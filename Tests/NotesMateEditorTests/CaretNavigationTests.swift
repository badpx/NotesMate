import AppKit
import XCTest
@testable import NotesMateEditor

final class CaretNavigationTests: XCTestCase {
    func testWrappedBoundaryUsesSelectionAffinity() throws {
        let bridge = AppKitInputBridge()
        let view = EditorTextView.make()
        view.setFrameSize(NSSize(width: 240, height: 1000))
        bridge.attach(view)
        bridge.load(.plain(Array(repeating: "这是用于测试折行的正文 mixed words and text。", count: 40).joined(separator: "\n")))
        let layout = try XCTUnwrap(view.layoutManager)
        let container = try XCTUnwrap(view.textContainer)
        layout.ensureLayout(for: container)
        var checked = 0
        layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) { line, _, _, glyphs, _ in
            let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let text = (view.string as NSString).substring(with: chars)
            let boundary = NSMaxRange(chars)
            guard !text.hasSuffix("\n"), boundary < (view.string as NSString).length else { return }
            let nextGlyph = layout.glyphIndexForCharacter(at: boundary)
            let nextLine = layout.lineFragmentRect(forGlyphAt: nextGlyph, effectiveRange: nil)
            guard nextLine.minY > line.minY else { return }
            for affinity in [NSSelectionAffinity.upstream, .downstream] {
                view.setSelectedRange(NSRange(location: boundary, length: 0), affinity: affinity, stillSelecting: false)
                let expectedLine = affinity == .upstream ? line : nextLine
                let glyph = affinity == .upstream ? glyphs.location : nextGlyph
                let font = view.textStorage!.attribute(.font, at: layout.characterIndexForGlyph(at: glyph), effectiveRange: nil) as! NSFont
                let native = NSRect(x: affinity == .upstream ? 225 : 5, y: view.textContainerOrigin.y + expectedLine.minY, width: 1, height: expectedLine.height)
                let caret = view.insertionPointDrawingRect(native, characterIndex: boundary)
                let baseline = view.textContainerOrigin.y + expectedLine.minY + layout.location(forGlyphAt: glyph).y
                XCTAssertEqual(caret.midY, baseline - (font.ascender + font.descender) / 2, accuracy: 0.001)
                XCTAssertEqual(caret.minX, native.minX)
            }
            checked += 1
        }
        XCTAssertGreaterThan(checked, 20)
    }
    func testGeometryOnlyCaretDoesNotHitTestNextLineAtRightEdge() throws {
        let bridge = AppKitInputBridge()
        let view = EditorTextView.make()
        bridge.attach(view)
        bridge.load(.plain("短行\n" + String(repeating: "长行文字", count: 20) + "\n"))
        let layout = try XCTUnwrap(view.layoutManager)
        layout.ensureLayout(for: view.textContainer!)
        let line = layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        let origin = view.textContainerOrigin
        let left = view.insertionPointDrawingRect(NSRect(x: origin.x + 5, y: origin.y + line.minY, width: 1, height: line.height))
        // A selection rectangle may extend far past the last visible glyph.
        let right = view.insertionPointDrawingRect(NSRect(x: origin.x + 310, y: origin.y + line.minY, width: 1, height: line.height))
        XCTAssertEqual(left.midY, right.midY, accuracy: 0.001)
        XCTAssertEqual(left.height, right.height)
    }

    func testUpstreamDoesNotCrossHardNewlineOrEmptyEOF() throws {
        let bridge = AppKitInputBridge()
        let view = EditorTextView.make()
        bridge.attach(view)
        bridge.load(.plain("第一行\n第二行\n"))
        let layout = try XCTUnwrap(view.layoutManager)
        layout.ensureLayout(for: view.textContainer!)
        for index in [4, 8] {
            view.setSelectedRange(NSRange(location: index, length: 0), affinity: .upstream, stillSelecting: false)
            let line = index == 8 ? layout.extraLineFragmentRect : layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: index), effectiveRange: nil)
            let rect = NSRect(x: 5, y: view.textContainerOrigin.y + line.minY, width: 1, height: line.height)
            let caret = view.insertionPointDrawingRect(rect, characterIndex: index)
            XCTAssertGreaterThanOrEqual(caret.midY, view.textContainerOrigin.y + line.minY)
            XCTAssertLessThan(caret.midY, view.textContainerOrigin.y + line.maxY)
        }
    }

}
