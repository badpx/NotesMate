import AppKit

/// A versioned, self-contained atomic envelope avoids half-written manifest/asset pairs.
final class DraftStore {
    /// Disk state keeps typing intent for an empty draft, never the caret or selected range.
    /// JSONDecoder ignores the old EditorSession selection/affinity keys in existing drafts.
    struct StoredSession: Codable {
        var insertionStyle: InlineStyle
        var explicitInsertionStyle: Bool

        init(_ session: EditorSession) {
            insertionStyle = session.insertionStyle
            explicitInsertionStyle = session.explicitInsertionStyle
        }

        var editorSession: EditorSession {
            var session = EditorSession()
            session.insertionStyle = insertionStyle
            session.explicitInsertionStyle = explicitInsertionStyle
            return session
        }
    }

    struct Envelope: Codable {
        var version = 1
        var document: EditorDocument
        var session: StoredSession?
    }
    let directory: URL
    var url: URL { directory.appendingPathComponent("draft-v1.json") }
    private let queue = DispatchQueue(label: "NotesMate.DraftStore")
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var storedError: Error?
    private(set) var lastError: Error? {
        get { lock.lock(); defer { lock.unlock() }; return storedError }
        set { lock.lock(); storedError = newValue; lock.unlock() }
    }
    private(set) var restoredSession: EditorSession?
    private var damagedSource = false

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NotesMate")) {
        self.directory = directory
    }

    func restore() throws -> EditorDocument? {
        restoredSession = nil
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
                guard envelope.version == 1 else { throw EditorDataError.unsupportedVersion }
                let document = try envelope.document.validated()
                guard document.assets.values.allSatisfy({ NSImage(data: $0.data) != nil }) else { throw EditorDataError.invalidDocument }
                if let session = envelope.session {
                    guard session.insertionStyle.marks.subtracting(.supported).isEmpty else { throw EditorDataError.invalidDocument }
                    if let font = session.insertionStyle.font, ![12, 14, 15, 16, 18, 22, 24].contains(font.size) { throw EditorDataError.invalidDocument }
                }
                restoredSession = document.isPristine ? envelope.session?.editorSession : nil
                return document
            } catch {
                damagedSource = true
                lastError = error
                // Preserve the damaged source before a later draft write replaces it.
                throw error
            }
        }
        return nil
    }

    func persist(_ document: EditorDocument, session: EditorSession? = nil, completion: ((Error?) -> Void)? = nil) {
        lock.lock(); generation &+= 1; let token = generation; lock.unlock()
        var pruned = document
        pruned.pruneAssets()
        let snapshot = pruned
        queue.async { [self] in
            lock.lock(); let current = token == generation; lock.unlock()
            guard current else { return }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if damagedSource, FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.copyItem(at: url, to: directory.appendingPathComponent("draft-recovery-\(UUID().uuidString).json"))
                    damagedSource = false
                }
                let hasInputFormat = session.map { $0.insertionStyle != .plain } ?? false
                if snapshot.isPristine && !hasInputFormat {
                    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                } else {
                    let typingIntent = snapshot.isPristine ? session.map(StoredSession.init) : nil
                    let data = try JSONEncoder().encode(Envelope(document: snapshot, session: typingIntent))
                    try data.write(to: url, options: .atomic)
                }
                lastError = nil
            } catch { lastError = error }
            let error = lastError
            DispatchQueue.main.async { [self] in
                lock.lock(); let current = token == generation; lock.unlock()
                if current { completion?(error) }
            }
        }
    }

    func flush() { queue.sync {} }
}
