import AppKit

/// Owns committed editor state. NSTextStorage is a projection and an IME staging surface.
final class AppKitInputBridge: NSObject, NSTextViewDelegate {
    private(set) var state = EditorSnapshot(document: EditorDocument(), session: EditorSession())
    weak var textView: EditorTextView?
    let history = UndoCoordinator()
    var onChange: (() -> Void)?
    let hooks = EditorHooks()
    private var dispatchKey: EditorKey?
    private var inputHookDepth = 0
    private var observedFormat: BlockKind = .body

    var hookContext: EditorHookContext {
        let index = positionMap.position(at: state.session.selection.location).index
        let expansion = selectionExpansion.flatMap {
            $0.revision == document.revision && $0.scopes[$0.step] == state.session.selection ? $0 : nil
        }
        return EditorHookContext(key: dispatchKey, format: document.paragraphs[index].kind,
            selection: state.session.selection, revision: document.revision, isComposing: isComposing,
            isPristine: document.isPristine, selectionStage: expansion.map { $0.step + 1 } ?? 0,
            selectionStageCount: expansion?.scopes.count ?? SelectionExpander.scopes(in: document, at: index).count)
    }
    func beginTipSession() {
        dispatchKey = nil
        // Reopening resumes the current format; it is not a format transition.
        // Reset the baseline without synthesizing an enterFormat event.
        observedFormat = hookContext.format
        hooks.emit(.sessionStarted, context: hookContext)
    }
    func withKeyPress(_ key: EditorKey, _ action: () -> Void) {
        let previous = dispatchKey
        dispatchKey = key
        hooks.emit(.keyPress, context: hookContext)
        defer { dispatchKey = previous }
        action()
        hooks.emit(.afterKeyPress, context: hookContext)
    }
    func keyReleased(_ key: EditorKey) {
        let previous = dispatchKey; dispatchKey = key
        hooks.emit(.keyRelease, context: hookContext)
        dispatchKey = previous
    }
    private func beginInputHook() {
        if inputHookDepth == 0 { hooks.emit(.beforeInput, context: hookContext) }
        inputHookDepth += 1
    }
    private func endInputHook(changed: Bool) {
        inputHookDepth -= 1
        if inputHookDepth == 0, changed {
            publishFormatTransition()
            hooks.emit(.afterInput, context: hookContext)
        }
    }
    private func publishFormatTransition() {
        guard !isComposing else { return }
        let current = hookContext.format
        guard observedFormat != current else { return }
        let old = observedFormat; observedFormat = current
        hooks.emit(.leaveFormat(old), context: hookContext)
        hooks.emit(.enterFormat(current), context: hookContext)
    }
    var onSave: (() -> Void)?
    private(set) var isApplying = false
    private(set) var nativeDepth = 0
    private(set) var compositionBefore: EditorSnapshot?
    private var pendingRange: NSRange?
    private var pendingBefore: EditorSnapshot?
    private var structuralNative = false
    private var suppressedNative = false
    private var listCache: [Int: ListResolver.Item] = [:]
    private struct SelectionExpansion {
        let revision: UInt64
        let scopes: [NSRange]
        let step: Int
    }
    private var selectionExpansion: SelectionExpansion?
    private(set) var positionMap = PositionMap(EditorDocument())
    struct Presentation {
        let document: EditorDocument
        let positions: PositionMap
        let lists: [Int: ListResolver.Item]
    }
    private var compositionPresentation: Presentation?
    var document: EditorDocument { state.document }
    /// Read-only IME preview for marker positions; never persisted or exported.
    var presentation: Presentation {
        guard let before = compositionBefore, let storage = textView?.textStorage else {
            return Presentation(document: document, positions: positionMap, lists: listCache)
        }
        if nativeDepth == 0, let cached = compositionPresentation { return cached }
        let delta = Self.difference(before.document.text as NSString, storage.string as NSString)
        let fragment = TextKitRenderer.decodeNative(storage.attributedSubstring(from: NSRange(location: delta.0.location, length: delta.1)), assets: before.document.assets)
        var preview = before.document
        preview.replace(delta.0, with: fragment)
        let result = Presentation(document: preview, positions: PositionMap(preview), lists: ListResolver.resolve(preview))
        if nativeDepth == 0 { compositionPresentation = result }
        return result
    }
    var presentationDocument: EditorDocument { presentation.document }
    func compositionDidChange() {
        compositionPresentation = nil
        textView?.needsDisplay = true
    }
    var isComposing: Bool { compositionBefore != nil || textView?.hasMarkedText() == true }

    override init() {
        super.init()
        history.snapshot = { [weak self] in self?.state ?? EditorSnapshot(document: EditorDocument(), session: EditorSession()) }
        history.restore = { [weak self] snapshot in self?.restoreHistory(snapshot) }
    }

    func attach(_ view: EditorTextView) {
        textView = view
        view.bridge = self
        view.delegate = self
        isApplying = true
        positionMap = PositionMap(document)
        listCache = ListResolver.resolve(document)
        TextKitRenderer.apply(state.document, previous: nil, to: view)
        view.setSelectedRange(state.session.selection, affinity: NSSelectionAffinity(rawValue: state.session.affinity) ?? .downstream, stillSelecting: false)
        updateTypingAttributes()
        isApplying = false
    }

    func undoManager(for view: NSTextView) -> UndoManager? { history.manager }

    func load(_ document: EditorDocument, session: EditorSession? = nil, clearHistory: Bool = true) {
        guard let valid = try? document.validated() else { return }
        let previous = state.document
        state = EditorSnapshot(document: valid, session: session ?? EditorSession())
        state.session.selection = PositionMap(valid).clamped(state.session.selection)
        state.document.revision = previous.revision &+ 1
        applyProjection(previous: previous)
        if clearHistory { history.sealTyping(in: textView); history.manager.removeAllActions() }
        changed()
    }

    func select(_ range: NSRange, userInitiated: Bool = true, affinity: NSSelectionAffinity = .downstream) {
        selectionExpansion = nil
        state.session.selection = PositionMap(document).clamped(range)
        state.session.affinity = affinity.rawValue
        if userInitiated { state.session.explicitInsertionStyle = false; inheritInsertionStyle() }
        isApplying = true
        textView?.setSelectedRange(state.session.selection, affinity: affinity, stillSelecting: false)
        updateTypingAttributes()
        isApplying = false
        publishFormatTransition()
        hooks.emit(.selectionChanged, context: hookContext)
        onChange?()
    }

    func selectNextScope() {
        guard !isComposing else { return }
        let selection = positionMap.clamped(textView?.selectedRange() ?? state.session.selection)
        let scopes: [NSRange]
        let step: Int
        if let expansion = selectionExpansion,
           expansion.revision == document.revision,
           expansion.scopes[expansion.step] == selection {
            scopes = expansion.scopes
            step = min(expansion.step + 1, scopes.count - 1)
        } else {
            let index = positionMap.position(at: selection.location).index
            scopes = SelectionExpander.scopes(in: document, at: index)
            step = 0
        }
        select(scopes[step])
        selectionExpansion = SelectionExpansion(revision: document.revision, scopes: scopes, step: step)
    }

    func execute(_ command: EditorCommand, name: String = EditorLanguage.text("Format")) {
        if isComposing {
            switch command {
            case .block, .list, .toggle:
                // Explicit formatting ends composition, preserving the displayed text.
                // Reconcile the model before applying a command to its selection.
                textView?.unmarkText()
                textView?.inputContext?.discardMarkedText()
                finishComposition()
            default: return
            }
        }
        guard !isComposing else { return }
        var next = state
        guard EditorReducer.apply(command, to: &next) else { return }
        beginInputHook()
        defer { endInputHook(changed: true) }
        commit(next, name: name)
    }

    private func commit(_ next: EditorSnapshot, name: String) {
        let before = state
        history.sealTyping(in: textView)
        state = next
        state.document.revision = before.document.revision &+ 1
        applyProjection(previous: before.document)
        history.register(before, name: name, view: textView)
        changed()
    }

    private func restoreHistory(_ snapshot: EditorSnapshot) {
        beginInputHook()
        defer { endInputHook(changed: true) }
        let previous = state.document
        state = snapshot
        state.document.revision = previous.revision &+ 1
        applyProjection(previous: previous)
        changed()
    }

    private func applyProjection(previous: EditorDocument) {
        guard let view = textView else { return }
        isApplying = true
        // Geometry can be queried synchronously while AppKit updates its selection.
        // Publish the new positional cache before touching the native view.
        positionMap = PositionMap(document)
        listCache = ListResolver.resolve(document)
        history.withoutRegistration {
            TextKitRenderer.apply(state.document, previous: previous, to: view)
            view.setSelectedRange(PositionMap(document).clamped(state.session.selection),
                                  affinity: NSSelectionAffinity(rawValue: state.session.affinity) ?? .downstream, stillSelecting: false)
            updateTypingAttributes()
        }
        isApplying = false
        view.scrollSelectionAfterLayout()
    }

    func runNative(inserted: String? = nil, _ action: () -> Void) {
        let outer = nativeDepth == 0
        let before = state
        let wasComposition = isComposing
        if outer { beginInputHook() }
        defer { if outer { endInputHook(changed: before != state) } }
        if outer {
            pendingRange = nil; pendingBefore = nil; structuralNative = false
            if !wasComposition { history.prepareNativeEvent() }
        }
        nativeDepth += 1
        action()
        nativeDepth -= 1
        if wasComposition { compositionDidChange() }
        guard outer else { return }
        if compositionBefore != nil {
            if textView?.hasMarkedText() != true { finishComposition() }
            return
        }
        synchronizeNative(from: before)
        if suppressedNative { history.manager.enableUndoRegistration(); suppressedNative = false }
        if structuralNative, before.document != state.document { history.register(before, name: EditorLanguage.text("Edit"), view: textView) }
        if !wasComposition, let inserted, let plan = MarkdownTriggerEngine.plan(in: state, inserted: inserted) {
            var next = state
            MarkdownTriggerEngine.apply(plan, to: &next)
            commit(next, name: EditorLanguage.text("Auto Format"))
            hooks.emit(.markdownShortcutApplied(plan), context: hookContext)
        }
        pendingBefore = nil; pendingRange = nil
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard !isApplying else { return true }
        guard let replacementString else { return history.manager.isUndoing || history.manager.isRedoing }
        if compositionBefore != nil { return true }
        if pendingBefore == nil { pendingBefore = state; pendingRange = affectedCharRange }
        else { pendingRange = nil } // Complex native edits are reconciled by a bounded string difference.
        let safe = PositionMap(document).clamped(affectedCharRange)
        let removed = (document.text as NSString).substring(with: safe)
        if removed.contains("\n") || replacementString.contains("\n") {
            structuralNative = true
            if !suppressedNative && !history.manager.isUndoing && !history.manager.isRedoing {
                history.manager.disableUndoRegistration(); suppressedNative = true
            }
        }
        return true
    }

    func textDidChange(_ notification: Notification) {
        if isComposing { compositionDidChange(); return }
        guard !isApplying, !isComposing, nativeDepth == 0 else { return }
        beginInputHook()
        defer { endInputHook(changed: true) }
        let before = pendingBefore ?? state
        synchronizeNative(from: before)
        if suppressedNative { history.manager.enableUndoRegistration(); suppressedNative = false }
        if structuralNative, !history.manager.isUndoing, !history.manager.isRedoing {
            history.register(before, name: EditorLanguage.text("Edit"), view: textView)
        }
        pendingBefore = nil; pendingRange = nil; structuralNative = false
    }

    private func synchronizeNative(from before: EditorSnapshot) {
        guard let view = textView, let storage = view.textStorage else { return }
        let oldText = before.document.text as NSString
        let newText = storage.string as NSString
        if !oldText.isEqual(to: storage.string) {
            let delta: (NSRange, Int)
            if let pendingRange, NSMaxRange(pendingRange) <= oldText.length {
                let insertedLength = newText.length - oldText.length + pendingRange.length
                if insertedLength >= 0 && pendingRange.location + insertedLength <= newText.length { delta = (pendingRange, insertedLength) }
                else { delta = Self.difference(oldText, newText) }
            } else { delta = Self.difference(oldText, newText) }
            let fragment = TextKitRenderer.decodeNative(storage.attributedSubstring(from: NSRange(location: delta.0.location, length: delta.1)), assets: before.document.assets)
            var next = before.document
            next.replace(delta.0, with: fragment)
            next.revision = state.document.revision &+ 1
            state.document = next
            positionMap = PositionMap(next)
            listCache = ListResolver.resolve(next)
            isApplying = true
            history.withoutRegistration {
                let map = PositionMap(next)
                TextKitRenderer.decorate(next, indices: map.paragraphs(in: NSRange(location: delta.0.location, length: delta.1)), view: view)
            }
            isApplying = false
        }
        state.session.selection = PositionMap(document).clamped(view.selectedRange())
        state.session.affinity = view.selectionAffinity.rawValue
        if history.manager.isUndoing || history.manager.isRedoing { state.session.explicitInsertionStyle = false }
        if !state.session.explicitInsertionStyle { inheritInsertionStyle() }
        updateTypingAttributes()
        // Native key edits (typing, wrapping, paste) bypass the reducer path, so the
        // document would never grow and the caret could sink below the viewport.
        view.scrollSelectionAfterLayout()
        changed()
        assert(document.text == storage.string, "Native input and document diverged")
    }

    static func difference(_ old: NSString, _ new: NSString) -> (NSRange, Int) {
        var start = 0
        while start < min(old.length, new.length), old.character(at: start) == new.character(at: start) { start += 1 }
        // A differing surrogate/combining suffix must not split a grapheme in either string.
        if start < old.length { start = min(start, old.rangeOfComposedCharacterSequence(at: start).location) }
        if start < new.length { start = min(start, new.rangeOfComposedCharacterSequence(at: start).location) }
        var oldEnd = old.length, newEnd = new.length
        while oldEnd > start, newEnd > start, old.character(at: oldEnd - 1) == new.character(at: newEnd - 1) { oldEnd -= 1; newEnd -= 1 }
        if oldEnd > start && oldEnd < old.length {
            let boundary = NSMaxRange(old.rangeOfComposedCharacterSequence(at: oldEnd - 1))
            newEnd += boundary - oldEnd; oldEnd = boundary
        }
        return (NSRange(location: start, length: oldEnd - start), newEnd - start)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !isApplying, nativeDepth == 0, !isComposing, let view = textView else { return }
        let selection = PositionMap(document).clamped(view.selectedRange())
        state.session.affinity = view.selectionAffinity.rawValue
        if selection != state.session.selection {
            selectionExpansion = nil
            state.session.selection = selection
            state.session.explicitInsertionStyle = false
            inheritInsertionStyle()
            updateTypingAttributes()
            publishFormatTransition()
            hooks.emit(.selectionChanged, context: hookContext)
            onChange?()
        }
    }

    private func inheritInsertionStyle() {
        let position = PositionMap(document).position(at: state.session.selection.location)
        let paragraph = document.paragraphs[position.index]
        let index = position.offset > 0 ? position.offset - 1 : 0
        state.session.insertionStyle = paragraph.length > 0 ? (paragraph.slice(NSRange(location: index, length: 1)).first?.style ?? .plain) : .plain
    }

    func updateTypingAttributes() {
        guard !isComposing, let view = textView else { return }
        let index = PositionMap(document).position(at: state.session.selection.location).index
        view.typingAttributes = TextKitRenderer.attributes(state.session.insertionStyle, block: document.paragraphs[index].kind)
        view.typingAttributes[.paragraphStyle] = TextKitRenderer.editorParagraphStyle(index, in: document)
    }

    func beginComposition() {
        guard compositionBefore == nil else { return }
        history.sealTyping(in: textView)
        compositionBefore = state
        compositionPresentation = nil
        pendingRange = nil
        history.manager.disableUndoRegistration()
        onChange?()
    }

    func runMarkedInput(_ action: () -> Void) {
        beginInputHook()
        defer { endInputHook(changed: true) }
        beginComposition()
        compositionPresentation = nil
        nativeDepth += 1
        action()
        nativeDepth -= 1
        compositionDidChange()
        // Empty marked text can end/cancel composition without insertText or unmarkText.
        // Reconcile after the native call so formatting and undo are enabled again.
        finishComposition()
    }

    func finishComposition() {
        guard nativeDepth == 0, let before = compositionBefore, textView?.hasMarkedText() != true else { return }
        beginInputHook()
        defer { endInputHook(changed: before != state) }
        compositionBefore = nil
        compositionPresentation = nil
        pendingRange = nil
        synchronizeNative(from: before)
        history.manager.enableUndoRegistration()
        if state.document != before.document { history.register(before, name: EditorLanguage.text("Typing"), view: textView) }
        pendingBefore = nil
    }

    func requestSave() {
        if let view = textView, view.hasMarkedText() {
            // unmarkText ends the native session; our override synchronizes the committed result first.
            view.unmarkText()
        }
        guard !isComposing else { return }
        onSave?()
    }

    func paste(from pasteboard: NSPasteboard, plainOnly: Bool = false) {
        guard !isComposing,
              let (fragment, preserve) = ClipboardCodec.read(pasteboard, plainOnly: plainOnly, style: state.session.insertionStyle) else { return }
        if !fragment.assets.isEmpty, fragment.text.allSatisfy({ $0 == "\u{FFFC}" }) {
            insertImageFragment(fragment, name: EditorLanguage.text("Paste Image"))
            return
        }
        var insertion = fragment
        let padding = imageBoundaryPadding(for: state.session.selection)
        if padding.before && insertion.paragraphs.first?.isEmpty == false {
            insertion.paragraphs.insert(Paragraph(), at: 0)
        }
        if padding.after && insertion.paragraphs.last?.isEmpty == false {
            insertion.paragraphs.append(Paragraph())
        }
        execute(.replace(state.session.selection, insertion, preserveBlocks: preserve), name: EditorLanguage.text("Paste"))
    }

    /// Only retained attachments need separation; replacing a selected image stays in place.
    func imageBoundaryPadding(for range: NSRange) -> (before: Bool, after: Bool) {
        let range = positionMap.clamped(range)
        let start = positionMap.position(at: range.location)
        let end = positionMap.position(at: NSMaxRange(range))
        let left = document.paragraphs[start.index].slice(NSRange(location: 0, length: start.offset))
        let right = document.paragraphs[end.index].slice(NSRange(location: end.offset,
            length: document.paragraphs[end.index].length - end.offset))
        return (left.contains { $0.assetID != nil }, right.contains { $0.assetID != nil })
    }

    func copy(to pasteboard: NSPasteboard, cut: Bool = false) {
        guard !isComposing, state.session.selection.length > 0 else { return }
        ClipboardCodec.write(document.fragment(in: state.session.selection), to: pasteboard)
        if cut { execute(.replace(state.session.selection, .plain(""), preserveBlocks: false), name: EditorLanguage.text("Cut")) }
    }

    func insertImages(_ images: [NSImage]) {
        let fragment = ClipboardCodec.imageFragment(images)
        guard fragment.canSend else { return }
        insertImageFragment(fragment, name: EditorLanguage.text("Insert Image"))
    }

    private func insertImageFragment(_ fragment: EditorDocument, name: String) {
        let selection = positionMap.clamped(state.session.selection)
        let start = positionMap.position(at: selection.location)
        let end = positionMap.position(at: NSMaxRange(selection))
        var insertion = fragment
        insertion.paragraphs = fragment.paragraphs.flatMap(\.runs).map { Paragraph(runs: [$0]) }
        // Keep images on their own lines without adding blank lines at existing boundaries.
        if start.offset > 0 { insertion.paragraphs.insert(Paragraph(), at: 0) }
        if end.offset < document.paragraphs[end.index].length {
            insertion.paragraphs.append(Paragraph())
        }
        execute(.replace(selection, insertion, preserveBlocks: false), name: name)
    }

    var listItems: [Int: ListResolver.Item] { listCache }

    private func changed() {
        selectionExpansion = nil
        positionMap = PositionMap(document)
        listCache = ListResolver.resolve(document)
        textView?.needsDisplay = true
        publishFormatTransition()
        onChange?()
    }
}
