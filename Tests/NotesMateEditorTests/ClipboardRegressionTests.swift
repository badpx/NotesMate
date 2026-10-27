import AppKit
import XCTest
@testable import NotesMateEditor

final class ClipboardRegressionTests: XCTestCase {
    func testLiteralListPrefixesAndSurrogatesArePreserved() {
        for format in [NSTextList.MarkerFormat.disc, .decimal] {
            let p = NSMutableParagraphStyle()
            p.textLists = [NSTextList(markerFormat: format, options: 0)]
            for value in ["-20°C", "1.5 米", "*ptr", "😀任务", "𠀀文本", "1😀", "• literal", "1. literal"] {
                XCTAssertEqual(ClipboardCodec.importRich(NSAttributedString(string: value, attributes: [.paragraphStyle: p])).text, value)
            }
        }
    }

    func testTabDelimitedMarkersAcrossRunsAndEmptyItems() {
        let p = NSMutableParagraphStyle()
        p.textLists = [NSTextList(markerFormat: .disc, options: 0)]
        for marker in ["•", "1.", "12."] {
            for body in ["", "-20°C", "😀任务"] {
                let text = NSMutableAttributedString(string: "\t" + marker, attributes: [.paragraphStyle: p])
                text.append(NSAttributedString(string: "\t" + body, attributes: [.paragraphStyle: p, .font: NSFont.boldSystemFont(ofSize: 14)]))
                let result = ClipboardCodec.importRich(text)
                XCTAssertEqual(result.text, body)
                XCTAssertEqual(result.paragraphs[0].kind, .list(.unordered, 1))
            }
        }
    }

    func testOnlyFirstTextRunDeterminesHeading() {
        for firstIsHeading in [false, true] {
            let text = NSMutableAttributedString(string: "首段", attributes: [.font: firstIsHeading ? NSFont.boldSystemFont(ofSize: 22) : NSFont.systemFont(ofSize: 14)])
            text.append(NSAttributedString(string: "后段", attributes: [.font: firstIsHeading ? NSFont.systemFont(ofSize: 14) : NSFont.boldSystemFont(ofSize: 22)]))
            XCTAssertEqual(ClipboardCodec.importRich(text).paragraphs[0].kind, firstIsHeading ? .heading(1) : .body)
        }
    }
}
