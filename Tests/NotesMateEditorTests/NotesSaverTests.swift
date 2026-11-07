import AppKit
import XCTest
@testable import NotesMateEditor

final class NotesSaverTests: XCTestCase {
    func testInProcessScriptRunsOffMainThreadAndPreservesErrors() {
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { done.signal() }
            XCTAssertFalse(Thread.isMainThread)
            do {
                XCTAssertEqual(try NotesSaver.runScript("return \"后台执行成功\""), "后台执行成功")
                XCTAssertThrowsError(try NotesSaver.runScript("error \"permission probe\" number -10004")) { error in
                    XCTAssertEqual((error as? NotesSaver.ScriptError)?.number, -10004)
                }
            } catch { XCTFail("\(error)") }
        }
        XCTAssertEqual(done.wait(timeout: .now() + 15), .success)
    }

    func image() -> NSImage {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<2 { for y in 0..<2 { bitmap.setColor(.red, atX: x, y: y) } }
        let image = NSImage(size: NSSize(width: 2, height: 2)); image.addRepresentation(bitmap); return image
    }
    func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func content() -> NotesSaver.NoteContent {
        .init(bodyHTML: "<div>A\(HTMLExporter.imagePlaceholder(0))B\(HTMLExporter.imagePlaceholder(1))C</div>", images: [image(), image()])
    }
    func testExporterPreservesRepeatedImageOccurrencesAndEscapesUserText() throws {
        let id = UUID()
        let doc = EditorDocument(paragraphs: [Paragraph(runs: [InlineRun(text: "A"), .image(id), InlineRun(text: "B"), .image(id), InlineRun(text: "C<!--NotesMateImage:0-->")])])
        let export = HTMLExporter.export(doc)
        XCTAssertEqual(export.assetIDs, [id, id])
        let html = try NotesSaver.resolveHTML(export.bodyHTML, imagePaths: ["/tmp/a & \"1.png", "/tmp/b.png"])
        XCTAssertTrue(html.final.contains("A<img"))
        XCTAssertTrue(html.final.contains(">B<img"))
        XCTAssertTrue(html.final.contains(">C&lt;!--NotesMateImage:0--&gt;"))
        XCTAssertFalse(html.final.contains("<!--NotesMateImage:"))
        XCTAssertTrue(html.final.contains("%22"))
        XCTAssertThrowsError(try NotesSaver.resolveHTML(export.bodyHTML, imagePaths: ["/tmp/a.png"]))
    }
    func testSuccessfulSaveVerifiesEveryOccurrenceBeforeCleanup() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        var calls: [String] = []
        let result = NotesSaver.save(content(), execute: { script in
            calls.append(script)
            if script.contains("return id of newNote") { return "test-note" }
            if script.contains("save attachment") {
                let directory = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)[0]
                for i in 0..<2 {
                    try FileManager.default.copyItem(at: directory.appendingPathComponent("image-\(i).png"),
                                                     to: directory.appendingPathComponent("verify-\(i).png"))
                }
            }
            return ""
        }, temporaryRoot: root)
        XCTAssertEqual(result, .success)
        XCTAssertEqual(calls.count, 3)
        XCTAssertFalse(calls[0].contains("<!--NotesMateImage:"))
        XCTAssertTrue(calls[1].range(of: "make new attachment")!.lowerBound < calls[1].range(of: "set body")!.lowerBound)
        XCTAssertFalse(calls.joined().contains("activate"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
    func testCorruptAttachmentRollsBackAndDoesNotReportSuccess() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        var rolledBack = false
        let result = NotesSaver.save(content(), execute: { script in
            if script.contains("return id of newNote") { return "test-note" }
            if script.contains("save attachment") {
                let dir = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)[0]
                for i in 0..<2 { try Data("corrupt".utf8).write(to: dir.appendingPathComponent("verify-\(i).png")) }
            }
            if script.contains("delete note id") { rolledBack = true }
            return ""
        }, temporaryRoot: root, verificationAttempts: 1)
        guard case .failed = result else { return XCTFail("Must fail") }
        XCTAssertTrue(rolledBack)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
    func testRollbackFailureRetainsSourceImages() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let result = NotesSaver.save(content(), execute: { script in
            if script.contains("return id of newNote") { return "test-note" }
            throw NotesSaver.ScriptError(number: -10000, message: "injected failure")
        }, temporaryRoot: root, verificationAttempts: 1)
        guard case .failed(let message) = result else { return XCTFail("Must fail") }
        XCTAssertTrue(message.contains(EditorLanguage.text("\nCould not remove the incomplete note. Check Notes before retrying to avoid duplicates.")))
        let dir = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)[0]
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("image-0.png").path))
    }
    func testMissingImageStopsBeforeAppleScript() {
        var called = false
        let result = NotesSaver.save(.init(bodyHTML: HTMLExporter.imagePlaceholder(0), images: []), execute: { _ in called = true; return "" })
        guard case .failed = result else { return XCTFail("Must fail") }
        XCTAssertFalse(called)
    }

    func testPlainTextRemainsOneBackgroundCall() {
        var calls = 0
        let result = NotesSaver.save(.init(bodyHTML: "<div>正文</div>", images: []), execute: { script in
            calls += 1
            XCTAssertFalse(script.contains("attachment"))
            return "test-note"
        })
        XCTAssertEqual(result, .success)
        XCTAssertEqual(calls, 1)
    }

    func testAttachmentReadinessCanRetry() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        var checks = 0
        let result = NotesSaver.save(content(), execute: { script in
            if script.contains("return id of newNote") { return "test-note" }
            if script.contains("save attachment") {
                checks += 1
                if checks == 1 { throw NotesSaver.ScriptError(number: -10000, message: "not ready") }
                let dir = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)[0]
                for i in 0..<2 {
                    try FileManager.default.copyItem(at: dir.appendingPathComponent("image-\(i).png"),
                                                     to: dir.appendingPathComponent("verify-\(i).png"))
                }
            }
            return ""
        }, temporaryRoot: root, verificationAttempts: 2)
        XCTAssertEqual(result, .success)
        XCTAssertEqual(checks, 2)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testCatalogParsesAccountsFoldersAndSkipsMalformedLines() {
        let output = "iCloud\tx-coredata://A/ICFolder/p1\t收件箱\n" +
            "iCloud\tx-coredata://A/ICFolder/p2\t工作 笔记\n" +
            "On My Mac\tx-coredata://B/ICFolder/p9\t本地\n" +
            "broken line\n" +
            "iCloud\t\t缺 ID\n"
        XCTAssertEqual(FolderCatalog.parse(output), [
            NotesFolder(id: "x-coredata://A/ICFolder/p1", name: "收件箱", accountName: "iCloud"),
            NotesFolder(id: "x-coredata://A/ICFolder/p2", name: "工作 笔记", accountName: "iCloud"),
            NotesFolder(id: "x-coredata://B/ICFolder/p9", name: "本地", accountName: "On My Mac"),
        ])
        XCTAssertEqual(FolderCatalog.parse(""), [])
    }

    func testCatalogFetchRunsScriptAndParsesResult() throws {
        var script = ""
        let folders = try FolderCatalog.fetch(execute: { script = $0; return "iCloud\tx-coredata://A/ICFolder/p1\t收件箱\n" })
        XCTAssertTrue(script.contains("folders of acc"))
        XCTAssertEqual(folders, [NotesFolder(id: "x-coredata://A/ICFolder/p1", name: "收件箱", accountName: "iCloud")])
    }

    func testMakeScriptTargetsFolderIDWithEscaping() {
        let script = NotesSaver.makeScript(bodyHTML: "<div>正文</div>", folderID: "x-coredata://A/ICFolder/p\"1\\")
        XCTAssertTrue(script.contains("make new note at folder id \"x-coredata://A/ICFolder/p\\\"1\\\\\""))
        XCTAssertFalse(script.contains("default folder"))
        XCTAssertTrue(NotesSaver.makeScript(bodyHTML: "<div>正文</div>").contains("default folder of default account"))
    }

    func testSaveFallsBackToDefaultFolderWhenTargetIsGone() {
        var calls: [String] = []
        let result = NotesSaver.save(.init(bodyHTML: "<div>正文</div>", images: []), execute: { script in
            calls.append(script)
            if script.contains("folder id") {
                throw NotesSaver.ScriptError(number: -1728, message: "Can't get folder")
            }
            return "test-note"
        }, folderID: "x-coredata://A/ICFolder/p1")
        XCTAssertEqual(result, .successUsingDefaultFolder)
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls[0].contains("folder id \"x-coredata://A/ICFolder/p1\""))
        XCTAssertTrue(calls[1].contains("default folder of default account"))
    }

    func testSaveDoesNotFallBackOnOtherErrors() {
        for number in [-1743, -1744] {
            var calls = 0
            let result = NotesSaver.save(.init(bodyHTML: "<div>正文</div>", images: []), execute: { _ in
                calls += 1
                throw NotesSaver.ScriptError(number: number, message: "Not authorized")
            }, folderID: "x-coredata://A/ICFolder/p1")
            guard case .unauthorized = result else { return XCTFail("Must be unauthorized: \(number)") }
            XCTAssertEqual(calls, 1)
        }
    }

    func testAutomationPermissionMenuStateTracksBothErrorsAndSuccess() {
        let name = "NotesMate.automation.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertFalse(NotesAutomationPermission.needsAuthorization(in: defaults))
        XCTAssertTrue(NotesAutomationPermission.shouldShowAuthorizationMenu(in: defaults))
        for number in [-1744, -1743] {
            NotesAutomationPermission.recordScriptError(number, defaults: defaults)
            XCTAssertTrue(NotesAutomationPermission.needsAuthorization(in: defaults))
            XCTAssertTrue(NotesAutomationPermission.shouldShowAuthorizationMenu(in: defaults))
            NotesAutomationPermission.recordScriptSuccess(defaults: defaults)
            XCTAssertFalse(NotesAutomationPermission.needsAuthorization(in: defaults))
            XCTAssertFalse(NotesAutomationPermission.shouldShowAuthorizationMenu(in: defaults))
        }
        NotesAutomationPermission.recordScriptError(-1728, defaults: defaults)
        XCTAssertFalse(NotesAutomationPermission.needsAuthorization(in: defaults))
        XCTAssertFalse(NotesAutomationPermission.shouldShowAuthorizationMenu(in: defaults))
    }

    func testFolderSelectorWaitsForSuccessfulSaveOnNewInstall() {
        let name = "NotesMate.folderSelector.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let previousDefaults = FolderCatalog.defaults
        FolderCatalog.defaults = defaults
        defer { FolderCatalog.defaults = previousDefaults }

        FolderCatalog.prepareForLaunch(hadOpenedEditorBefore: false)
        XCTAssertFalse(FolderCatalog.isSelectorAvailable)
        FolderCatalog.prepareForLaunch(hadOpenedEditorBefore: true)
        XCTAssertFalse(FolderCatalog.isSelectorAvailable, "A restart before the first save must not load folders")
        FolderCatalog.recordSuccessfulSave()
        XCTAssertTrue(FolderCatalog.isSelectorAvailable)
    }

    func testExistingInstallationKeepsFolderSelector() {
        let name = "NotesMate.folderSelector.legacy.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let previousDefaults = FolderCatalog.defaults
        FolderCatalog.defaults = defaults
        defer { FolderCatalog.defaults = previousDefaults }

        FolderCatalog.prepareForLaunch(hadOpenedEditorBefore: true)
        XCTAssertTrue(FolderCatalog.isSelectorAvailable)
    }

    func testTargetFolderPersistsAcrossDefaultsRoundTrip() {
        let suiteName = "NotesMateTests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        FolderCatalog.defaults = suite
        defer { FolderCatalog.defaults = .standard }
        XCTAssertNil(FolderCatalog.target)
        let folder = NotesFolder(id: "x-coredata://A/ICFolder/p1", name: "收件箱", accountName: "iCloud")
        FolderCatalog.target = folder
        XCTAssertEqual(FolderCatalog.target, folder)
        FolderCatalog.target = nil
        XCTAssertNil(FolderCatalog.target)
        XCTAssertNil(suite.string(forKey: "NotesMate.targetFolder.id"))
    }
}
