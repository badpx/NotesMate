import AppKit
import Foundation
import OSAKit

/// Saves through Notes' AppleScript API without changing focus or using the clipboard.
enum NotesSaver {
    struct NoteContent {
        let bodyHTML: String
        /// One image per occurrence, in the same order as HTMLExporter.imagePlaceholder.
        let images: [NSImage]
        var target: FolderCatalog.Selection = .init(folder: nil, revision: 0)
    }

    enum SaveResult: Equatable {
        case success
        case successUsingDefaultFolder
        case unauthorized(String)
        case failed(String)
        case outcomeUnknown(String)

        var succeeded: Bool { self == .success || self == .successUsingDefaultFolder }
        var errorDetail: String? {
            switch self {
            case .success, .successUsingDefaultFolder: return nil
            case .unauthorized(let detail), .failed(let detail), .outcomeUnknown(let detail): return detail
            }
        }
        var needsAuthorization: Bool {
            if case .unauthorized = self { return true }
            return false
        }
    }

    struct ScriptError: LocalizedError {
        let number: Int
        let message: String
        var errorDescription: String? { message }
    }

    static func runScript(_ source: String) throws -> String {
        guard let language = OSALanguage(forName: "AppleScript"), language.isThreadSafe else {
            throw ScriptError(number: 0, message: EditorLanguage.text("The system AppleScript engine cannot run in the background."))
        }
        // Own the language instance for this invocation: never share a script component
        // across threads. Apple events originate from NotesMate, using its sandbox/TCC
        // permissions, rather than from an external osascript process.
        let instance = OSALanguageInstance(language: language)
        let script = OSAScript(source: source, from: nil, languageInstance: instance, using: [])
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let number = error[OSAScriptErrorNumber] as? Int ?? 0
            NotesAutomationPermission.recordScriptError(number)
            throw ScriptError(number: number,
                              message: error[OSAScriptErrorMessage] as? String ?? EditorLanguage.text("Unable to save to Notes."))
        }
        NotesAutomationPermission.recordScriptSuccess()
        return result?.stringValue ?? ""
    }

    static func save(_ content: NoteContent) -> SaveResult {
        save(content, execute: runScript, folderID: content.target.folder?.id)
    }

    /// Injection keeps automated failure tests out of the user's Notes database.
    static func save(_ content: NoteContent, execute: (String) throws -> String,
                     folderID: String? = nil,
                     temporaryRoot: URL = FileManager.default.temporaryDirectory,
                     verificationAttempts: Int = 20) -> SaveResult {
        let fm = FileManager.default
        let directory = temporaryRoot.appendingPathComponent("NotesMate-\(UUID().uuidString)", isDirectory: true)
        var preserveFiles = false
        var noteID: String?
        var usedDefaultFolder = false
        var creating = false
        var missingNoteID = false
        let started = ISO8601DateFormatter().string(from: Date())
        defer { if !preserveFiles { try? fm.removeItem(at: directory) } }
        do {
            var payloads: [Data] = []
            var paths: [String] = []
            if !content.images.isEmpty { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
            for (i, image) in content.images.enumerated() {
                guard let data = pngData(for: image) else { throw ScriptError(number: 0, message: EditorLanguage.text("Unable to encode the image attachment.")) }
                let file = directory.appendingPathComponent("image-\(i).png")
                try data.write(to: file, options: .atomic)
                payloads.append(data)
                paths.append(file.path)
            }
            let html = try resolveHTML(content.bodyHTML, imagePaths: paths)
            // Acquire the note ID before any attachment work so later failures can roll back.
            // On an ambiguous create error, retain sources rather than assuming no note exists.
            preserveFiles = !paths.isEmpty
            let id: String
            creating = true
            do {
                id = try execute(makeScript(bodyHTML: html.initial, folderID: folderID))
            } catch let error as ScriptError where error.number == -1728 && folderID != nil {
                // Retry once against the default folder. Report the fallback to the
                // main-thread owner, which can conditionally invalidate its selection.
                usedDefaultFolder = true
                id = try execute(makeScript(bodyHTML: html.initial))
            }
            guard !id.isEmpty else {
                missingNoteID = true
                throw ScriptError(number: 0, message: EditorLanguage.text("Notes did not return a note ID. Check whether the note was created."))
            }
            noteID = id
            creating = false
            if !paths.isEmpty {
                _ = try execute(attachmentScript(noteID: id, html: html.final, paths: paths))
                let exports = paths.indices.map { directory.appendingPathComponent("verify-\($0).png") }
                var verified = false
                let deadline = Date().addingTimeInterval(8)
                for attempt in 0..<max(1, verificationAttempts) {
                    for file in exports { try? fm.removeItem(at: file) }
                    do {
                        _ = try execute(verificationScript(noteID: id, exports: exports))
                        verified = zip(exports, payloads).allSatisfy { (try? Data(contentsOf: $0.0)) == $0.1 }
                    } catch let error as ScriptError where error.number == -1743 { throw error }
                    catch { /* Import may still be finishing; retry within a bounded window. */ }
                    if verified || Date() >= deadline { break }
                    if attempt + 1 < verificationAttempts { Thread.sleep(forTimeInterval: 0.1) }
                }
                guard verified else { throw ScriptError(number: 0, message: EditorLanguage.text("Image verification failed. Your draft has been kept.")) }
            }
            preserveFiles = false
            return usedDefaultFolder ? .successUsingDefaultFolder : .success
        } catch {
            var detail = error.localizedDescription
            let unknown = missingNoteID || (creating && (error as? ScriptError)?.number == -1712)
            if unknown {
                let destination = usedDefaultFolder ? EditorLanguage.text("Default Folder")
                    : content.target.folder.map { "\($0.accountName) / \($0.name) (\($0.id))" } ?? folderID ?? EditorLanguage.text("Default Folder")
                detail += EditorLanguage.format("\nThe save result is unknown. Check Notes before retrying to avoid duplicates. Save started at {0}; destination: {1}.",
                    started, destination)
            }
            if let id = noteID {
                do {
                    _ = try execute("with timeout of 10 seconds\ntell application \"Notes\" to delete note id \(quote(id))\nend timeout")
                    preserveFiles = false
                } catch {
                    detail += EditorLanguage.text("\nCould not remove the incomplete note. Check Notes before retrying to avoid duplicates.")
                }
            }
            if preserveFiles { detail += EditorLanguage.format("\nTemporary image files are kept at {0}", directory.path) }
            if let error = error as? ScriptError,
               NotesAutomationPermission.isAuthorizationError(error.number) { return .unauthorized(detail) }
            return unknown ? .outcomeUnknown(detail) : .failed(detail)
        }
    }

    static func resolveHTML(_ html: String, imagePaths: [String]) throws -> (initial: String, final: String) {
        var initial = html
        var final = html
        for (i, path) in imagePaths.enumerated() {
            let marker = HTMLExporter.imagePlaceholder(i)
            guard final.components(separatedBy: marker).count == 2 else {
                throw ScriptError(number: 0, message: EditorLanguage.text("Image positions do not match the text. The note was not saved."))
            }
            initial = initial.replacingOccurrences(of: marker, with: "")
            let url = HTMLExporter.escape(URL(fileURLWithPath: path).absoluteString).replacingOccurrences(of: "\"", with: "&quot;")
            final = final.replacingOccurrences(of: marker, with: "<img src=\"\(url)\">")
        }
        guard !final.contains("<!--NotesMateImage:") else {
            throw ScriptError(number: 0, message: EditorLanguage.text("Image data is missing. The note was not saved."))
        }
        return (initial, final)
    }

    static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Pure-text creation stays a single background AppleEvent transaction.
    static func makeScript(bodyHTML: String, folderID: String? = nil) -> String {
        let target = folderID.map { "folder id \(quote($0))" } ?? "default folder of default account"
        return """
        with timeout of 30 seconds
            tell application "Notes"
                set newNote to make new note at \(target) with properties {body:\(quote(bodyHTML))}
                return id of newNote
            end tell
        end timeout
        """
    }

    static func attachmentScript(noteID: String, html: String, paths: [String]) -> String {
        var lines = ["with timeout of 30 seconds", "tell application \"Notes\"", "set newNote to note id \(quote(noteID))"]
        for path in paths {
            lines.append("make new attachment at newNote with data (POSIX file \(quote(path)))")
        }
        // Local files must first be handed to Notes via its attachment API. Replacing the
        // body then imports exactly the requested occurrences; no name-based deduplication.
        lines.append("set body of newNote to \(quote(html))")
        lines += ["end tell", "end timeout"]
        return lines.joined(separator: "\n")
    }

    static func verificationScript(noteID: String, exports: [URL]) -> String {
        var lines = ["with timeout of 5 seconds", "tell application \"Notes\"", "set n to note id \(quote(noteID))",
                     "if (count of attachments of n) is not \(exports.count) then error \"Image count mismatch\""]
        for (i, file) in exports.enumerated() {
            lines.append("save attachment \(i + 1) of n in POSIX file \(quote(file.path))")
        }
        lines += ["end tell", "end timeout"]
        return lines.joined(separator: "\n")
    }

    static func pngData(for image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
