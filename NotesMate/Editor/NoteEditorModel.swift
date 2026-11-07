import AppKit
import SwiftUI

final class NoteEditorModel: ObservableObject {
    let bridge: AppKitInputBridge
    let tips: EditorTipsController
    private let featureTips: EditorFeatureTips
    let drafts: DraftStore
    private var pendingPersist: DispatchWorkItem?
    private var lastPersistRevision: UInt64?
    // An empty draft still exists until explicitly replaced. Window visibility and
    // document emptiness must not be used as draft-creation signals.
    private var hasDraft = false
    private(set) var recoveryMessage: String?
    @Published private(set) var isSaving = false
    @Published private(set) var lastSaveError: NotesSaver.SaveResult?
    private var quitCompletions: [(Bool) -> Void] = []
    @Published private(set) var draftPersistenceFailed = false
    private static let saveQueue = DispatchQueue(label: "NotesMate.save", qos: .userInitiated)

    init(drafts: DraftStore = DraftStore(), restore: Bool = true, tips: EditorTipsController = EditorTipsController()) {
        self.bridge = AppKitInputBridge()
        self.drafts = drafts
        self.tips = tips
        let featureTips = EditorFeatureTips(tips: tips)
        self.featureTips = featureTips
        if restore {
            do {
                if let document = try drafts.restore() {
                    hasDraft = true
                    bridge.load(document, session: drafts.restoredSession)
                }
            }
            catch {
                hasDraft = true // A damaged existing draft is not a newly created draft.
                recoveryMessage = EditorLanguage.format("Couldn’t restore the draft. The original file has been preserved: {0}", error.localizedDescription)
            }
        }
        tips.onSessionBegan = { [weak self] in
            guard let self else { return }
            self.bridge.beginTipSession()
            self.ensureDraft()
        }
        tips.canPresent = { [weak bridge] tip in bridge.map { EditorTipContext.canPresent(tip, in: $0) } ?? false }
        tips.canSave = { [weak self] in
            guard let self else { return false }
            return !self.isEmpty && !self.isComposing && !self.isSaving
        }
        bridge.hooks.observe { [weak featureTips] hook, context in featureTips?.handle(hook, context: context) }
        bridge.onChange = { [weak self] in
            guard let self else { return }
            // Programmatically loaded content also resumes an existing draft.
            if !self.bridge.document.isPristine { self.hasDraft = true }
            self.objectWillChange.send()
            self.tips.editorChanged()
            guard !self.bridge.isComposing, self.lastPersistRevision != self.bridge.document.revision else { return }
            self.lastPersistRevision = self.bridge.document.revision
            self.pendingPersist?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.persistDraft() }
            self.pendingPersist = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
        }
    }

    var isEmpty: Bool { !bridge.document.canSend }
    var images: [NSImage] { bridge.document.assetOrder.compactMap { bridge.document.assets[$0].flatMap { NSImage(data: $0.data) } } }
    var attachmentCount: Int { bridge.document.assetOrder.count }
    var isComposing: Bool { bridge.isComposing }
    var selectedBlock: BlockKind? {
        let indices = PositionMap(bridge.document).paragraphs(in: bridge.state.session.selection)
        let first = bridge.document.paragraphs[indices.lowerBound].kind
        return indices.allSatisfy { bridge.document.paragraphs[$0].kind == first } ? first : nil
    }
    func isActive(_ mark: InlineMarks) -> Bool {
        let selection = bridge.state.session.selection
        if selection.length == 0 { return bridge.state.session.insertionStyle.marks.contains(mark) }
        let runs = bridge.document.fragment(in: selection).paragraphs.flatMap(\.runs).filter { $0.assetID == nil }
        return !runs.isEmpty && runs.allSatisfy { $0.style.marks.contains(mark) }
    }

    func toggleBold() { bridge.execute(.toggle(.bold), name: EditorLanguage.text("Bold")) }
    func toggleItalic() { bridge.execute(.toggle(.italic), name: EditorLanguage.text("Italic")) }
    func toggleUnderline() { bridge.execute(.toggle(.underline), name: EditorLanguage.text("Underline")) }
    func toggleStrike() { bridge.execute(.toggle(.strike), name: EditorLanguage.text("Strikethrough")) }
    func setBlock(_ kind: BlockKind) { bridge.execute(.block(kind), name: EditorLanguage.text("Paragraph Style")) }
    func toggleList(_ kind: ListKind) { bridge.execute(.list(kind), name: EditorLanguage.text("List")) }

    func exportContent() -> NotesSaver.NoteContent? {
        guard !bridge.isComposing, !isEmpty else { return nil }
        let result = HTMLExporter.export(bridge.document)
        return NotesSaver.NoteContent(bodyHTML: result.bodyHTML, images: images,
                                      target: FolderCatalog.selection)
    }

    @discardableResult
    func save(using writer: (NotesSaver.NoteContent) -> NotesSaver.SaveResult = NotesSaver.save) -> NotesSaver.SaveResult? {
        guard !isSaving, quitCompletions.isEmpty, let content = exportContent() else { return nil }
        let revision = bridge.document.revision
        let inputGeneration = bridge.inputGeneration
        let result = writer(content)
        finishSave(result, content: content, revision: revision, inputGeneration: inputGeneration)
        return result
    }

    private func finishSave(_ result: NotesSaver.SaveResult, content: NotesSaver.NoteContent,
                            revision: UInt64, inputGeneration: UInt64) {
        if case .successUsingDefaultFolder = result { FolderCatalog.invalidate(content.target) }
        lastSaveError = result.succeeded ? nil : result
        if result.succeeded, !bridge.isComposing,
           bridge.document.revision == revision, bridge.inputGeneration == inputGeneration { clear() }
    }

    func clear() {
        pendingPersist?.cancel(); pendingPersist = nil
        bridge.load(EditorDocument())
        hasDraft = false
        ensureDraft()
        persistDraft()
    }

    private func ensureDraft() {
        guard !hasDraft else { return }
        hasDraft = true
        bridge.hooks.emit(.draftCreated, context: bridge.hookContext)
    }

    func saveAsync(using writer: @escaping (NotesSaver.NoteContent) -> NotesSaver.SaveResult = NotesSaver.save,
                   completion: @escaping (NotesSaver.SaveResult) -> Void) {
        guard !isSaving, quitCompletions.isEmpty, let content = exportContent() else { return }
        let revision = bridge.document.revision
        let inputGeneration = bridge.inputGeneration
        isSaving = true
        Self.saveQueue.async {
            let result = autoreleasepool { writer(content) }
            DispatchQueue.main.async {
                self.finishSave(result, content: content, revision: revision, inputGeneration: inputGeneration)
                self.isSaving = false
                completion(result)
                let waiting = self.quitCompletions
                self.quitCompletions.removeAll()
                if !waiting.isEmpty {
                    let ready = self.prepareToQuit()
                    waiting.forEach { $0(ready) }
                }
            }
        }
    }

    func persistDraft() {
        pendingPersist?.cancel(); pendingPersist = nil
        // During composition the bridge still exposes only the last committed document.
        drafts.persist(bridge.document, session: bridge.state.session) { [weak self] error in
            self?.draftPersistenceFailed = error != nil
        }
    }

    func flushPendingPersist() {
        if pendingPersist != nil { persistDraft() }
        drafts.flush()
        draftPersistenceFailed = drafts.lastError != nil
    }

    /// Retry the current snapshot and synchronously check the actual disk result before quitting.
    func prepareToQuit() -> Bool {
        guard !isSaving else { return false }
        bridge.commitComposition()
        persistDraft()
        flushPendingPersist()
        return !draftPersistenceFailed
    }

    func prepareToQuit(completion: @escaping (Bool) -> Void) {
        if isSaving { quitCompletions.append(completion) }
        else { completion(prepareToQuit()) }
    }

    deinit { pendingPersist?.cancel() }
}
