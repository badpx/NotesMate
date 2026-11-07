import AppKit

final class UndoCoordinator {
    let manager = UndoManager()
    var restore: ((EditorSnapshot) -> Void)?
    var snapshot: (() -> EditorSnapshot)?
    private var nativeGroupGeneration: UInt64 = 0

    init() {
        // We close groups explicitly when switching between native and semantic
        // input. NSUndoManager's queued automatic close cannot safely do that too.
        manager.groupsByEvent = false
    }

    func prepareNativeEvent() {
        guard manager.groupingLevel == 0 else { return }
        // Match event grouping, but own the queued close so sealing can invalidate it.
        manager.beginUndoGrouping()
        nativeGroupGeneration &+= 1
        let generation = nativeGroupGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.nativeGroupGeneration == generation else { return }
            if self.manager.groupingLevel == 1 { self.manager.endUndoGrouping() }
        }
    }

    func sealTyping(in view: NSTextView?) {
        view?.breakUndoCoalescing()
        // This manager is editor-owned. Native AppKit calls must have returned before sealing.
        nativeGroupGeneration &+= 1
        if manager.groupingLevel == 1 { manager.endUndoGrouping() }
        assert(manager.groupingLevel == 0, "Unexpected nested editor undo transaction")
    }

    func register(_ before: EditorSnapshot, name: String, view: NSTextView?) {
        guard !manager.isUndoing, !manager.isRedoing else { return }
        sealTyping(in: view)
        manager.beginUndoGrouping()
        registerRestore(before)
        manager.setActionName(name)
        manager.endUndoGrouping()
    }

    private func registerRestore(_ state: EditorSnapshot) {
        manager.registerUndo(withTarget: self) { target in
            guard let inverse = target.snapshot?() else { return }
            target.registerRestore(inverse)
            target.restore?(state)
        }
    }

    func withoutRegistration(_ body: () -> Void) {
        manager.disableUndoRegistration()
        defer { manager.enableUndoRegistration() }
        body()
    }
}
