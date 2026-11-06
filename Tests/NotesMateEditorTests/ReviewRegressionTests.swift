import AppKit
import XCTest
@testable import NotesMateEditor

final class ReviewRegressionTests: XCTestCase {
    private let unspecified = NSRange(location: NSNotFound, length: 0)

    func model() -> NoteEditorModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return NoteEditorModel(drafts: DraftStore(directory: directory), restore: false)
    }

    func isolatedFolders() {
        let name = "NotesMate.review.\(UUID().uuidString)"
        let previous = FolderCatalog.defaults
        let defaults = UserDefaults(suiteName: name)!
        FolderCatalog.defaults = defaults
        addTeardownBlock {
            FolderCatalog.defaults = previous
            defaults.removePersistentDomain(forName: name)
        }
    }

    func testSaveCompletionBeforeIMECommitKeepsNewInputAndBalancedUndo() {
        let model = model(), view = EditorTextView.make()
        model.bridge.attach(view)
        model.bridge.load(.plain("old"))
        let done = expectation(description: "saved during composition")
        model.saveAsync(using: { _ in .success }) { _ in
            XCTAssertEqual(model.bridge.document.text, "old")
            XCTAssertEqual(view.string, "新")
            XCTAssertTrue(model.isComposing)
            done.fulfill()
        }
        model.bridge.select(NSRange(location: 0, length: 3))
        view.setMarkedText("新", selectedRange: NSRange(location: 1, length: 0), replacementRange: unspecified)
        wait(for: [done], timeout: 3)
        view.unmarkText()
        XCTAssertEqual(model.bridge.document.text, "新")
        XCTAssertFalse(model.isComposing)
        XCTAssertTrue(model.bridge.history.manager.isUndoRegistrationEnabled)
        view.undo(nil)
        XCTAssertEqual(model.bridge.document.text, "old")
        view.redo(nil)
        XCTAssertEqual(model.bridge.document.text, "新")
    }

    func testEvenCancelledCompositionProtectsDraftAfterSaveSnapshot() {
        let model = model(), view = EditorTextView.make()
        model.bridge.attach(view)
        model.bridge.load(.plain("old"))
        let done = expectation(description: "saved")
        model.saveAsync(using: { _ in .success }) { _ in
            XCTAssertEqual(model.bridge.document.text, "old")
            done.fulfill()
        }
        let revision = model.bridge.document.revision
        model.bridge.beginComposition()
        model.bridge.finishComposition()
        XCTAssertEqual(model.bridge.document.revision, revision)
        wait(for: [done], timeout: 3)
    }

    func testExplicitLoadDuringCompositionEndsTransactionBeforeClearingHistory() {
        let bridge = AppKitInputBridge(), view = EditorTextView.make()
        bridge.attach(view)
        bridge.load(.plain("old"))
        view.setMarkedText("新", selectedRange: NSRange(location: 1, length: 0), replacementRange: unspecified)
        bridge.load(.plain("replacement"))
        view.unmarkText()
        XCTAssertFalse(bridge.isComposing)
        XCTAssertEqual(view.string, "replacement")
        XCTAssertTrue(bridge.history.manager.isUndoRegistrationEnabled)
        view.insertText("!", replacementRange: unspecified)
        bridge.history.sealTyping(in: view)
        bridge.history.manager.undo()
        XCTAssertEqual(bridge.document.text, "replacement")
    }

    func testQuitWaitsForEverySaveStageAndPersistsFinalDraft() throws {
        for stage in ["create", "attachment", "verification", "rollback"] {
            let model = model()
            model.bridge.load(.plain("draft"))
            let started = expectation(description: stage), saved = expectation(description: "saved"), quit = expectation(description: "quit")
            let release = DispatchSemaphore(value: 0)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let content = NotesSaverTests().content()
            var completionRan = false
            model.saveAsync(using: { _ in
                NotesSaver.save(content, execute: { script in
                    let current = script.contains("return id of newNote") ? "create"
                        : script.contains("make new attachment") ? "attachment"
                        : script.contains("save attachment") ? "verification" : "rollback"
                    if current == stage {
                        started.fulfill()
                        _ = release.wait(timeout: .now() + 5)
                    }
                    if current == "create" { return "test-note" }
                    if current == "verification", stage != "rollback" {
                        let dir = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)[0]
                        for i in 0..<2 {
                            try FileManager.default.copyItem(at: dir.appendingPathComponent("image-\(i).png"), to: dir.appendingPathComponent("verify-\(i).png"))
                        }
                    }
                    return ""
                }, temporaryRoot: root, verificationAttempts: 1)
            }) { _ in completionRan = true; saved.fulfill() }
            wait(for: [started], timeout: 3)
            XCTAssertFalse(model.prepareToQuit())
            var quitRan = false
            model.prepareToQuit { ready in
                quitRan = true
                XCTAssertTrue(ready)
                XCTAssertTrue(completionRan)
                XCTAssertFalse(model.isSaving)
                XCTAssertEqual(try? model.drafts.restore()?.text, stage == "rollback" ? "draft" : nil)
                quit.fulfill()
            }
            XCTAssertFalse(quitRan)
            release.signal()
            wait(for: [saved, quit], timeout: 5)
        }
    }

    func testFolderFallbackUsesFrozenTargetAndPreservesNewSelectionIncludingABA() {
        isolatedFolders()
        let a = NotesFolder(id: "a", name: "A", accountName: "account")
        let b = NotesFolder(id: "b", name: "B", accountName: "account")
        for returnToA in [false, true] {
            FolderCatalog.target = a
            let model = model()
            model.bridge.load(.plain("draft"))
            let done = expectation(description: "fallback")
            model.saveAsync(using: { content in
                XCTAssertEqual(content.target.folder, a)
                return NotesSaver.save(content, execute: { script in
                    if script.contains("folder id \"a\"") { throw NotesSaver.ScriptError(number: -1728, message: "gone") }
                    return "test-note"
                }, folderID: content.target.folder?.id)
            }) { result in
                XCTAssertEqual(result, .successUsingDefaultFolder)
                XCTAssertEqual(FolderCatalog.target, returnToA ? a : b)
                done.fulfill()
            }
            FolderCatalog.target = b
            if returnToA { FolderCatalog.target = a }
            wait(for: [done], timeout: 3)
        }
        FolderCatalog.target = a
        let captured = FolderCatalog.selection
        FolderCatalog.invalidate(captured)
        XCTAssertNil(FolderCatalog.target)
    }

    func testFolderRefreshRejectsStaleListsAndRefreshesNamesByStableID() {
        isolatedFolders()
        let a = NotesFolder(id: "a", name: "A", accountName: "old account")
        let b = NotesFolder(id: "b", name: "B", accountName: "account")
        FolderCatalog.target = a
        var refresh = FolderRefreshState()
        let old = refresh.begin(), latest = refresh.begin()
        refresh.reconcile([a, b], for: latest)
        FolderCatalog.target = b
        XCTAssertFalse(refresh.isCurrent(old))
        refresh.reconcile([a], for: old)
        XCTAssertEqual(FolderCatalog.target, b)
        let inFlight = refresh.begin()
        FolderCatalog.target = a
        refresh.reconcile([], for: inFlight)
        XCTAssertEqual(FolderCatalog.target, a)
        let renamed = NotesFolder(id: "a", name: "renamed", accountName: "new account")
        let renameRequest = refresh.begin()
        refresh.reconcile([renamed], for: renameRequest)
        XCTAssertEqual(FolderCatalog.target, renamed)
        let missing = refresh.begin()
        refresh.reconcile([], for: missing)
        XCTAssertNil(FolderCatalog.target)
    }

    func testSameCharacterReplacementUpdatesStyleExportUndoAndRedo() {
        let bridge = AppKitInputBridge(), view = EditorTextView.make()
        bridge.attach(view)
        bridge.load(EditorDocument(paragraphs: [Paragraph(runs: [InlineRun(text: "x"), InlineRun(text: "a", style: InlineStyle(marks: .bold))])]))
        let revision = bridge.document.revision
        bridge.select(NSRange(location: 1, length: 1))
        view.insertText("a", replacementRange: unspecified)
        XCTAssertEqual(bridge.document.text, "xa")
        XCTAssertGreaterThan(bridge.document.revision, revision)
        XCTAssertEqual(HTMLExporter.export(bridge.document).bodyHTML, "<div>xa</div>")
        bridge.history.sealTyping(in: view)
        bridge.history.manager.undo()
        XCTAssertEqual(HTMLExporter.export(bridge.document).bodyHTML, "<div>x<b>a</b></div>")
        bridge.history.manager.redo()
        XCTAssertEqual(HTMLExporter.export(bridge.document).bodyHTML, "<div>xa</div>")
    }

    func testIMESameCharacterReplacementSynchronizesStylesAndHistory() {
        let bridge = AppKitInputBridge(), view = EditorTextView.make()
        bridge.attach(view)
        let original = EditorDocument(paragraphs: [
            Paragraph(runs: [InlineRun(text: "x"), InlineRun(text: "啊", style: InlineStyle(marks: .bold))]),
            Paragraph(kind: .list(.ordered, 1), runs: [InlineRun(text: "retained")]),
        ])
        bridge.load(original)
        let revision = bridge.document.revision
        bridge.select(NSRange(location: 1, length: 1))
        view.setMarkedText("啊", selectedRange: NSRange(location: 1, length: 0), replacementRange: unspecified)
        view.unmarkText()
        XCTAssertEqual(bridge.document.paragraphs[0].runs, [InlineRun(text: "x啊")])
        XCTAssertEqual(bridge.document.paragraphs[1], original.paragraphs[1])
        XCTAssertGreaterThan(bridge.document.revision, revision)
        XCTAssertTrue(HTMLExporter.export(bridge.document).bodyHTML.hasPrefix("<div>x啊</div>"))
        let native = TextKitRenderer.decodeNative(view.textStorage!, assets: bridge.document.assets)
        XCTAssertEqual(native.paragraphs[0].runs, bridge.document.paragraphs[0].runs)
        view.undo(nil)
        XCTAssertEqual(bridge.document.paragraphs[0].runs, original.paragraphs[0].runs)
        view.redo(nil)
        XCTAssertEqual(bridge.document.paragraphs[0].runs, [InlineRun(text: "x啊")])
    }

    func testIMEReplacementAlsoSynchronizesUnchangedPrefixStyle() {
        let bridge = AppKitInputBridge(), view = EditorTextView.make()
        bridge.attach(view)
        bridge.load(EditorDocument(paragraphs: [Paragraph(runs: [
            InlineRun(text: "x"), InlineRun(text: "啊呀", style: InlineStyle(marks: .bold)),
        ])]))
        bridge.select(NSRange(location: 1, length: 2))
        view.setMarkedText("啊哈", selectedRange: NSRange(location: 2, length: 0), replacementRange: unspecified)
        view.unmarkText()
        XCTAssertEqual(HTMLExporter.export(bridge.document).bodyHTML, "<div>x啊哈</div>")
        view.undo(nil)
        XCTAssertEqual(HTMLExporter.export(bridge.document).bodyHTML, "<div>x<b>啊呀</b></div>")
    }

    func testTypingAcrossEventTurnsClosesGroupsAndPreservesUndoBoundaries() {
        let bridge = AppKitInputBridge(), view = EditorTextView.make()
        bridge.attach(view)
        for text in ["hello", " world"] {
            view.insertText(text, replacementRange: unspecified)
            let nextTurn = expectation(description: "next event")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { nextTurn.fulfill() }
            wait(for: [nextTurn], timeout: 2)
        }
        XCTAssertEqual(bridge.history.manager.groupingLevel, 0)
        view.undo(nil)
        // Preserve the editor's existing per-event boundary across native projections.
        XCTAssertEqual(view.string, "hello")
        view.undo(nil)
        XCTAssertEqual(view.string, "")
        view.redo(nil)
        view.redo(nil)
        XCTAssertEqual(view.string, "hello world")
    }

    func testMultiImageAndMixedPasteMaintainImageParagraphsInBodyAndLists() {
        var images = ClipboardCodec.imageFragment([NotesSaverTests().image(), NotesSaverTests().image()])
        images.paragraphs = images.paragraphs.flatMap(\.runs).map { Paragraph(runs: [$0]) }
        for kind in [BlockKind.body, .list(.ordered, 1)] {
            for mixed in [false, true] {
                let bridge = AppKitInputBridge(), view = EditorTextView.make()
                bridge.attach(view)
                bridge.load(EditorDocument(paragraphs: [Paragraph(kind: kind, runs: [InlineRun(text: "beforeafter")])]))
                bridge.select(NSRange(location: 6, length: 0))
                var fragment = images
                if mixed { fragment.paragraphs.insert(Paragraph(runs: [InlineRun(text: "middle")]), at: 1) }
                let board = NSPasteboard.withUniqueName()
                defer { board.releaseGlobally() }
                ClipboardCodec.write(fragment, to: board)
                bridge.paste(from: board)
                XCTAssertEqual(bridge.document.text, "before\n\u{FFFC}\n" + (mixed ? "middle\n" : "") + "\u{FFFC}\nafter")
                for paragraph in bridge.document.paragraphs where paragraph.runs.contains(where: { $0.assetID != nil }) {
                    XCTAssertTrue(paragraph.isAttachmentOnly)
                    XCTAssertEqual(paragraph.kind, .body)
                }
            }
        }
    }

    func testExchangeListsRoundTripWithSharedIdentityAndMixedNesting() throws {
        let kinds: [BlockKind] = [.list(.ordered, 1), .list(.unordered, 2), .list(.ordered, 3), .list(.ordered, 1), .list(.ordered, 1), .body, .list(.ordered, 1)]
        let document = EditorDocument(paragraphs: kinds.enumerated().map { Paragraph(kind: $0.element, runs: [InlineRun(text: "row\($0.offset)")]) })
        let rendered = TextKitRenderer.render(document, exchange: true)
        for format in [NSAttributedString.DocumentType.rtf, .rtfd] {
            let data = try rendered.data(from: NSRange(location: 0, length: rendered.length), documentAttributes: [.documentType: format])
            let read = try NSAttributedString(data: data, options: [.documentType: format], documentAttributes: nil)
            let string = read.string as NSString
            func lists(_ row: Int) -> [NSTextList] {
                (read.attribute(.paragraphStyle, at: string.range(of: "row\(row)").location, effectiveRange: nil) as! NSParagraphStyle).textLists
            }
            XCTAssertEqual(lists(2).map(\.markerFormat), [.decimal, .disc, .decimal])
            for (row, number) in [(0, 1), (3, 2), (4, 3), (6, 1)] {
                XCTAssertEqual(read.itemNumber(in: lists(row)[0], at: string.range(of: "row\(row)").location), number)
            }
            XCTAssertTrue(lists(0)[0] === lists(3)[0])
            XCTAssertFalse(lists(0)[0] === lists(6)[0])
        }
    }

    func testHTMLRoundTripPreservesSpacesAndExpandsTabsInBodyAndInlineCode() throws {
        for marks in [InlineMarks(), .code] {
            let text = "  a  b\t c  "
            let document = EditorDocument.plain(text, style: InlineStyle(marks: marks))
            let html = HTMLExporter.export(document).bodyHTML
            let read = try NSAttributedString(data: Data(html.utf8), options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
            XCTAssertEqual(read.string.replacingOccurrences(of: "\u{00A0}", with: " ").trimmingCharacters(in: .newlines), text.replacingOccurrences(of: "\t", with: "    "))
        }
    }

    func testCreateSideEffectThenTimeoutReportsUnknownAndRetainsDraft() {
        let model = model()
        model.bridge.load(.plain("locatable draft"))
        var created = false
        let result = model.save(using: { content in
            NotesSaver.save(content, execute: { _ in
                created = true
                throw NotesSaver.ScriptError(number: -1712, message: "AppleEvent timed out")
            })
        })
        XCTAssertTrue(created)
        guard case .outcomeUnknown(let message) = result else { return XCTFail("Expected unknown result") }
        XCTAssertTrue(message.contains(EditorLanguage.text("Default Folder")))
        XCTAssertTrue(message.contains("AppleEvent timed out"))
        XCTAssertEqual(model.lastSaveError, result)
        XCTAssertEqual(model.bridge.document.text, "locatable draft")
    }

    func testAuthorizationAfterCreationAndFailedRollbackRetainsRecoveryDetails() throws {
        let model = model()
        model.bridge.load(.plain("draft"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = model.save(using: { _ in
            NotesSaver.save(NotesSaverTests().content(), execute: { script in
                if script.contains("return id of newNote") { return "test-note" }
                throw NotesSaver.ScriptError(number: -1743, message: "Not authorized")
            }, temporaryRoot: root)
        })
        XCTAssertTrue(result?.needsAuthorization == true)
        XCTAssertEqual(model.lastSaveError, result)
        let detail = try XCTUnwrap(model.lastSaveError?.errorDetail)
        XCTAssertTrue(detail.contains("Not authorized"))
        XCTAssertTrue(detail.contains(EditorLanguage.text("\nCould not remove the incomplete note. Check Notes before retrying to avoid duplicates.")))
        XCTAssertTrue(detail.contains(root.path))
    }
}
