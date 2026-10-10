import AppKit
import SwiftUI
import XCTest
@testable import NotesMateEditor

final class EditorAppKitTests: XCTestCase {
    private struct RestoredEditorHost: NSViewRepresentable {
        let bridge: AppKitInputBridge

        func makeNSView(context: Context) -> EditorScrollView {
            let scroll = EditorScrollView()
            scroll.hasVerticalScroller = true
            let editor = EditorTextView.make()
            scroll.documentView = editor
            bridge.attach(editor)
            return scroll
        }

        func updateNSView(_ scroll: EditorScrollView, context: Context) {}
    }

    var bridge: AppKitInputBridge!
    var view: EditorTextView!
    override func setUp() {
        super.setUp()
        bridge = AppKitInputBridge()
        view = EditorTextView.make()
        bridge.attach(view)
    }
    override func tearDown() { view = nil; bridge = nil; super.tearDown() }
    func type(_ text: String) {
        for c in text { view.insertText(String(c), replacementRange: NSRange(location: NSNotFound, length: 0)) }
    }
    func assertProjection(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(view.string, bridge.document.text, file: file, line: line)
        let reference = NSTextStorage(attributedString: TextKitRenderer.render(bridge.document))
        reference.fixAttributes(in: NSRange(location: 0, length: reference.length))
        let actual = NSMutableAttributedString(attributedString: view.textStorage!)
        reference.enumerateAttribute(.attachment, in: NSRange(location: 0, length: reference.length)) { value, range, _ in
            guard let expected = value as? NSTextAttachment else { return }
            let attachment = actual.attribute(.attachment, at: range.location, effectiveRange: nil) as? NSTextAttachment
            XCTAssertNotNil(attachment, file: file, line: line)
            XCTAssertEqual(attachment?.bounds, expected.bounds, file: file, line: line)
            XCTAssertEqual(attachment?.contents, expected.contents, file: file, line: line)
            XCTAssertEqual(attachment?.image?.size, expected.image?.size, file: file, line: line)
        }
        // Independent projections allocate independent attachment objects; compare values, not identity.
        actual.removeAttribute(.attachment, range: NSRange(location: 0, length: actual.length))
        reference.removeAttribute(.attachment, range: NSRange(location: 0, length: reference.length))
        XCTAssertEqual(actual, reference, file: file, line: line)
    }

    func testCaretHeightUsesFontWithoutLineSpacing() {
        for size: CGFloat in [14, 15, 22] {
            let font = NSFont.systemFont(ofSize: size)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 6
            view.typingAttributes = [.font: font, .paragraphStyle: paragraph]
            let natural = view.layoutManager!.defaultLineHeight(for: font)
            for spacing: CGFloat in [0, 4, 10, 72] {
                let rect = NSRect(x: 12, y: 20, width: 1, height: natural + spacing)
                let caret = view.insertionPointDrawingRect(rect)
                XCTAssertEqual(caret.height, natural)
                XCTAssertEqual(caret.minX, rect.minX)
                let center = view.textContainerOrigin.y + view.layoutManager!.extraLineFragmentRect.minY + view.layoutManager!.defaultBaselineOffset(for: font)
                    - (font.ascender + font.descender) / 2
                XCTAssertEqual(caret.midY, center, accuracy: 0.001)
                XCTAssertEqual(caret.width, rect.width + 1)
            }
        }
    }

    func testEmptyLineCaretStaysCenteredWhenTextAppears() {
        for trailing in ["", "\n后"] {
            var centers: [CGFloat] = []
            for content in ["", "x", "文"] {
                bridge.load(.plain("前\n" + content + trailing))
                bridge.select(NSRange(location: 2, length: 0))
                let layout = view.layoutManager!
                layout.ensureLayout(for: view.textContainer!)
                let line = content.isEmpty && trailing.isEmpty
                    ? layout.extraLineFragmentRect
                    : layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: 2), effectiveRange: nil)
                let rect = NSRect(x: view.textContainerOrigin.x + 5,
                                  y: view.textContainerOrigin.y + line.minY, width: 1, height: line.height)
                let caret = view.insertionPointDrawingRect(rect)
                centers.append(caret.midY)
                XCTAssertEqual(caret.height, layout.defaultLineHeight(for: view.typingAttributes[.font] as! NSFont))
            }
            XCTAssertEqual(centers[0], centers[1], accuracy: 0.001)
            XCTAssertEqual(centers[0], centers[2], accuracy: 0.001)
        }
    }

    func testCaretAndSelectionUseLargestFontOnVisualLine() throws {
        bridge.load(.plain("small BIG\nnext"))
        let storage = try XCTUnwrap(view.textStorage)
        let large = NSFont.systemFont(ofSize: 22)
        storage.addAttribute(.font, value: large, range: NSRange(location: 6, length: 3))
        let layout = try XCTUnwrap(view.layoutManager as? EditorLayoutManager)
        layout.ensureLayout(for: view.textContainer!)
        let line = layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        for index in [0, 7] {
            let glyph = layout.glyphIndexForCharacter(at: index)
            let rect = NSRect(x: view.textContainerOrigin.x + layout.location(forGlyphAt: glyph).x,
                              y: view.textContainerOrigin.y + line.minY, width: 1, height: line.height)
            XCTAssertEqual(view.insertionPointDrawingRect(rect).height, layout.defaultLineHeight(for: large))
        }
        let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: 0, length: 3), actualCharacterRange: nil)
        var heights: [CGFloat] = []
        layout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: glyphs, in: view.textContainer!) { rect, _ in heights.append(rect.height) }
        XCTAssertEqual(heights, [layout.defaultLineHeight(for: large)])
    }

    func testEmptyListCaretUsesActualLineDespiteStaleNativeRectangle() throws {
        for kind in [ListKind.ordered, .unordered] {
            bridge.load(EditorDocument(paragraphs: [
                Paragraph(kind: .list(kind, 1), runs: [InlineRun(text: "前面的列表文本")]),
                Paragraph(kind: .list(kind, 1))
            ]))
            bridge.select(NSRange(location: bridge.document.length, length: 0))
            let layout = try XCTUnwrap(view.layoutManager)
            layout.ensureLayout(for: view.textContainer!)
            let extra = layout.extraLineFragmentRect
            let font = TextKitRenderer.font(for: .plain, block: .body)
            let marker = try XCTUnwrap(ListMarkerRenderer.firstLine(1, document: bridge.document,
                map: bridge.positionMap, view: view))
            for offset: CGFloat in [0, -6, -18] {
                let native = NSRect(x: 27, y: view.textContainerOrigin.y + extra.minY + offset,
                                    width: 1, height: extra.height)
                let caret = view.insertionPointDrawingRect(native, characterIndex: bridge.document.length)
                XCTAssertEqual(caret.midY, view.textContainerOrigin.y + marker.1 - (font.ascender + font.descender) / 2, accuracy: 0.001)
                XCTAssertEqual(caret.height, layout.defaultLineHeight(for: font))
            }
        }
    }

    func testCaretHeightMatchesAcrossMiddleLastAndEmptyLines() {
        bridge.load(.plain("面面\n面面\n面面\n"))
        let layout = view.layoutManager!
        layout.ensureLayout(for: view.textContainer!)
        var heights: [CGFloat] = []
        for offset in [0, 3, 6, 9] {
            bridge.select(NSRange(location: offset, length: 0))
            let line = offset == 9 ? layout.extraLineFragmentRect
                : layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: offset), effectiveRange: nil)
            heights.append(view.insertionPointDrawingRect(NSRect(x: view.textContainerOrigin.x + 5,
                y: view.textContainerOrigin.y + line.minY, width: 1, height: line.height)).height)
        }
        bridge.load(.plain("面面\n面面\n面面"))
        bridge.select(NSRange(location: 8, length: 0))
        layout.ensureLayout(for: view.textContainer!)
        let last = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: 6), effectiveRange: nil)
        heights.append(view.insertionPointDrawingRect(NSRect(x: view.textContainerOrigin.x + 5,
            y: view.textContainerOrigin.y + last.minY, width: 1, height: last.height)).height)
        XCTAssertTrue(heights.allSatisfy { $0 == heights[0] })
    }

    func testCaretCentersOnLaidOutTextAndImage() {
        bridge.load(.plain("进来吧\n你是谁？\n不好说"))
        let layout = view.layoutManager!
        layout.ensureLayout(for: view.textContainer!)
        let glyph = layout.glyphIndexForCharacter(at: 5)
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let font = view.textStorage!.attribute(.font, at: 5, effectiveRange: nil) as! NSFont
        let baseline = view.textContainerOrigin.y + line.minY + layout.location(forGlyphAt: glyph).y
        let native = NSRect(x: 50, y: view.textContainerOrigin.y + line.minY, width: 1, height: line.height)
        let caret = view.insertionPointDrawingRect(native)
        XCTAssertEqual(caret.midY, baseline - (font.ascender + font.descender) / 2, accuracy: 0.001)
        XCTAssertEqual(caret.height, layout.defaultLineHeight(for: font))

        let image = NSImage(size: NSSize(width: 80, height: 80))
        image.lockFocus(); NSColor.green.setFill(); NSRect(x: 0, y: 0, width: 80, height: 80).fill(); image.unlockFocus()
        bridge.load(ClipboardCodec.imageFragment([image]))
        layout.ensureLayout(for: view.textContainer!)
        let imageLine = layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        let attachment = view.textStorage!.attribute(.attachment, at: 0, effectiveRange: nil) as! NSTextAttachment
        let imageBaseline = view.textContainerOrigin.y + imageLine.minY + layout.location(forGlyphAt: 0).y
        let imageCaret = view.insertionPointDrawingRect(NSRect(x: view.textContainerOrigin.x, y: view.textContainerOrigin.y + imageLine.minY, width: 1, height: imageLine.height))
        XCTAssertEqual(imageCaret.midY, imageBaseline - attachment.bounds.midY, accuracy: 0.001)
        XCTAssertEqual(imageCaret.height, attachment.bounds.height)
    }

    func testSelectionBackgroundCentersAcrossWrappedAndEmptyLines() throws {
        bridge.load(.plain("将duckduckgo作为默认的搜索后端，并检查其当前的超时配置阈值\n\n末行"))
        let layout = try XCTUnwrap(view.layoutManager as? EditorLayoutManager)
        let container = try XCTUnwrap(view.textContainer)
        layout.ensureLayout(for: container)
        let range = NSRange(location: 0, length: bridge.document.length)
        bridge.select(range)
        let before = bridge.state
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var native: [NSRect] = []
        layout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: glyphs, in: container) { rect, _ in
            native.append(rect.offsetBy(dx: self.view.textContainerOrigin.x, dy: self.view.textContainerOrigin.y))
        }
        let adjusted = native
        XCTAssertGreaterThanOrEqual(adjusted.count, 4)
        for rect in adjusted {
            XCTAssertGreaterThan(rect.width, 0)
            XCTAssertEqual(rect.height, layout.defaultLineHeight(for: TextKitRenderer.font(for: .plain, block: .body)), accuracy: 0.01)
        }
        let font = TextKitRenderer.font(for: .plain, block: .body)
        let baseline = view.textContainerOrigin.y + layout.location(forGlyphAt: 0).y
        XCTAssertEqual(try XCTUnwrap(adjusted.first).midY, baseline - (font.ascender + font.descender) / 2, accuracy: 0.01)
        XCTAssertEqual(bridge.state, before)
    }

    func testSelectionPaintUsesFontHeight() throws {
        bridge.load(.plain("探测duckduckgo可以访问注册它为后端\n下一行"))
        view.selectedTextAttributes = [.backgroundColor: NSColor.magenta]
        bridge.select(NSRange(location: 0, length: 10))
        let layout = try XCTUnwrap(view.layoutManager as? EditorLayoutManager)
        layout.ensureLayout(for: view.textContainer!)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 200,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        layout.drawBackground(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs), at: .zero)
        NSGraphicsContext.restoreGraphicsState()
        let rows = (0..<200).filter { y in
            guard let color = bitmap.colorAt(x: 10, y: y)?.usingColorSpace(.deviceRGB) else { return false }
            return color.alphaComponent > 0.5 && color.redComponent > 0.8 && color.blueComponent > 0.8
        }
        // Fractional rectangle edges can cover one additional raster row.
        let naturalHeight = Int(layout.defaultLineHeight(for: TextKitRenderer.font(for: .plain, block: .body)))
        XCTAssertTrue((naturalHeight...naturalHeight + 1).contains(rows.count), "Painted height: \(rows.count)")
        let glyphs = layout.glyphRange(forCharacterRange: view.selectedRange(), actualCharacterRange: nil)
        var expected: NSRect?
        layout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: glyphs, in: view.textContainer!) { rect, _ in
            if expected == nil { expected = rect }
        }
        let paintedCenter = CGFloat(try XCTUnwrap(rows.first) + (try XCTUnwrap(rows.last)) + 1) / 2
        XCTAssertEqual(paintedCenter, 200 - (try XCTUnwrap(expected)).midY, accuracy: 1)
    }

    func testSelectionTrackingAndRedrawUseIdenticalRectangles() throws {
        bridge.load(.plain("将duckduckgo作为默认的搜索后端\n下一行"))
        let layout = try XCTUnwrap(view.layoutManager as? EditorLayoutManager)
        let container = try XCTUnwrap(view.textContainer)
        layout.ensureLayout(for: container)
        let range = NSRange(location: 1, length: 10)
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        func rectangles(selected: NSRange) -> [NSRect] {
            var result: [NSRect] = []
            layout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: selected, in: container) { rect, _ in result.append(rect) }
            return result
        }
        let original = try XCTUnwrap(rectangles(selected: NSRange(location: NSNotFound, length: 0)).first)
        let tracking = rectangles(selected: glyphs)
        bridge.select(range)
        layout.ensureLayout(for: container)
        XCTAssertEqual(tracking, rectangles(selected: glyphs))
        let adjusted = try XCTUnwrap(tracking.first)
        XCTAssertEqual(adjusted.minX, original.minX, accuracy: 0.001)
        XCTAssertEqual(adjusted.width, original.width, accuracy: 0.001)
        XCTAssertLessThan(adjusted.height, original.height)
        let font = TextKitRenderer.font(for: .plain, block: .body)
        XCTAssertEqual(adjusted.midY, layout.location(forGlyphAt: glyphs.location).y - (font.ascender + font.descender) / 2, accuracy: 0.001)
    }

    func testSelectionBackgroundUsesImageBoundsAndSplitsMergedRects() throws {
        let image = NSImage(size: NSSize(width: 80, height: 80))
        image.lockFocus(); NSColor.green.setFill(); NSRect(x: 0, y: 0, width: 80, height: 80).fill(); image.unlockFocus()
        bridge.load(ClipboardCodec.imageFragment([image]))
        let layout = try XCTUnwrap(view.layoutManager as? EditorLayoutManager)
        layout.ensureLayout(for: view.textContainer!)
        let line = layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
        // 选中图片不再填充背景（改由 drawGlyphs 描边），附件区间被完全扣除。
        XCTAssertTrue(layout.selectionBackgroundRects([line], selectedGlyphs: NSRange(location: 0, length: 1),
                                                      origin: view.textContainerOrigin).isEmpty)
        let attachment = view.textStorage!.attribute(.attachment, at: 0, effectiveRange: nil) as! NSTextAttachment
        let border = try XCTUnwrap(layout.selectionBorderRects(selectedGlyphs: NSRange(location: 0, length: 1),
                                                               origin: view.textContainerOrigin).first)
        XCTAssertEqual(border.height, attachment.bounds.height, accuracy: 0.01)
        XCTAssertEqual(border.width, attachment.bounds.width, accuracy: 0.01)
        // 描边框 == 附件字形的实际绘制包围矩形（四边对称贴着图片边缘）。
        let drawn = layout.boundingRect(forGlyphRange: NSRange(location: 0, length: 1), in: view.textContainer!)
            .offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
        XCTAssertEqual(border, drawn)
        // 未选中附件时没有描边框。
        XCTAssertTrue(layout.selectionBorderRects(selectedGlyphs: NSRange(location: 1, length: 0),
                                                  origin: view.textContainerOrigin).isEmpty)

        bridge.load(.plain("第一行\n第二行\n第三行"))
        layout.ensureLayout(for: view.textContainer!)
        let merged = layout.usedRect(for: view.textContainer!).offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
        let split = layout.selectionBackgroundRects([merged], selectedGlyphs: NSRange(location: 0, length: bridge.document.length), origin: view.textContainerOrigin)
        XCTAssertEqual(split.count, 3)
        XCTAssertTrue(split.allSatisfy { $0.height == split[0].height })
    }

    /// 图文混排整行选中：文字部分保留选区背景，附件区间（含其后的换行区）被扣除，图片只留描边。
    func testSelectionCarvesAttachmentSpansFromBackground() throws {
        let image = NSImage(size: NSSize(width: 40, height: 40))
        image.lockFocus(); NSColor.blue.setFill(); NSRect(x: 0, y: 0, width: 40, height: 40).fill(); image.unlockFocus()
        guard let asset = ClipboardCodec.imageAsset(image) else { return XCTFail("asset") }
        let id = UUID()
        bridge.load(EditorDocument(paragraphs: [Paragraph(runs: [InlineRun(text: "前"), .image(id)])], assets: [id: asset]))
        let layout = try XCTUnwrap(view.layoutManager as? EditorLayoutManager)
        layout.ensureLayout(for: view.textContainer!)
        let all = NSRange(location: 0, length: bridge.document.length)
        let glyphs = layout.glyphRange(forCharacterRange: all, actualCharacterRange: nil)
        let line = layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
            .offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
        let rects = layout.selectionBackgroundRects([line], selectedGlyphs: glyphs, origin: view.textContainerOrigin)
        let textBounds = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: NSRange(location: 0, length: 1),
                                                                              actualCharacterRange: nil),
                                             in: view.textContainer!).offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
        let imageBounds = try XCTUnwrap(layout.selectionBorderRects(selectedGlyphs: glyphs, origin: view.textContainerOrigin).first)
        // 只剩文字区一段背景，右缘不超过图片左缘；图片右侧（换行区）无残留色带。
        XCTAssertEqual(rects.count, 1)
        XCTAssertEqual(rects[0].minX, textBounds.minX, accuracy: 0.01)
        XCTAssertLessThanOrEqual(rects[0].maxX, imageBounds.minX + 0.01)
        // 仅选中图片时整行无背景、只有描边框。
        let imageGlyphs = layout.glyphRange(forCharacterRange: NSRange(location: 1, length: 1), actualCharacterRange: nil)
        XCTAssertTrue(layout.selectionBackgroundRects([line], selectedGlyphs: imageGlyphs, origin: view.textContainerOrigin).isEmpty)
        XCTAssertEqual(layout.selectionBorderRects(selectedGlyphs: imageGlyphs, origin: view.textContainerOrigin).count, 1)
    }

    /// Selection crossing list items must start at each line's text start, never bleed
    /// left into the indent/gutter (AppKit's native rects extend to the fragment edge
    /// whenever the selection covers the line start).
    func testSelectionDoesNotBleedIntoListIndent() throws {
        bridge.load(EditorDocument(paragraphs: [
            Paragraph(kind: .list(.unordered, 1), runs: [InlineRun(text: "列表项甲内容内容内容内容")]),
            Paragraph(kind: .list(.unordered, 1), runs: [InlineRun(text: "列表项乙内容内容内容内容")]),
        ]))
        let layout = try XCTUnwrap(view.layoutManager as? EditorLayoutManager)
        let container = try XCTUnwrap(view.textContainer)
        layout.ensureLayout(for: container)
        // 第一项中间 → 第二项中间
        let selection = NSRange(location: 4, length: 18)
        let glyphs = layout.glyphRange(forCharacterRange: selection, actualCharacterRange: nil)
        var rects: [NSRect] = []
        layout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: glyphs,
                                       in: container) { rect, _ in rects.append(rect) }
        XCTAssertEqual(rects.count, 2)
        let textStart = container.lineFragmentPadding + 22 // L1 缩进后的文字起点
        for rect in rects {
            XCTAssertGreaterThanOrEqual(rect.minX, textStart - 1,
                                        "selection must not bleed into the gutter: \(rect)")
        }
    }

    func testPickedImagesInsertAtSelectionAndUndoTogether() {
        type("前文后文")
        bridge.select(NSRange(location: 2, length: 0))
        let image = NSImage(size: NSSize(width: 20, height: 20))
        image.lockFocus()
        NSColor.green.setFill()
        NSRect(x: 0, y: 0, width: 20, height: 20).fill()
        image.unlockFocus()
        bridge.insertImages([image, image])
        XCTAssertEqual(bridge.document.text, "前文\n\u{FFFC}\n\u{FFFC}\n后文")
        XCTAssertEqual(bridge.document.assetOrder.count, 2)
        XCTAssertEqual(bridge.state.session.selection, NSRange(location: 7, length: 0))
        view.undo(nil)
        XCTAssertEqual(bridge.document.text, "前文后文")
        XCTAssertEqual(bridge.state.session.selection, NSRange(location: 2, length: 0))
        view.redo(nil)
        XCTAssertEqual(bridge.document.text, "前文\n\u{FFFC}\n\u{FFFC}\n后文")
        assertProjection()
    }

    /// 图片段恒为正文（EditorSpec §8.2）：列表项任意落点插入图片，图片独立成正文行，
    /// 列表原文本行的格式保持正确；粘贴与工具栏按钮两条路径一致。
    func testImageInsertionIntoListBreaksOutOfList() {
        let image = NSImage(size: NSSize(width: 20, height: 20))
        image.lockFocus()
        NSColor.green.setFill()
        NSRect(x: 0, y: 0, width: 20, height: 20).fill()
        image.unlockFocus()
        let cases: [(Int, [BlockKind], String)] = [
            // (光标落点, 期望 kind 序列, 期望文本) —— 文档为单个无序列表项 "条目"
            (0, [.body, .list(.unordered, 1)], "\u{FFFC}\n条目"),       // 行首
            (1, [.list(.unordered, 1), .body, .list(.unordered, 1)], "条\n\u{FFFC}\n目"), // 中间
            (2, [.list(.unordered, 1), .body], "条目\n\u{FFFC}"),       // 行尾
        ]
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setData(NotesSaver.pngData(for: image), forType: .png)
        for (offset, kinds, text) in cases {
            for paste in [false, true] {
                bridge.load(EditorDocument(paragraphs: [
                    Paragraph(kind: .list(.unordered, 1), runs: [InlineRun(text: "条目")])]))
                bridge.select(NSRange(location: offset, length: 0))
                if paste { bridge.paste(from: board) } else { bridge.insertImages([image]) }
                XCTAssertEqual(bridge.document.paragraphs.map(\.kind), kinds, "落点 \(offset) paste=\(paste)")
                XCTAssertEqual(bridge.document.text, text, "落点 \(offset) paste=\(paste)")
                let html = HTMLExporter.export(bridge.document).bodyHTML
                XCTAssertTrue(html.contains("<div>\(HTMLExporter.imagePlaceholder(0))</div>"))
                XCTAssertFalse(html.contains("<li>\(HTMLExporter.imagePlaceholder(0))"))
                assertProjection()
                view.undo(nil)
                XCTAssertEqual(bridge.document.text, "条目")
            }
        }
        // 空列表项：图片占据该行成为正文；连续多张各自独立行
        bridge.load(EditorDocument())
        bridge.execute(.list(.ordered))
        bridge.insertImages([image, image])
        XCTAssertEqual(bridge.document.paragraphs.map(\.kind), [.body, .body])
        XCTAssertEqual(bridge.document.text, "\u{FFFC}\n\u{FFFC}")
        XCTAssertEqual(bridge.document.assetOrder.count, 2)
        assertProjection()
    }

    func testImageInsertionRespectsLineBoundaries() {
        let image = NSImage(size: NSSize(width: 20, height: 20))
        image.lockFocus()
        NSColor.green.setFill()
        NSRect(x: 0, y: 0, width: 20, height: 20).fill()
        image.unlockFocus()
        let cases: [(String, NSRange, String)] = [
            ("", NSRange(location: 0, length: 0), "\u{FFFC}"),
            ("正文", NSRange(location: 0, length: 0), "\u{FFFC}\n正文"),
            ("正文", NSRange(location: 2, length: 0), "正文\n\u{FFFC}"),
            ("前\n后", NSRange(location: 2, length: 0), "前\n\u{FFFC}\n后"),
            ("前选中后", NSRange(location: 1, length: 2), "前\n\u{FFFC}\n后"),
            ("前\n后", NSRange(location: 1, length: 0), "前\n\u{FFFC}\n后")
        ]
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setData(NotesSaver.pngData(for: image), forType: .png)
        for (text, range, expected) in cases {
            for paste in [false, true] {
                bridge.load(.plain(text))
                bridge.select(range)
                if paste { bridge.paste(from: board) } else { bridge.insertImages([image]) }
                XCTAssertEqual(bridge.document.text, expected)
                assertProjection()
                view.undo(nil)
                XCTAssertEqual(bridge.document.text, text)
                XCTAssertEqual(bridge.state.session.selection, range)
            }
        }
    }

    func testTextAroundImageStartsSeparateLineIncludingIMEAndPaste() {
        let image = NSImage(size: NSSize(width: 20, height: 20))
        image.lockFocus()
        NSColor.green.setFill()
        NSRect(x: 0, y: 0, width: 20, height: 20).fill()
        image.unlockFocus()
        let source = ClipboardCodec.imageFragment([image])
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("文字", forType: .string)
        for offset in [0, 1] {
            for mode in ["typing", "ime", "paste"] {
                bridge.load(source)
                bridge.select(NSRange(location: offset, length: 0))
                switch mode {
                case "typing": view.insertText("文字", replacementRange: NSRange(location: NSNotFound, length: 0))
                case "ime":
                    view.setMarkedText("wen", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                    XCTAssertEqual(view.string, offset == 0 ? "wen\n\u{FFFC}" : "\u{FFFC}\nwen")
                    view.setMarkedText("文字", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                    view.insertText("文字", replacementRange: view.markedRange())
                default: bridge.paste(from: board)
                }
                XCTAssertEqual(bridge.document.text, offset == 0 ? "文字\n\u{FFFC}" : "\u{FFFC}\n文字")
                XCTAssertEqual(bridge.document.assetOrder.count, 1)
                assertProjection()
                view.undo(nil)
                XCTAssertEqual(bridge.document.text, source.text)
                XCTAssertEqual(bridge.state.session.selection, NSRange(location: offset, length: 0))
                view.redo(nil)
                XCTAssertEqual(bridge.document.text, offset == 0 ? "文字\n\u{FFFC}" : "\u{FFFC}\n文字")
                assertProjection()
            }
        }
        bridge.load(source)
        bridge.select(NSRange(location: 0, length: 1))
        view.insertText("替换", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(bridge.document.text, "替换")
    }

    func testNativeTriggerResetAndUndo_T12_T15_U01_U03() {
        type("**中文**")
        XCTAssertEqual(view.string, "中文")
        XCTAssertTrue(bridge.document.paragraphs[0].runs.first!.style.marks.contains(.bold))
        type("后续")
        XCTAssertEqual(bridge.document.paragraphs[0].runs.last!.style, .plain)
        view.undo(nil)
        XCTAssertEqual(view.string, "中文")
        view.undo(nil)
        XCTAssertEqual(view.string, "**中文**")
        XCTAssertEqual(bridge.state.session.selection.location, 6)
        view.redo(nil)
        XCTAssertEqual(view.string, "中文")
        assertProjection()
    }

    func testEmptyListTypingDeletionAndEOF_M02_M03_L07_U04() {
        type("- ")
        XCTAssertEqual(bridge.document.paragraphs[0].kind, .list(.unordered, 1))
        view.insertTab(nil); view.insertTab(nil)
        XCTAssertEqual(bridge.document.paragraphs[0].kind, .list(.unordered, 3))
        view.layoutManager!.ensureLayout(for: view.textContainer!)
        XCTAssertEqual(view.layoutManager!.extraLineFragmentUsedRect.minX, 66)
        type("a")
        view.deleteBackward(nil)
        XCTAssertTrue(bridge.document.paragraphs[0].isEmpty)
        XCTAssertEqual(bridge.document.paragraphs[0].kind, .list(.unordered, 3))
        view.insertNewline(nil)
        XCTAssertEqual(bridge.document.paragraphs[0].kind, .list(.unordered, 2))
        view.undo(nil)
        XCTAssertEqual(bridge.document.paragraphs[0].kind, .list(.unordered, 3))
        type("a"); view.insertNewline(nil)
        XCTAssertEqual(bridge.document.paragraphs.count, 2)
        XCTAssertEqual(bridge.document.paragraphs[1].kind, .list(.unordered, 3))
        assertProjection()
    }

    func testCrossParagraphNativeDeleteUndo_M10_K12_U05() {
        type("# A"); view.insertNewline(nil); type("B")
        let before = bridge.document.paragraphs
        bridge.select(NSRange(location: 1, length: 1))
        view.deleteForward(nil)
        XCTAssertEqual(view.string, "AB")
        view.undo(nil)
        XCTAssertEqual(bridge.document.paragraphs, before)
        assertProjection()
    }

    func testNativeDeleteWordAndUnicode_M07_K11() {
        type("中👩🏽‍💻e\u{301}")
        view.deleteBackward(nil)
        XCTAssertEqual(view.string, "中👩🏽‍💻")
        view.deleteBackward(nil)
        XCTAssertEqual(view.string, "中")
        bridge.load(.plain("hello word")); bridge.select(NSRange(location: 10, length: 0))
        view.deleteWordBackward(nil)
        XCTAssertEqual(view.string, "hello ")
        assertProjection()
    }

    func testCompositionCommitSkipsTrigger_I01_I02_I04_U06() {
        view.setMarkedText("**中**", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(bridge.isComposing)
        XCTAssertEqual(bridge.document.text, "")
        view.insertText("**中**", replacementRange: view.markedRange())
        XCTAssertFalse(bridge.isComposing)
        XCTAssertEqual(bridge.document.text, "**中**")
        XCTAssertFalse(bridge.document.paragraphs[0].runs[0].style.marks.contains(.bold))
        view.undo(nil)
        XCTAssertEqual(view.string, "")
    }

    func testKeyboardSaveAndFormatting_K14_K17() {
        var saves = 0
        bridge.onSave = { saves += 1 }
        for code: UInt16 in [36, 76] {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
                                        context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: code)!
            XCTAssertTrue(view.performKeyEquivalent(with: event))
        }
        XCTAssertEqual(saves, 2)
        bridge.execute(.toggle(.bold)); type("x")
        XCTAssertTrue(bridge.document.paragraphs[0].runs[0].style.marks.contains(.bold))
        bridge.select(NSRange(location: 0, length: 1)); bridge.execute(.toggle(.italic))
        let obliqueness = view.textStorage!.attribute(.obliqueness, at: 0, effectiveRange: nil) as? NSNumber
        XCTAssertEqual(obliqueness?.doubleValue, 0.25)
        bridge.select(NSRange(location: 1, length: 0))
        let selectAll = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
            context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
        XCTAssertTrue(view.performKeyEquivalent(with: selectAll))
        XCTAssertEqual(bridge.state.session.selection, NSRange(location: 0, length: 1))
    }

    func testCommandAExpandsListSelectionAndResetsAfterCaretMove() {
        let document = EditorDocument(paragraphs: [
            Paragraph(runs: [InlineRun(text: "body")]),
            Paragraph(kind: .list(.unordered, 1), runs: [InlineRun(text: "root")]),
            Paragraph(kind: .list(.unordered, 2), runs: [InlineRun(text: "child")]),
            Paragraph(kind: .list(.unordered, 3), runs: [InlineRun(text: "leaf")]),
            Paragraph(kind: .list(.unordered, 1), runs: [InlineRun(text: "sibling")]),
            Paragraph(runs: [InlineRun(text: "tail")]),
        ])
        bridge.load(document)
        let map = PositionMap(document)
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
            context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
        func press(_ expected: NSRange) {
            XCTAssertTrue(view.performKeyEquivalent(with: event))
            XCTAssertEqual(bridge.state.session.selection, expected)
            XCTAssertEqual(view.selectedRange(), expected)
        }
        bridge.select(NSRange(location: map.starts[3] + 2, length: 0))
        press(map.range(of: 3))
        press(NSRange(location: map.starts[1], length: NSMaxRange(map.range(of: 3)) - map.starts[1]))
        press(NSRange(location: 0, length: map.length))
        press(NSRange(location: 0, length: map.length))

        bridge.select(NSRange(location: map.starts[2] + 1, length: 0))
        press(map.range(of: 2)) // The first selection excludes its level-three child.
        press(NSRange(location: map.starts[1], length: NSMaxRange(map.range(of: 3)) - map.starts[1]))
        press(NSRange(location: 0, length: map.length))

        bridge.select(NSRange(location: map.starts[1] + 1, length: 0))
        press(map.range(of: 1))
        press(NSRange(location: 0, length: map.length))

        bridge.select(NSRange(location: map.starts[0] + 2, length: 0))
        press(map.range(of: 0))
        press(NSRange(location: 0, length: map.length))
        view.setSelectedRange(NSRange(location: map.starts[5] + 1, length: 0))
        view.selectAll(nil) // Menu action follows the same selection path.
        XCTAssertEqual(view.selectedRange(), map.range(of: 5))
    }

    func testCommandAOnEmptyParagraphAndAfterEdit() {
        bridge.load(.plain("first\n\nlast"))
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
            context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
        bridge.select(NSRange(location: 6, length: 0))
        XCTAssertTrue(view.performKeyEquivalent(with: event))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: bridge.document.length))
        XCTAssertTrue(view.performKeyEquivalent(with: event))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: bridge.document.length))

        bridge.select(NSRange(location: 2, length: 0))
        view.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.performKeyEquivalent(with: event))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 6))
    }

    func testCommandASkipsEmptyListItem() {
        let document = EditorDocument(paragraphs: [
            Paragraph(runs: [InlineRun(text: "before")]),
            Paragraph(kind: .list(.unordered, 1), runs: [InlineRun(text: "root")]),
            Paragraph(kind: .list(.unordered, 2)),
            Paragraph(kind: .list(.unordered, 3), runs: [InlineRun(text: "child")]),
            Paragraph(kind: .list(.ordered, 1)),
            Paragraph(runs: [InlineRun(text: "after")]),
        ])
        bridge.load(document)
        let map = PositionMap(document)
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
            context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
        bridge.select(NSRange(location: map.starts[2], length: 0))
        XCTAssertTrue(view.performKeyEquivalent(with: event))
        XCTAssertEqual(view.selectedRange(), NSRange(location: map.starts[1],
            length: NSMaxRange(map.range(of: 3)) - map.starts[1]))
        XCTAssertTrue(view.performKeyEquivalent(with: event))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: map.length))

        bridge.select(NSRange(location: map.starts[4], length: 0))
        XCTAssertTrue(view.performKeyEquivalent(with: event))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: map.length))
    }

    func testCommandASelectsWholeCodeBlockBeforeDocument() {
        let document = EditorDocument(paragraphs: [
            Paragraph(runs: [InlineRun(text: "before")]),
            Paragraph(kind: .codeLine, runs: [InlineRun(text: "first")]),
            Paragraph(kind: .codeLine),
            Paragraph(kind: .codeLine, runs: [InlineRun(text: "last")]),
            Paragraph(runs: [InlineRun(text: "after")]),
        ])
        bridge.load(document)
        let map = PositionMap(document)
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
            context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
        let block = NSRange(location: map.starts[1], length: NSMaxRange(map.range(of: 3)) - map.starts[1])
        for index in 1...3 {
            bridge.select(NSRange(location: map.starts[index], length: 0))
            XCTAssertTrue(view.performKeyEquivalent(with: event))
            XCTAssertEqual(view.selectedRange(), block)
            XCTAssertTrue(view.performKeyEquivalent(with: event))
            XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: map.length))
        }
    }

    func testFormattingEndsCompositionAndKeepsText() {
        for command: EditorCommand in [.block(.heading(2)), .list(.unordered), .list(.ordered)] {
            bridge.load(EditorDocument())
            view.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            bridge.execute(command)
            XCTAssertFalse(bridge.isComposing)
            XCTAssertFalse(view.hasMarkedText())
            XCTAssertEqual(bridge.document.text, "中文")
            XCTAssertNotEqual(bridge.document.paragraphs[0].kind, .body)
            view.undo(nil)
            XCTAssertEqual(bridge.document.text, "中文")
            XCTAssertEqual(bridge.document.paragraphs[0].kind, .body)
            view.undo(nil)
            XCTAssertEqual(bridge.document.text, "")
        }
    }

    func testFormatShortcutDuringCompositionAndNextInput() {
        view.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
            context: nil, characters: "b", charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11)!
        XCTAssertTrue(view.performKeyEquivalent(with: event))
        XCTAssertFalse(bridge.isComposing)
        XCTAssertTrue(bridge.state.session.insertionStyle.marks.contains(.bold))
        view.setMarkedText("继续", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertText("继续", replacementRange: view.markedRange())
        XCTAssertEqual(bridge.document.text, "中文继续")
        XCTAssertTrue(bridge.document.paragraphs[0].runs.last!.style.marks.contains(.bold))
        assertProjection()
    }

    func testPastePlainRichAndInternalClipboard_P01_P03_P09_P11() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("- **原文**\n``` ", forType: .string)
        bridge.paste(from: pasteboard)
        XCTAssertEqual(bridge.document.text, "- **原文**\n``` ")
        XCTAssertTrue(bridge.document.paragraphs.allSatisfy { $0.kind == .body })
        let style = NSMutableParagraphStyle()
        style.textLists = [NSTextList(markerFormat: .decimal, options: 0), NSTextList(markerFormat: .disc, options: 0)]
        let rich = NSAttributedString(string: "粘贴", attributes: [.font: NSFont(name: "Times New Roman", size: 23)!,
            .paragraphStyle: style, .underlineStyle: 1, .strikethroughStyle: 1, .link: "https://example.com", .foregroundColor: NSColor.red])
        let fragment = ClipboardCodec.importRich(rich)
        XCTAssertEqual(fragment.paragraphs[0].kind, .list(.unordered, 2))
        XCTAssertNil(fragment.paragraphs[0].runs[0].style.font) // 字号归一正文（EditorSpec §8）
        bridge.load(fragment)
        bridge.select(NSRange(location: 0, length: fragment.length))
        bridge.copy(to: pasteboard)
        bridge.load(EditorDocument())
        bridge.paste(from: pasteboard)
        XCTAssertEqual(bridge.document.paragraphs[0].kind, .list(.unordered, 2))
        XCTAssertNil(view.textStorage!.attribute(.link, at: 0, effectiveRange: nil))
        assertProjection()
    }

    func testFontTiers_P02_L10() {
        // 字号归一正文：非粗体不产生标题档（EditorSpec §8）
        for size in [16, 17, 20, 21, 22, 24] {
            let rich = NSAttributedString(string: "x", attributes: [.font: NSFont.systemFont(ofSize: CGFloat(size))])
            XCTAssertNil(ClipboardCodec.importRich(rich).paragraphs[0].runs[0].style.font)
            XCTAssertEqual(ClipboardCodec.importRich(rich).paragraphs[0].kind, .body)
        }
        // 粗体大字号映射到标题档位（kind=heading），粗体经 marks 保留
        let bold24 = NSAttributedString(string: "x", attributes: [.font: NSFont.boldSystemFont(ofSize: 24)])
        XCTAssertEqual(ClipboardCodec.importRich(bold24).paragraphs[0].kind, .heading(1))
        XCTAssertNil(ClipboardCodec.importRich(bold24).paragraphs[0].runs[0].style.font)
        XCTAssertTrue(ClipboardCodec.importRich(bold24).paragraphs[0].runs[0].style.marks.contains(.bold))
        let bold18 = NSAttributedString(string: "x", attributes: [.font: NSFont.boldSystemFont(ofSize: 18)])
        XCTAssertEqual(ClipboardCodec.importRich(bold18).paragraphs[0].kind, .heading(2))
        // 等宽优先保留为代码字体，不参与标题判定
        let mono = NSAttributedString(string: "x", attributes: [.font: NSFont(name: "Courier", size: 24)!])
        XCTAssertEqual(ClipboardCodec.importRich(mono).paragraphs[0].kind, .body)
        XCTAssertEqual(ClipboardCodec.importRich(mono).paragraphs[0].runs[0].style.font, FontIntent(size: 14, monospaced: true))
    }

    /// Bug 回归：列表空项上粘贴普通富文本，列表不得消失——首行继承列表项格式，后续行成为同级列表项。
    func testPasteRichIntoEmptyListItemKeepsList() {
        type("- 项目")
        view.insertNewline(nil) // 新的空列表项
        XCTAssertEqual(bridge.document.paragraphs.map(\.kind), [.list(.unordered, 1), .list(.unordered, 1)])

        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let rich = NSMutableAttributedString(string: "第一行\n第二行")
        rich.addAttribute(.font, value: NSFont.systemFont(ofSize: 14),
                          range: NSRange(location: 0, length: rich.length))
        board.setData(rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]), forType: .rtf)
        bridge.paste(from: board)

        XCTAssertEqual(bridge.document.text, "项目\n第一行\n第二行")
        XCTAssertEqual(bridge.document.paragraphs.map(\.kind),
                       [.list(.unordered, 1), .list(.unordered, 1), .list(.unordered, 1)])
        assertProjection()
    }

    /// 规则：粘贴的标题赋予 heading kind 并独立成段——空列表项中粘贴标题，标题占据该段（跳出列表）。
    func testPasteHeadingIntoEmptyListItemBreaksOut() {
        type("- 项目")
        view.insertNewline(nil)

        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let rich = NSMutableAttributedString(string: "第一行\n第二行")
        rich.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 24),
                          range: NSRange(location: 0, length: rich.length))
        board.setData(rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]), forType: .rtf)
        bridge.paste(from: board)

        XCTAssertEqual(bridge.document.text, "项目\n第一行\n第二行")
        XCTAssertEqual(bridge.document.paragraphs.map(\.kind),
                       [.list(.unordered, 1), .heading(1), .heading(1)])
        assertProjection()
    }

    /// 规则：粘贴标题按落点分三分支——空正文→标题成段；非空落点→降级为加粗内联文本（不切割、
    /// 列表不跳出）；空列表项→标题占据该行。光标永远在粘贴内容末尾；Backspace 降级为纯正文。
    func testPastedHeadingGetsOwnParagraphEverywhere() {
        // 落点 1：空正文（空文档）——标题成段，尾部无多余空行
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let heading = NSAttributedString(string: "大标题", attributes: [.font: NSFont.boldSystemFont(ofSize: 24)])
        board.setData(heading.rtf(from: NSRange(location: 0, length: heading.length), documentAttributes: [:]), forType: .rtf)
        bridge.paste(from: board)
        XCTAssertEqual(bridge.document.paragraphs.map(\.kind), [.heading(1)])
        XCTAssertEqual(bridge.document.text, "大标题")
        XCTAssertEqual(bridge.state.session.selection.location, 3, "落点 1 光标在粘贴内容末尾")

        // 段首 Backspace → 降级为纯正文：kind 为 body，粘贴自带的显式粗体一并清除
        bridge.select(NSRange(location: 0, length: 0))
        view.deleteBackward(nil)
        XCTAssertEqual(bridge.document.paragraphs[0].kind, .body)
        XCTAssertEqual(bridge.document.text, "大标题")
        XCTAssertFalse(bridge.document.paragraphs[0].runs[0].style.marks.contains(.bold),
                       "降级后不带粗体 marks")

        // 落点 2：正文段落中间——降级为加粗内联文本，不切割段落
        bridge.load(EditorDocument())
        type("前后")
        bridge.select(NSRange(location: 1, length: 0))
        bridge.paste(from: board)
        XCTAssertEqual(bridge.document.paragraphs.map(\.kind), [.body])
        XCTAssertEqual(bridge.document.text, "前大标题后")
        XCTAssertEqual(bridge.state.session.selection.location, 4, "落点 2 光标在粘贴内容末尾")
        XCTAssertTrue(bridge.document.paragraphs[0].runs[1].style.marks.contains(.bold), "内联降级保留粗体")

        // 落点 3：列表项中间——列表项仍是列表项，不跳出
        bridge.load(EditorDocument())
        type("- 项目")
        bridge.select(NSRange(location: 1, length: 0))
        bridge.paste(from: board)
        XCTAssertEqual(bridge.document.paragraphs.map(\.kind), [.list(.unordered, 1)])
        XCTAssertEqual(bridge.document.text, "项大标题目")
        XCTAssertEqual(bridge.state.session.selection.location, 4, "落点 3 光标在粘贴内容末尾")

        // 落点 4：空列表项——标题占据该行（跳出列表），无尾部空行
        bridge.load(EditorDocument())
        type("- 项目")
        view.insertNewline(nil)
        bridge.paste(from: board)
        XCTAssertEqual(bridge.document.paragraphs.map(\.kind), [.list(.unordered, 1), .heading(1)])
        XCTAssertEqual(bridge.document.text, "项目\n大标题")
        XCTAssertEqual(bridge.state.session.selection.location, 6, "落点 4 光标在粘贴内容末尾")

        // 落点 5：正文行尾——同样内联降级，不换行
        bridge.load(EditorDocument())
        type("前文")
        bridge.select(NSRange(location: 2, length: 0))
        bridge.paste(from: board)
        XCTAssertEqual(bridge.document.paragraphs.map(\.kind), [.body])
        XCTAssertEqual(bridge.document.text, "前文大标题")
        XCTAssertEqual(bridge.state.session.selection.location, 5, "落点 5 光标在标题末尾")
        assertProjection()
    }

    /// 补充规则：多行片段首段按落点规则、后续段落保持自身 kind（标题仍独立成段）。
    func testPastedMultilineHeadingFirstDegradesRestStays() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let rich = NSMutableAttributedString(string: "大标题\n次标题")
        rich.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 24), range: NSRange(location: 0, length: rich.length))
        board.setData(rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]), forType: .rtf)
        type("前后")
        bridge.select(NSRange(location: 1, length: 0))
        bridge.paste(from: board)
        // 首段降级内联（加粗），次段保持标题独立成段，目标行后缀独立成段
        XCTAssertEqual(bridge.document.paragraphs.map(\.kind), [.body, .heading(1), .body])
        XCTAssertEqual(bridge.document.text, "前大标题\n次标题\n后")
        XCTAssertEqual(bridge.state.session.selection.location, 8, "光标在多行粘贴内容末尾")
        assertProjection()
    }

    /// Bug 回归：降级只去粗体，不误伤同段其它刻意格式（斜体保留）。
    func testDegradePastedHeadingKeepsItalicButNotBold() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let font = NSFontManager.shared.convert(NSFont.boldSystemFont(ofSize: 24), toHaveTrait: .italicFontMask)
        let heading = NSAttributedString(string: "粗斜标题", attributes: [.font: font])
        board.setData(heading.rtf(from: NSRange(location: 0, length: heading.length), documentAttributes: [:]), forType: .rtf)
        bridge.paste(from: board)
        XCTAssertEqual(bridge.document.paragraphs[0].kind, .heading(1))
        XCTAssertTrue(bridge.document.paragraphs[0].runs[0].style.marks.contains(.bold))
        XCTAssertTrue(bridge.document.paragraphs[0].runs[0].style.marks.contains(.italic))

        bridge.select(NSRange(location: 0, length: 0))
        view.deleteBackward(nil)
        XCTAssertEqual(bridge.document.paragraphs[0].kind, .body)
        XCTAssertFalse(bridge.document.paragraphs[0].runs[0].style.marks.contains(.bold))
        XCTAssertTrue(bridge.document.paragraphs[0].runs[0].style.marks.contains(.italic), "斜体保留")
    }

    /// Bug 回归：纯文本/多行/行内粘贴的光标落点均在粘贴内容末尾。
    func testPasteCursorLandsAtEndOfInsertedContent() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }

        // 纯文本行尾
        type("前文")
        board.setString("X", forType: .string)
        bridge.paste(from: board)
        XCTAssertEqual(bridge.document.text, "前文X")
        XCTAssertEqual(bridge.state.session.selection.location, 3, "纯文本行尾")

        // 多行纯文本：首行并入当前段落（标准粘贴行为），光标在末尾
        bridge.load(EditorDocument())
        type("前文")
        board.clearContents()
        board.setString("一\n二", forType: .string)
        bridge.paste(from: board)
        XCTAssertEqual(bridge.document.text, "前文一\n二")
        XCTAssertEqual(bridge.state.session.selection.location, bridge.document.length, "多行纯文本末尾")

        // 列表项中多行富文本 → 首行并入当前项，后续行同级列表项，光标在末尾
        bridge.load(EditorDocument())
        type("- 项目")
        bridge.select(NSRange(location: 2, length: 0))
        let rich = NSMutableAttributedString(string: "甲\n乙")
        rich.addAttribute(.font, value: NSFont.systemFont(ofSize: 14), range: NSRange(location: 0, length: rich.length))
        board.clearContents()
        board.setData(rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]), forType: .rtf)
        bridge.paste(from: board)
        XCTAssertEqual(bridge.document.text, "项目甲\n乙")
        XCTAssertEqual(bridge.document.paragraphs.map(\.kind),
                       [.list(.unordered, 1), .list(.unordered, 1)])
        XCTAssertEqual(bridge.state.session.selection.location, bridge.document.length, "列表多行粘贴末尾")
        assertProjection()
    }

    /// Bug 回归：Chromium 系复制的「标题 + 空列表项」片段把标记符写进文本（\t•\t），
    /// 剥离后保留一个空列表项——标题下方只出现一个项目符（剪切板实测样本形态）。
    func testPasteStripsListMarkerTextFromListParagraphs() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setData("<meta charset=\"utf-8\"><h2><b>文档同步</b></h2><ul><li></li></ul><br>".data(using: .utf8), forType: .html)
        board.setString("文档同步\n", forType: .string)
        bridge.paste(from: board)
        XCTAssertEqual(bridge.document.paragraphs.map(\.kind), [.heading(2), .list(.unordered, 1)])
        XCTAssertEqual(bridge.document.text, "文档同步\n")
        XCTAssertTrue(bridge.document.paragraphs[1].isEmpty, "标记符剥离后为空列表项")
        assertProjection()
    }

    /// 变体：标题 + 非空列表项——条目文本保留，标记符不重复出现。
    func testPasteStripsMarkerButKeepsItemText() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setData("<meta charset=\"utf-8\"><h2><b>文档同步</b></h2><ul><li>内容</li></ul>".data(using: .utf8), forType: .html)
        board.setString("文档同步\n内容", forType: .string)
        bridge.paste(from: board)
        XCTAssertEqual(bridge.document.paragraphs.map(\.kind), [.heading(2), .list(.unordered, 1)])
        XCTAssertEqual(bridge.document.text, "文档同步\n内容")
        assertProjection()
    }

    /// Bug 回归：非空落点粘贴标题降级为加粗内联文本后，字体族与字号与正文逐字节一致（只多粗体）。
    /// （HEAD 旧档位逻辑下该 run 残留 FontIntent(18) → 渲染 18px 比正文大一号。）
    func testDegradedPastedHeadingMatchesBodyFontExactly() {
        type("前后")
        bridge.select(NSRange(location: 1, length: 0))
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let rich = NSAttributedString(string: "标题", attributes: [.font: NSFont(name: "HelveticaNeue-Bold", size: 18)!])
        board.setData(rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]), forType: .rtf)
        bridge.paste(from: board)

        XCTAssertEqual(bridge.document.text, "前标题后")
        let runs = bridge.document.paragraphs[0].runs
        XCTAssertEqual(runs.count, 3)
        XCTAssertTrue(runs[1].style.marks.contains(.bold))
        XCTAssertNil(runs[1].style.font, "降级路径已清空字体档位")

        // 渲染层逐字节比对：族与字号与正文一致，仅多粗体 trait
        let storage = view.textStorage!
        let bodyFont = storage.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        let pastedFont = storage.attribute(.font, at: 1, effectiveRange: nil) as! NSFont
        XCTAssertEqual(pastedFont.pointSize, bodyFont.pointSize)
        XCTAssertEqual(pastedFont.familyName, bodyFont.familyName)
        XCTAssertTrue(NSFontManager.shared.traits(of: pastedFont).contains(.boldFontMask))

        // 取消粗体后与正文逐字节一致
        bridge.select(NSRange(location: 1, length: 2))
        bridge.execute(.toggle(.bold), name: EditorLanguage.text("Bold"))
        let unbolded = view.textStorage!.attribute(.font, at: 1, effectiveRange: nil) as! NSFont
        let bodyFontAfter = view.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        XCTAssertEqual(unbolded, bodyFontAfter)
        assertProjection()
    }

    /// Bug 回归：HTML 片段尾部的段落结束符不产生空行（含 <div><br></div> 尾巴的形态）。
    func testPasteTrimsTrailingEmptyParagraphs() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setData("<meta charset=\"utf-8\"><h1><b>大标题</b></h1><div><br></div>".data(using: .utf8), forType: .html)
        board.setString("大标题\n\n", forType: .string)
        bridge.paste(from: board)
        XCTAssertEqual(bridge.document.paragraphs.count, 1)
        XCTAssertEqual(bridge.document.text, "大标题")

        // 内部空行保留：多行粘贴的内部换行不受影响
        bridge.load(EditorDocument())
        board.clearContents()
        board.setString("甲\n\n乙\n", forType: .string)
        bridge.paste(from: board)
        XCTAssertEqual(bridge.document.text, "甲\n\n乙")
        XCTAssertEqual(bridge.document.paragraphs.count, 3)
    }

    /// 多行粘贴进列表项：首段继承目标格式，后续行中的自带列表段落保留自身层级（可嵌套）。
    func testPasteListFragmentIntoListItemKeepsNesting() {
        type("- 项目")
        view.insertNewline(nil)
        // 内部剪贴板：两行的二级有序列表片段
        let fragment = EditorDocument(paragraphs: [
            Paragraph(kind: .list(.ordered, 2), runs: [InlineRun(text: "自带甲")]),
            Paragraph(kind: .list(.ordered, 2), runs: [InlineRun(text: "自带乙")]),
        ])
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        ClipboardCodec.write(fragment, to: board)
        bridge.paste(from: board)
        // 首段并入空列表项（无序一级），第二段保留自身层级（有序二级 → 形成嵌套）
        XCTAssertEqual(bridge.document.paragraphs.map(\.kind),
                       [.list(.unordered, 1), .list(.unordered, 1), .list(.ordered, 2)])
        XCTAssertEqual(bridge.document.text, "项目\n自带甲\n自带乙")
        assertProjection()
    }

    func testImageRepresentationsAttachmentsAndUndo_P04_P08_M06_E06() {
        let image = NSImage(size: NSSize(width: 200, height: 100))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 200, height: 100).fill(); image.unlockFocus()
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.setData(NotesSaver.pngData(for: image), forType: .png)
        board.setData(image.tiffRepresentation, forType: .tiff)
        bridge.paste(from: board)
        XCTAssertEqual(bridge.document.assetOrder.count, 1)
        let attachment = view.textStorage!.attribute(.attachment, at: 0, effectiveRange: nil) as! NSTextAttachment
        XCTAssertEqual(attachment.bounds.height, 72)
        XCTAssertEqual(attachment.bounds.width, 144)
        XCTAssertFalse(HTMLExporter.export(bridge.document).bodyHTML.contains("\u{FFFC}"))
        view.undo(nil); XCTAssertEqual(bridge.document.assetOrder.count, 0)
        view.redo(nil); XCTAssertEqual(bridge.document.assetOrder.count, 1)
        board.setData(Data([1, 2, 3]), forType: .png)
        XCTAssertEqual(ClipboardCodec.images(on: board).count, 1)
    }

    func testIncrementalProjectionMatchesFullAfterMixedCommands() {
        for input in ["# 标题", "body", "- item", "next", "``` code"] {
            type(input); view.insertNewline(nil); assertProjection()
        }
        bridge.select(NSRange(location: 0, length: bridge.document.length))
        bridge.execute(.list(.ordered)); assertProjection()
        bridge.execute(.indent(1)); assertProjection()
        bridge.execute(.toggle(.strike)); assertProjection()
        for _ in 0..<3 { view.undo(nil); assertProjection() }
        for _ in 0..<3 { view.redo(nil); assertProjection() }
    }

    func testDefaultTypingUndoMatchesNative_U02() {
        final class NativeView: NSTextView {
            let history = UndoManager()
            override var undoManager: UndoManager? { history }
        }
        let native = NativeView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        native.allowsUndo = true
        for c in "hello ** incomplete" {
            native.insertText(String(c), replacementRange: NSRange(location: NSNotFound, length: 0))
            type(String(c))
        }
        native.breakUndoCoalescing()
        if native.history.groupingLevel == 1 { native.history.endUndoGrouping() }
        native.history.undo(); view.undo(nil)
        XCTAssertEqual(view.string, native.string)
        XCTAssertEqual(bridge.history.manager.canUndo, native.history.canUndo)
    }

    func testReplacementRangeAndUnsupportedSyntax_T16_T18() {
        type("**a")
        bridge.select(NSRange(location: 2, length: 1))
        view.insertText("b**", replacementRange: NSRange(location: 2, length: 1))
        XCTAssertEqual(view.string, "b")
        XCTAssertTrue(bridge.document.paragraphs[0].runs[0].style.marks.contains(.bold))
        bridge.load(EditorDocument()); type("- [ ]")
        XCTAssertEqual(view.string, "[ ]")
        XCTAssertEqual(bridge.document.paragraphs[0].kind, .list(.unordered, 1))
        bridge.load(EditorDocument())
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.setString("- [ ]", forType: .string)
        bridge.paste(from: board)
        XCTAssertEqual(view.string, "- [ ]")
        XCTAssertEqual(bridge.document.paragraphs[0].kind, .body)
    }

    func testIMEGatesAndSaveCommit_I03_I05_I06() {
        bridge.execute(.list(.ordered))
        view.insertTab(nil)
        var saved = ""
        bridge.onSave = { saved = self.bridge.document.text }
        view.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(bridge.presentationDocument.paragraphs[0].kind, .list(.ordered, 2))
        XCTAssertEqual(bridge.presentationDocument.text, "中文")
        view.setMarkedText("中文候选", selectedRange: NSRange(location: 4, length: 0), replacementRange: view.markedRange())
        XCTAssertEqual(bridge.presentationDocument.text, "中文候选")
        XCTAssertEqual(bridge.presentation.positions.length, 4)
        for (chars, code) in [("\r", UInt16(36)), ("z", UInt16(6))] {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
                context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
            XCTAssertFalse(view.performKeyEquivalent(with: event))
        }
        XCTAssertEqual(saved, "")
        bridge.requestSave()
        XCTAssertEqual(saved, "中文候选")
        XCTAssertFalse(bridge.isComposing)
        XCTAssertEqual(bridge.document.paragraphs[0].kind, .list(.ordered, 2))
    }

    func testListGutterAndLongNumberGeometry_L05_L08_L12() {
        bridge.execute(.list(.ordered)); view.insertTab(nil)
        view.layoutManager!.ensureLayout(for: view.textContainer!)
        let origin = view.textContainerOrigin
        let target = ListMarkerRenderer.gutterTarget(NSPoint(x: origin.x + 1, y: origin.y + 5), bridge: bridge, view: view)
        XCTAssertNotNil(target)
        XCTAssertGreaterThanOrEqual(target!.x, origin.x + 44)
        type(String(repeating: "word ", count: 40))
        let kind = bridge.document.paragraphs[0].kind
        bridge.select(NSRange(location: 80, length: 0)); view.deleteBackward(nil)
        XCTAssertEqual(bridge.document.paragraphs[0].kind, kind)
        let long = EditorDocument(paragraphs: (0..<110).map { _ in Paragraph(kind: .list(.ordered, 1), runs: [InlineRun(text: "item")]) })
        bridge.load(long)
        XCTAssertEqual(bridge.listItems[99]?.marker, "100.")
        let width = ("100." as NSString).size(withAttributes: [.font: TextKitRenderer.font(for: .plain, block: .body)]).width
        XCTAssertGreaterThanOrEqual(view.textContainerOrigin.x + view.textContainer!.lineFragmentPadding + 22 - 4 - width, 0)
    }

    func testHistoryBranchAndEmptyInputAttributes_U04_U07() {
        bridge.execute(.toggle(.bold))
        view.undo(nil)
        XCTAssertTrue(bridge.state.session.insertionStyle.marks.isEmpty)
        view.redo(nil)
        XCTAssertTrue(bridge.state.session.insertionStyle.marks.contains(.bold))
        type("x")
        view.undo(nil)
        XCTAssertTrue(bridge.history.manager.canRedo)
        type("y")
        XCTAssertFalse(bridge.history.manager.canRedo)
        XCTAssertEqual(view.string, "y")
    }

    func testFinderFilesAndRTFDAttachments_P06_P07() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = NSImage(size: NSSize(width: 20, height: 20))
        image.lockFocus(); NSColor.blue.setFill(); NSRect(x: 0, y: 0, width: 20, height: 20).fill(); image.unlockFocus()
        let data = try XCTUnwrap(NotesSaver.pngData(for: image))
        let urls = [directory.appendingPathComponent("a.png"), directory.appendingPathComponent("b.png")]
        for url in urls { try data.write(to: url) }
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        XCTAssertTrue(board.writeObjects(urls.map { $0 as NSURL }))
        bridge.paste(from: board)
        XCTAssertEqual(bridge.document.assetOrder.count, 2)
        view.undo(nil); XCTAssertEqual(bridge.document.assetOrder.count, 0)
        let fragment = ClipboardCodec.imageFragment([image, image])
        let rich = NSMutableAttributedString(string: "before")
        rich.append(TextKitRenderer.render(fragment, exchange: true)); rich.append(NSAttributedString(string: "after"))
        let imported = ClipboardCodec.importRich(rich)
        XCTAssertEqual(imported.assetOrder.count, 2)
        XCTAssertEqual(imported.text, "before\u{FFFC}\u{FFFC}after")
        bridge.load(imported)
        bridge.select(NSRange(location: 6, length: 0)); view.insertNewline(nil)
        XCTAssertEqual(bridge.document.assetOrder.count, 2)
    }

    func testLongDocumentLocalInput_L09() {
        let document = EditorDocument(paragraphs: (0..<1500).map { i in
            Paragraph(kind: i % 3 == 0 ? .list(.ordered, 1) : .body, runs: [InlineRun(text: "paragraph \(i) 中文")])
        })
        bridge.load(document)
        bridge.select(NSRange(location: document.length, length: 0))
        let start = Date()
        type("new text")
        let elapsed = Date().timeIntervalSince(start)
        print("PERF 1500 paragraphs / 8 native characters: \(elapsed)s")
        XCTAssertTrue(bridge.document.text.hasSuffix("new text"))
        XCTAssertEqual(bridge.document.paragraphs.count, 1500)
        XCTAssertEqual(bridge.document.paragraphs[0], document.paragraphs[0])
        XCTAssertEqual(bridge.positionMap.starts, PositionMap(bridge.document).starts)
        XCTAssertEqual(bridge.presentation.positions.length, bridge.document.length)
    }

    func testBodyEOFListAndSelectionAffinity_M03_M09() {
        type("a"); view.insertNewline(nil); bridge.execute(.list(.ordered))
        XCTAssertEqual(bridge.document.paragraphs.map(\.kind), [.body, .list(.ordered, 1)])
        type("b")
        bridge.select(NSRange(location: 0, length: 3), affinity: .upstream)
        let before = bridge.state.session
        bridge.execute(.block(.heading(2)))
        view.undo(nil)
        XCTAssertEqual(bridge.state.session, before)
        XCTAssertEqual(view.selectedRange(), before.selection)
        XCTAssertEqual(view.selectionAffinity.rawValue, before.affinity)
    }

    func testResetSurvivesRelayoutAndInlineCodeIsOpaque_T13_T17() {
        type("**bold**")
        view.setFrameSize(NSSize(width: 280, height: 400))
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        view.setSelectedRange(view.selectedRange())
        type(" plain")
        XCTAssertTrue(bridge.document.paragraphs[0].runs.last!.style.marks.isEmpty)
        bridge.load(EditorDocument()); type("`abc`")
        bridge.select(NSRange(location: 1, length: 0)); type("**literal**")
        XCTAssertEqual(view.string, "a**literal**bc")
        XCTAssertTrue(bridge.document.paragraphs[0].runs.allSatisfy { !$0.style.marks.contains(.bold) })
    }

    func testTextTabDefaultForwardDeleteAndHeadingBackspace_K05_K08_K09() {
        type("abc")
        view.insertTab(nil)
        XCTAssertEqual(view.string, "abc\t")
        let before = bridge.state
        view.insertBacktab(nil)
        XCTAssertEqual(bridge.state, before)
        view.deleteBackward(nil)
        bridge.execute(.block(.heading(2))); bridge.select(NSRange(location: 0, length: 0))
        view.deleteForward(nil)
        XCTAssertEqual(view.string, "bc")
        XCTAssertEqual(bridge.document.paragraphs[0].kind, .heading(2))
        view.deleteBackward(nil)
        XCTAssertEqual(view.string, "bc"); XCTAssertEqual(bridge.document.paragraphs[0].kind, .body)
        bridge.load(EditorDocument()); bridge.execute(.list(.ordered)); for _ in 0..<8 { view.insertTab(nil) }
        view.undo(nil)
        XCTAssertEqual(bridge.document.paragraphs[0].kind, .list(.ordered, 7))
    }

    func testPasteOnlyTriggersOnFollowingTypedEvent_P10() {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.setString("-", forType: .string)
        bridge.paste(from: board)
        XCTAssertEqual(bridge.document.paragraphs[0].kind, .body)
        type(" ")
        XCTAssertEqual(bridge.document.paragraphs[0].kind, .list(.unordered, 1))
        view.undo(nil)
        XCTAssertEqual(view.string, "- ")
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        XCTAssertEqual(view.string, "- ")
    }

    func testStandardRTFDExchange_P03_P11() throws {
        let source = EditorDocument(paragraphs: [
            Paragraph(kind: .list(.ordered, 1), runs: [InlineRun(text: "first")]),
            Paragraph(kind: .list(.unordered, 3), runs: [InlineRun(text: "second", style: InlineStyle(marks: [.bold, .italic, .strike]))]),
        ])
        let rich = TextKitRenderer.render(source, exchange: true)
        let data = try XCTUnwrap(rich.rtfd(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]))
        let decoded = try XCTUnwrap(NSAttributedString(rtfd: data, documentAttributes: nil))
        let imported = ClipboardCodec.importRich(decoded)
        XCTAssertEqual(imported.text, source.text)
        XCTAssertEqual(imported.paragraphs.map(\.kind), source.paragraphs.map(\.kind))
        XCTAssertTrue(imported.paragraphs[1].runs[0].style.marks.contains([.bold, .italic, .strike]))
    }

    func testIMEReplacesParagraphsAsOneTransaction_U06() {
        let source = EditorDocument(paragraphs: [Paragraph(kind: .heading(1), runs: [InlineRun(text: "ab")]),
            Paragraph(kind: .list(.ordered, 2), runs: [InlineRun(text: "cd")])])
        bridge.load(source)
        bridge.select(NSRange(location: 1, length: 3))
        view.setMarkedText("候选", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 1, length: 3))
        view.insertText("提交", replacementRange: view.markedRange())
        XCTAssertEqual(view.string, "a提交d")
        view.undo(nil)
        XCTAssertEqual(bridge.document.paragraphs, source.paragraphs)
        assertProjection()
    }

    func testImageOnlyListAndMixedCutRoundTrip_M06_M10_P11_D07() throws {
        let image = NSImage(size: NSSize(width: 30, height: 80))
        image.lockFocus(); NSColor.orange.setFill(); NSRect(x: 0, y: 0, width: 30, height: 80).fill(); image.unlockFocus()
        bridge.execute(.list(.ordered)); view.insertTab(nil)
        bridge.insertImages([image]); view.insertNewline(nil)
        // 图片段恒为正文（EditorSpec §8.2）：空列表项插图后成为正文行，Enter 续正文。
        XCTAssertEqual(bridge.document.paragraphs.map(\.kind), [.body, .body])
        XCTAssertFalse(bridge.document.paragraphs[0].isEmpty)
        XCTAssertTrue(bridge.document.paragraphs[1].isEmpty)
        view.insertNewline(nil) // Keep a lower-depth empty item in the copied fragment.
        let source = bridge.document
        bridge.select(NSRange(location: 0, length: source.length))
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        bridge.copy(to: board, cut: true)
        XCTAssertTrue(bridge.document.assetOrder.isEmpty)
        view.undo(nil)
        XCTAssertEqual(bridge.document.paragraphs, source.paragraphs)
        XCTAssertEqual(bridge.document.assets, source.assets)
        view.redo(nil)
        bridge.paste(from: board)
        XCTAssertEqual(bridge.document.text, source.text)
        XCTAssertEqual(bridge.document.paragraphs.map(\.kind), source.paragraphs.map(\.kind))
        XCTAssertEqual(bridge.document.assetOrder.count, 1)
        XCTAssertEqual(try XCTUnwrap(bridge.document.assets[bridge.document.assetOrder[0]]).data,
                       try XCTUnwrap(source.assets[source.assetOrder[0]]).data)
        let export = HTMLExporter.export(bridge.document)
        XCTAssertEqual(export.assetIDs, bridge.document.assetOrder)
        XCTAssertFalse(export.bodyHTML.contains("\u{FFFC}"))
        var repeated = bridge.document
        let id = repeated.assetOrder[0]
        repeated.paragraphs[1].runs = [.image(id)]
        XCTAssertEqual(HTMLExporter.export(repeated).assetIDs, [id, id])
        XCTAssertFalse(HTMLExporter.export(repeated).bodyHTML.contains("\u{FFFC}"))
        assertProjection()
        bridge.load(EditorDocument())
        XCTAssertTrue(bridge.document.assets.isEmpty)
        XCTAssertFalse(bridge.history.manager.canUndo)
    }

    /// 纯输入回归测试：整段输入走原生路径（无回车、无显式 layout pass），
    /// 换行折行使内容超出视口时，文档必须随之增长并滚动到光标可见，
    /// 否则用户既看不到也滚不到视口之外的内容。
    func testTypingWrappedTextGrowsDocumentAndKeepsCaretVisible() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 120), styleMask: [], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        scroll.hasVerticalScroller = true
        window.contentView = scroll; scroll.documentView = view
        defer { scroll.documentView = nil; window.contentView = nil }
        type(String(repeating: "wrapping paragraph keeps growing ", count: 40))
        // Capture geometry before any explicit layout query can run a deferred pass.
        let height = view.frame.height
        let visibleMaxY = scroll.contentView.bounds.maxY
        view.layoutManager!.ensureLayout(for: view.textContainer!)
        let bottom = view.textContainerOrigin.y + view.layoutManager!.usedRect(for: view.textContainer!).maxY
        let lastGlyph = view.layoutManager!.lineFragmentRect(forGlyphAt: view.layoutManager!.numberOfGlyphs - 1, effectiveRange: nil)
        let caretBottom = view.textContainerOrigin.y + lastGlyph.maxY
        XCTAssertGreaterThan(bottom, scroll.contentSize.height, "precondition: content must overflow the viewport")
        XCTAssertGreaterThan(height, scroll.contentSize.height, "document frame must grow with typed content")
        XCTAssertGreaterThanOrEqual(height, bottom, "frame must cover the full content so manual scrolling can reach the bottom")
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0, "viewport must auto-scroll while typing")
        XCTAssertGreaterThanOrEqual(visibleMaxY + 1, caretBottom, "caret line must be visible")
    }

    func testReturnScrollsToTrailingEmptyLineWithoutFurtherTyping() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 120), styleMask: [], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        scroll.hasVerticalScroller = true
        window.contentView = scroll; scroll.documentView = view
        defer { scroll.documentView = nil; window.contentView = nil }
        for prefix in ["", "- ", "1. "] {
            bridge.load(EditorDocument()); type(prefix)
            for _ in 0..<25 { type("line"); view.insertNewline(nil) }
            // Capture the viewport before a geometry query can finish deferred layout.
            let visible = view.visibleRect
            let height = view.frame.height
            let offset = scroll.contentView.bounds.minY
            view.layoutManager!.ensureLayout(for: view.textContainer!)
            let lastLine = view.layoutManager!.extraLineFragmentRect.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
            XCTAssertFalse(lastLine.isEmpty)
            XCTAssertGreaterThan(offset, 0)
            XCTAssertGreaterThanOrEqual(height, lastLine.maxY)
            XCTAssertLessThanOrEqual(lastLine.maxY, visible.maxY + 1)
            XCTAssertGreaterThanOrEqual(lastLine.minY, visible.minY - 1)
        }
    }

    func testRestoredLongDraftScrollsImmediatelyAfterAttachment() {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NotesMateScrollTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let drafts = DraftStore(directory: directory)
        let draft = EditorDocument.plain((0..<70).map {
            "Restored line \($0) with a longer sentence to wrap in the editor"
        }.joined(separator: "\n"))
        drafts.persist(draft, session: EditorSession(selection: NSRange(location: draft.length, length: 0)))
        drafts.flush()
        let model = NoteEditorModel(drafts: drafts)
        XCTAssertEqual(model.bridge.document.text, draft.text)
        let hosting = NSHostingView(rootView: RestoredEditorHost(bridge: model.bridge))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 260),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        hosting.layoutSubtreeIfNeeded()
        guard let editor = model.bridge.textView, let scroll = editor.enclosingScrollView else {
            XCTFail("Restored editor did not attach to the scroll view")
            return
        }
        XCTAssertGreaterThan(editor.frame.height, scroll.contentView.bounds.height)
        let bottom = max(editor.layoutManager!.usedRect(for: editor.textContainer!).maxY,
                         editor.layoutManager!.extraLineFragmentRect.maxY) + 2 * editor.textContainerInset.height
        XCTAssertGreaterThanOrEqual(editor.frame.height, ceil(bottom))
        let clip = scroll.contentView.bounds
        let end = scroll.contentView.constrainBoundsRect(NSRect(x: 0, y: 10_000, width: clip.width, height: clip.height))
        XCTAssertGreaterThan(end.minY, 0)
        XCTAssertGreaterThanOrEqual(end.maxY, editor.frame.height - 1)
    }

    func testEightLevelListsAndClipboardRoundTrip() throws {
        let expected = ["●", "○", "◆", "◇", "■", "□", "▲", "△"]
        for kind in [ListKind.unordered, .ordered] {
            let source = EditorDocument(paragraphs: (1...8).map {
                Paragraph(kind: .list(kind, $0), runs: [InlineRun(text: "level \($0)")])
            })
            XCTAssertNoThrow(try source.validated())
            bridge.load(source)
            for i in 0..<8 {
                XCTAssertEqual(bridge.listItems[i]?.marker, kind == .unordered ? expected[i] : "1.")
                XCTAssertEqual(TextKitRenderer.paragraphStyle(source.paragraphs[i].kind).headIndent, CGFloat((i + 1) * 22))
            }
            let rich = TextKitRenderer.render(source, exchange: true)
            let data = try XCTUnwrap(rich.rtfd(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]))
            let decoded = try XCTUnwrap(NSAttributedString(rtfd: data, documentAttributes: nil))
            XCTAssertEqual(ClipboardCodec.importRich(decoded).paragraphs.map(\.kind), source.paragraphs.map(\.kind))
            let tag = kind == .ordered ? "ol" : "ul"
            XCTAssertEqual(HTMLExporter.export(source).bodyHTML.components(separatedBy: "<\(tag)>").count - 1, 8)
        }
        let style = NSMutableParagraphStyle()
        style.textLists = (0..<10).map { _ in NSTextList(markerFormat: .disc, options: 0) }
        let imported = ClipboardCodec.importRich(NSAttributedString(string: "deep", attributes: [.paragraphStyle: style]))
        XCTAssertEqual(imported.paragraphs[0].kind, .list(.unordered, 8))
        XCTAssertThrowsError(try EditorDocument(paragraphs: [Paragraph(kind: .list(.ordered, 9))]).validated())
    }

    func testHeadingPrefixIsConsumedBeforeTextAndComposition() {
        for prefix in ["# ", "## ", "### "] {
            bridge.load(EditorDocument()); type(prefix)
            XCTAssertEqual(view.string, "")
            XCTAssertEqual(bridge.document.text, "")
            view.setMarkedText("biaoti", selectedRange: NSRange(location: 6, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            view.insertText("标题", replacementRange: view.markedRange())
            XCTAssertEqual(view.string, "标题")
            XCTAssertEqual(bridge.document.paragraphs[0].kind, .heading(prefix.count - 1))
            assertProjection()
        }
    }

    func testEmptyMarkedTextDoesNotLeaveFormattingDisabled() {
        view.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertFalse(bridge.isComposing)
        XCTAssertTrue(bridge.history.manager.isUndoRegistrationEnabled)
        bridge.execute(.toggle(.bold))
        XCTAssertTrue(bridge.state.session.insertionStyle.marks.contains(.bold))
    }

    func testCancellingMarkedTextRestoresFormattingAndUndo() {
        type("before")
        let before = bridge.document
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(bridge.isComposing)
        view.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: view.markedRange())
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertFalse(bridge.isComposing)
        XCTAssertEqual(bridge.document.paragraphs, before.paragraphs)
        XCTAssertTrue(bridge.history.manager.isUndoRegistrationEnabled)
        bridge.execute(.list(.ordered))
        XCTAssertEqual(bridge.document.paragraphs[0].kind, .list(.ordered, 1))
        view.undo(nil)
        XCTAssertEqual(bridge.document.paragraphs, before.paragraphs)
    }

    func testFirstMarkedCharacterNeverUsesStaleEmptyListPreview() {
        for prefix in ["- ", "1. "] {
            bridge.load(EditorDocument()); type(prefix + "first"); view.insertNewline(nil)
            bridge.beginComposition()
            XCTAssertTrue(bridge.presentationDocument.paragraphs[1].isEmpty) // Prime the empty-line preview.
            var observedDuringNativeEdit = false
            let token = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification,
                object: view.textStorage, queue: nil) { [self] _ in
                guard view.string.hasSuffix("zhong") else { return }
                observedDuringNativeEdit = true
                let preview = bridge.presentation
                XCTAssertEqual(preview.document.text, view.string)
                XCTAssertEqual(preview.positions.length, (view.string as NSString).length)
                XCTAssertNotNil(preview.lists[1])
                XCTAssertFalse(preview.document.paragraphs[1].isEmpty)
            }
            view.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            NotificationCenter.default.removeObserver(token)
            XCTAssertTrue(observedDuringNativeEdit)
            let preview = bridge.presentation
            let geometry = ListMarkerRenderer.firstLine(1, document: preview.document, map: preview.positions, view: view)
            XCTAssertNotNil(geometry)
            XCTAssertFalse(geometry!.0.isEmpty)
            view.insertText("中", replacementRange: view.markedRange())
            XCTAssertNotNil(bridge.listItems[1])
            XCTAssertEqual(bridge.document.paragraphs[1].text, "中")
        }
    }
    func testListGroupSpacingUpdatesWhenNeighborChangesAndUndoRestoresIt() throws {
        bridge.load(EditorDocument(paragraphs: [
            Paragraph(kind: .list(.unordered, 1), runs: [InlineRun(text: "第一项")]),
            Paragraph(runs: [InlineRun(text: "第二项")])
        ]))
        func firstSpacing() throws -> CGFloat {
            try XCTUnwrap(view.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle).paragraphSpacing
        }
        XCTAssertEqual(try firstSpacing(), 6)
        bridge.select(NSRange(location: bridge.positionMap.starts[1], length: 0))
        bridge.execute(.list(.unordered))
        XCTAssertEqual(try firstSpacing(), 0)
        assertProjection()
        view.undo(nil)
        XCTAssertEqual(try firstSpacing(), 6)
        assertProjection()
        view.redo(nil)
        XCTAssertEqual(try firstSpacing(), 0)
        assertProjection()
    }

    func testParagraphRhythmSeparatesBlocksWithoutExpandingWrappedLinesOrExport() throws {
        let wrapped = String(repeating: "中文 text ", count: 12)
        let document = EditorDocument(paragraphs: [
            Paragraph(kind: .heading(1), runs: [InlineRun(text: "标题")]),
            Paragraph(runs: [InlineRun(text: wrapped)]),
            Paragraph(kind: .list(.unordered, 1), runs: [InlineRun(text: "项目一")]),
            Paragraph(kind: .list(.unordered, 1), runs: [InlineRun(text: "项目二")]),
            Paragraph(runs: [InlineRun(text: "正文")])
        ])
        let exported = HTMLExporter.export(document).bodyHTML
        bridge.load(document)
        let layout = try XCTUnwrap(view.layoutManager)
        layout.ensureLayout(for: view.textContainer!)
        let map = bridge.positionMap
        let bodyGlyphs = layout.glyphRange(forCharacterRange: map.range(of: 1), actualCharacterRange: nil)
        var bodyLines: [NSRect] = []
        layout.enumerateLineFragments(forGlyphRange: bodyGlyphs) { rect, _, _, _, _ in bodyLines.append(rect) }
        XCTAssertGreaterThan(bodyLines.count, 2)
        let innerStep = bodyLines[1].minY - bodyLines[0].minY
        func firstLine(_ index: Int) -> NSRect {
            layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: map.starts[index]), effectiveRange: nil)
        }
        XCTAssertEqual(firstLine(3).minY - firstLine(2).minY, innerStep, accuracy: 0.01)
        XCTAssertEqual(firstLine(2).minY - bodyLines.last!.minY, innerStep + 6, accuracy: 0.01)
        XCTAssertEqual(firstLine(4).minY - firstLine(3).minY, innerStep + 6, accuracy: 0.01)
        XCTAssertEqual(bridge.document.paragraphs, document.paragraphs)
        XCTAssertEqual(bridge.document.assets, document.assets)
        XCTAssertEqual(HTMLExporter.export(bridge.document).bodyHTML, exported)
        let exchange = TextKitRenderer.render(document, exchange: true)
        XCTAssertEqual((exchange.attribute(.paragraphStyle, at: map.starts[1], effectiveRange: nil) as? NSParagraphStyle)?.paragraphSpacing, 0)
        assertProjection()
    }

    func testCodeBackgroundDoesNotResizeWhenExitingOrUndoingExit() throws {
        for blankLines in [0, 1, 3] {
            bridge.load(EditorDocument(paragraphs: [
                Paragraph(runs: [InlineRun(text: "上文")]),
                Paragraph(kind: .codeLine, runs: [InlineRun(text: "let x = 1")])
            ] + (0..<blankLines).map { _ in Paragraph(kind: .codeLine) }))
            bridge.select(NSRange(location: bridge.document.length, length: 0))
            let before = try XCTUnwrap(view.codeBackgroundRects().first)
            view.moveDown(nil)
            let after = try XCTUnwrap(view.codeBackgroundRects().first)
            XCTAssertEqual(after.minY, before.minY, accuracy: 0.01)
            XCTAssertEqual(after.height, before.height, accuracy: 0.01)
            view.undo(nil)
            XCTAssertEqual(try XCTUnwrap(view.codeBackgroundRects().first).height, before.height, accuracy: 0.01)
            view.redo(nil)
            XCTAssertEqual(try XCTUnwrap(view.codeBackgroundRects().first).height, before.height, accuracy: 0.01)
        }
    }

    func testCodeBackgroundLeavesSpaceAroundNeighboringBody() throws {
        for tail in ["正文", ""] {
            bridge.load(EditorDocument(paragraphs: [
                Paragraph(runs: [InlineRun(text: "上文")]),
                Paragraph(kind: .codeLine, runs: [InlineRun(text: "let x = 1")]),
                Paragraph(kind: .codeLine), Paragraph(kind: .codeLine),
                Paragraph(runs: tail.isEmpty ? [] : [InlineRun(text: tail)])
            ]))
            let rect = try XCTUnwrap(view.codeBackgroundRects().first)
            let layout = try XCTUnwrap(view.layoutManager)
            let map = bridge.positionMap
            let top = layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
            let bottom = tail.isEmpty ? layout.extraLineFragmentRect
                : layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: map.starts[4]), effectiveRange: nil)
            XCTAssertGreaterThanOrEqual(rect.minY - view.textContainerOrigin.y - top.maxY, 2)
            XCTAssertGreaterThanOrEqual(view.textContainerOrigin.y + bottom.minY - rect.maxY, 2)
            let glyph = layout.glyphIndexForCharacter(at: map.starts[1])
            let last = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let font = TextKitRenderer.font(for: .plain, block: .codeLine)
            let textBottom = view.textContainerOrigin.y + last.minY + layout.location(forGlyphAt: glyph).y - font.descender
            XCTAssertGreaterThanOrEqual(rect.maxY + 0.01, textBottom + TextKitRenderer.codeVerticalPadding)
            assertProjection()
        }
    }

    func testBackspaceInTrailingAndMiddleCodeBlankLines() {
        for line in [1, 2, 3] {
            let original = EditorDocument(paragraphs: [
                Paragraph(kind: .codeLine, runs: [InlineRun(text: "code")]),
                Paragraph(kind: .codeLine), Paragraph(kind: .codeLine), Paragraph(kind: .codeLine)
            ])
            bridge.load(original)
            let oldLocation = bridge.positionMap.starts[line]
            bridge.select(NSRange(location: oldLocation, length: 0))
            view.deleteBackward(nil)
            XCTAssertEqual(bridge.document.text, "code\n\n")
            XCTAssertEqual(bridge.document.paragraphs.map(\.kind), [.codeLine, .codeLine, .codeLine])
            XCTAssertEqual(view.selectedRange(), NSRange(location: oldLocation - 1, length: 0))
            assertProjection()
            view.undo(nil)
            XCTAssertEqual(bridge.document.paragraphs, original.paragraphs)
            XCTAssertEqual(view.selectedRange().location, oldLocation)
            view.redo(nil)
            XCTAssertEqual(view.selectedRange().location, oldLocation - 1)
            view.insertText("x", replacementRange: view.selectedRange())
            XCTAssertTrue(bridge.document.paragraphs.allSatisfy { $0.kind.isCode })
            XCTAssertEqual(bridge.document.paragraphs[line - 1].text, line == 1 ? "codex" : "x")
            assertProjection()
        }
    }

    func testBackspaceMergesNonemptyCodeLinesWithoutLosingText() {
        bridge.load(EditorDocument(paragraphs: [
            Paragraph(kind: .codeLine, runs: [InlineRun(text: "a")]),
            Paragraph(kind: .codeLine, runs: [InlineRun(text: "b")]), Paragraph()
        ]))
        bridge.select(NSRange(location: 2, length: 0))
        view.deleteBackward(nil)
        XCTAssertEqual(bridge.document.text, "ab\n")
        XCTAssertEqual(bridge.document.paragraphs.map(\.kind), [.codeLine, .body])
        XCTAssertEqual(view.selectedRange().location, 1)
        assertProjection()
    }

    func testCodeBlankLinesAndDownArrowExitUndo() {
        bridge.load(EditorDocument(paragraphs: [Paragraph(kind: .codeLine)]))
        view.insertNewline(nil)
        view.insertNewline(nil)
        XCTAssertEqual(bridge.document.paragraphs.map(\.kind), [.codeLine, .codeLine, .codeLine])
        let code = bridge.document
        view.moveDown(nil)
        XCTAssertEqual(bridge.document.paragraphs.map(\.kind), [.codeLine, .codeLine, .codeLine, .body])
        XCTAssertEqual(view.selectedRange().location, bridge.document.length)
        view.undo(nil)
        XCTAssertEqual(bridge.document.paragraphs, code.paragraphs)
        view.redo(nil)
        view.insertText("正文", replacementRange: view.selectedRange())
        XCTAssertEqual(bridge.document.paragraphs.last?.kind, .body)
        XCTAssertEqual(bridge.document.paragraphs.last?.text, "正文")
        assertProjection()
    }

    func testCodeDownArrowRespectsWrappedLinesAndExistingBody() {
        let text = String(repeating: "abcdefghij ", count: 30)
        bridge.load(EditorDocument(paragraphs: [Paragraph(kind: .codeLine, runs: [InlineRun(text: text)])]))
        bridge.select(NSRange(location: 0, length: 0))
        view.moveDown(nil)
        XCTAssertEqual(bridge.document.paragraphs.count, 1)
        XCTAssertGreaterThan(view.selectedRange().location, 0)
        bridge.select(NSRange(location: bridge.document.length, length: 0))
        view.moveDown(nil)
        XCTAssertEqual(bridge.document.paragraphs.map(\.kind), [.codeLine, .body])
        let before = bridge.document
        bridge.select(NSRange(location: text.utf16.count, length: 0))
        view.moveDown(nil)
        XCTAssertEqual(bridge.document.paragraphs, before.paragraphs)
        XCTAssertEqual(view.selectedRange().location, bridge.document.length)
    }

    func testCodeTabIndentsWholeLineAndKeepsCaretWithText() {
        type("abc")
        bridge.execute(.block(.codeLine))
        bridge.select(NSRange(location: 2, length: 0))
        view.insertTab(nil)
        XCTAssertEqual(view.string, "\tabc")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 3, length: 0))
        XCTAssertEqual(bridge.document.paragraphs[0].kind, .codeLine)
        view.insertBacktab(nil)
        XCTAssertEqual(view.string, "abc")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 2, length: 0))
        view.undo(nil)
        XCTAssertEqual(view.string, "\tabc")
        view.redo(nil)
        XCTAssertEqual(view.string, "abc")
        assertProjection()
    }

    func testCodeMultilineTabSelectionAndSpaceOutdent() {
        bridge.load(EditorDocument(paragraphs: [
            Paragraph(kind: .codeLine, runs: [InlineRun(text: "one")]),
            Paragraph(kind: .codeLine, runs: [InlineRun(text: "    two")]),
            Paragraph(kind: .codeLine, runs: [InlineRun(text: "three")])]))
        bridge.select(NSRange(location: 0, length: 12)) // End at the third line's start.
        view.insertTab(nil)
        XCTAssertEqual(view.string, "\tone\n\t    two\nthree")
        view.insertBacktab(nil)
        XCTAssertEqual(view.string, "one\n    two\nthree")
        bridge.select(NSRange(location: 10, length: 0))
        view.insertBacktab(nil)
        XCTAssertEqual(view.string, "one\ntwo\nthree")
        XCTAssertEqual(view.selectedRange().location, 6)
        assertProjection()
    }

    func testEmptyCodeTabAndPlainTextSelectionReplacement() {
        bridge.execute(.block(.codeLine))
        view.insertTab(nil)
        XCTAssertEqual(view.string, "\t")
        view.insertBacktab(nil)
        XCTAssertEqual(view.string, "")
        let before = bridge.state
        view.insertBacktab(nil)
        XCTAssertEqual(bridge.state, before)
        bridge.load(.plain("abcd"))
        bridge.select(NSRange(location: 1, length: 2))
        view.insertTab(nil)
        XCTAssertEqual(view.string, "a\td")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 2, length: 0))
        assertProjection()
    }

}
