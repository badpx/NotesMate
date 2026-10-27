import AppKit
import XCTest
@testable import NotesMateEditor

final class DraftFailureTests: XCTestCase {
    func testFailureRetryAndQuitPreserveLatestDraft() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root) // A file cannot serve as the draft directory.
        let store = DraftStore(directory: root)
        let model = NoteEditorModel(drafts: store, restore: false)
        model.bridge.load(.plain("first"))
        XCTAssertFalse(model.prepareToQuit())
        XCTAssertTrue(model.draftPersistenceFailed)
        model.bridge.load(.plain("latest"))
        XCTAssertFalse(model.prepareToQuit())
        XCTAssertEqual(model.bridge.document.text, "latest")
        try FileManager.default.removeItem(at: root)
        XCTAssertTrue(model.prepareToQuit())
        XCTAssertFalse(model.draftPersistenceFailed)
        XCTAssertEqual(try store.restore()?.text, "latest")
    }

    func testAsynchronousFailureIsDeliveredOnMainThreadAndCanRecover() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root)
        let store = DraftStore(directory: root)
        let failure = expectation(description: "failure delivered")
        store.persist(.plain("keep")) { error in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertNotNil(error)
            failure.fulfill()
        }
        wait(for: [failure], timeout: 3)
        try FileManager.default.removeItem(at: root)
        let success = expectation(description: "retry succeeded")
        store.persist(.plain("keep")) { error in
            XCTAssertNil(error)
            success.fulfill()
        }
        wait(for: [success], timeout: 3)
        XCTAssertEqual(try store.restore()?.text, "keep")
    }

    func testObsoleteCompletionDoesNotOverwriteLatestStatus() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DraftStore(directory: root)
        var oldCallback = false
        store.persist(.plain("old")) { _ in oldCallback = true }
        store.flush() // Old completion is queued on main, but a newer generation supersedes it.
        let done = expectation(description: "latest")
        store.persist(.plain("new")) { _ in done.fulfill() }
        wait(for: [done], timeout: 3)
        XCTAssertFalse(oldCallback)
    }
}
