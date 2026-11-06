import Foundation

struct NotesFolder: Equatable {
    let id: String
    let name: String
    let accountName: String
}

/// Enumerates Notes folders and persists the user's chosen save target.
enum FolderCatalog {
    struct Selection: Equatable {
        let folder: NotesFolder?
        let revision: UInt64
    }
    private static var selectionRevision: UInt64 = 0
    static var selection: Selection { Selection(folder: target, revision: selectionRevision) }

    /// Called on the main thread after a save, never from the AppleScript queue.
    static func invalidate(_ captured: Selection) {
        guard selection == captured else { return }
        target = nil
    }
    static func fetch(execute: (String) throws -> String = NotesSaver.runScript) throws -> [NotesFolder] {
        parse(try execute(catalogScript))
    }

    /// Tab/newline are not allowed in Notes account and folder names, so a delimited
    /// plain-text result is lossless and avoids parsing AppleScript list literals.
    static let catalogScript = """
        with timeout of 30 seconds
            tell application "Notes"
                set output to ""
                repeat with acc in accounts
                    repeat with f in folders of acc
                        set output to output & (name of acc) & tab & (id of f) & tab & (name of f) & linefeed
                    end repeat
                end repeat
                return output
            end tell
        end timeout
        """

    static func parse(_ output: String) -> [NotesFolder] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3, !fields[1].isEmpty else { return nil }
            return NotesFolder(id: String(fields[1]), name: String(fields[2]), accountName: String(fields[0]))
        }
    }

    private static let idKey = "NotesMate.targetFolder.id"
    private static let nameKey = "NotesMate.targetFolder.name"
    private static let accountKey = "NotesMate.targetFolder.account"
    private static let selectorAvailableKey = "NotesMate.folderSelector.available"

    /// Injectable for tests; production code always uses the standard suite.
    static var defaults: UserDefaults = .standard

    /// A new installation waits until the first successful save before reading folders.
    /// Existing installations keep their previously available folder selector.
    static var isSelectorAvailable: Bool { defaults.bool(forKey: selectorAvailableKey) }

    static func prepareForLaunch(hadOpenedEditorBefore: Bool) {
        guard defaults.object(forKey: selectorAvailableKey) == nil else { return }
        defaults.set(hadOpenedEditorBefore, forKey: selectorAvailableKey)
    }

    static func recordSuccessfulSave() {
        defaults.set(true, forKey: selectorAvailableKey)
    }

    /// The folder new notes are saved into; `nil` means the default folder.
    static var target: NotesFolder? {
        get {
            guard let id = defaults.string(forKey: idKey) else { return nil }
            return NotesFolder(id: id,
                               name: defaults.string(forKey: nameKey) ?? "",
                               accountName: defaults.string(forKey: accountKey) ?? "")
        }
        set {
            selectionRevision &+= 1
            defaults.set(newValue?.id, forKey: idKey)
            defaults.set(newValue?.name, forKey: nameKey)
            defaults.set(newValue?.accountName, forKey: accountKey)
        }
    }
}

/// Main-thread request ordering and selection reconciliation, independent of SwiftUI.
struct FolderRefreshState {
    struct Request {
        let generation: UInt64
        let selection: FolderCatalog.Selection
    }
    private var generation: UInt64 = 0

    mutating func begin() -> Request {
        generation &+= 1
        return Request(generation: generation, selection: FolderCatalog.selection)
    }

    func isCurrent(_ request: Request) -> Bool { request.generation == generation }

    func reconcile(_ list: [NotesFolder], for request: Request) {
        guard isCurrent(request), FolderCatalog.selection == request.selection,
              let target = request.selection.folder else { return }
        // Stable IDs survive account/folder renames; persist the current metadata too.
        let updated = list.first { $0.id == target.id }
        if updated != target { FolderCatalog.target = updated }
    }
}
