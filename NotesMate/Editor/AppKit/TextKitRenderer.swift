import AppKit

extension NSAttributedString.Key {
    static let editorStyle = Self("NotesMate.InlineStyle.v1")
    static let editorAsset = Self("NotesMate.Asset.v1")
}

/// Supplies real layout geometry for the zero-length last paragraph, including when the caret is elsewhere.
final class EditorLayoutManager: NSLayoutManager {
    var trailingKind: BlockKind = .body
    private var backgroundDrawingOrigin: NSPoint?

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        let previous = backgroundDrawingOrigin
        backgroundDrawingOrigin = origin
        defer { backgroundDrawingOrigin = previous }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int,
                                          forCharacterRange charRange: NSRange, color: NSColor) {
        guard let drawingOrigin = backgroundDrawingOrigin,
              let view = textContainers.first?.textView as? EditorTextView,
              NSIntersectionRange(view.selectedRange(), charRange).length > 0,
              color == view.selectedTextAttributes[.backgroundColor] as? NSColor
                || color == NSColor.selectedTextBackgroundColor
                || color == NSColor.unemphasizedSelectedTextBackgroundColor else {
            super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
            return
        }
        // Native background painting can bypass enumerateEnclosingRects. Apply the same
        // geometry here as during tracking, including when drawing at a different origin.
        let origin = view.textContainerOrigin
        let rects = UnsafeBufferPointer(start: rectArray, count: rectCount).map {
            $0.offsetBy(dx: origin.x - drawingOrigin.x, dy: origin.y - drawingOrigin.y)
        }
        let adjusted = selectionBackgroundRects(rects, selectedGlyphs: glyphRange(forCharacterRange: charRange, actualCharacterRange: nil), origin: origin).map {
            $0.offsetBy(dx: drawingOrigin.x - origin.x, dy: drawingOrigin.y - origin.y)
        }
        adjusted.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            super.fillBackgroundRectArray(base, count: buffer.count, forCharacterRange: charRange, color: color)
        }
    }

    override func enumerateEnclosingRects(forGlyphRange glyphRange: NSRange,
                                           withinSelectedGlyphRange selectedRange: NSRange,
                                           in container: NSTextContainer,
                                           using block: @escaping (NSRect, UnsafeMutablePointer<ObjCBool>) -> Void) {
        guard selectedRange.location != NSNotFound, selectedRange.length > 0,
              let view = container.textView as? EditorTextView else {
            super.enumerateEnclosingRects(forGlyphRange: glyphRange, withinSelectedGlyphRange: selectedRange,
                                           in: container, using: block)
            return
        }
        // Supply the same geometry to selection tracking, invalidation and painting. Changing
        // rectangles only at fill time leaves the upward extension clipped during mouse tracking.
        let origin = view.textContainerOrigin
        super.enumerateEnclosingRects(forGlyphRange: glyphRange, withinSelectedGlyphRange: selectedRange,
                                       in: container) { rect, stop in
            let adjusted = self.selectionBackgroundRects([rect.offsetBy(dx: origin.x, dy: origin.y)],
                                                         selectedGlyphs: selectedRange, origin: origin)
            for rect in adjusted {
                block(rect.offsetBy(dx: -origin.x, dy: -origin.y), stop)
                if stop.pointee.boolValue { break }
            }
        }
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let view = textContainers.first?.textView as? EditorTextView,
              view.selectedRange().length > 0 else { return }
        let selectedGlyphs = glyphRange(forCharacterRange: view.selectedRange(), actualCharacterRange: nil)
        let rects = selectionBorderRects(selectedGlyphs: selectedGlyphs, origin: origin)
        guard !rects.isEmpty else { return }
        // 选中附件画一圈选中色描边（EditorSpec §6 选区规则），取代图片底部/右侧的不对称背景。
        let color = view.selectedTextAttributes[.backgroundColor] as? NSColor ?? .selectedTextBackgroundColor
        color.setStroke()
        for rect in rects {
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1.5, dy: 1.5), xRadius: 4, yRadius: 4)
            path.lineWidth = 3
            path.stroke()
        }
    }

    /// 选区覆盖的附件字形的描边框几何（view 坐标）。图片段恒独占行，边框即附件包围矩形。
    func selectionBorderRects(selectedGlyphs: NSRange, origin: NSPoint) -> [NSRect] {
        guard let view = textContainers.first?.textView as? EditorTextView,
              let container = view.textContainer, let storage = view.textStorage,
              selectedGlyphs.length > 0 else { return [] }
        let characters = NSIntersectionRange(characterRange(forGlyphRange: selectedGlyphs, actualGlyphRange: nil),
                                             NSRange(location: 0, length: storage.length))
        guard characters.length > 0 else { return [] }
        var rects: [NSRect] = []
        storage.enumerateAttribute(.attachment, in: characters) { value, range, _ in
            guard value != nil else { return }
            let glyphs = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            rects.append(self.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: origin.x, dy: origin.y))
        }
        return rects
    }

    /// 附件字符区间的横向缝隙（view 坐标 x 区间 + 字符范围），供选区背景避开图片——图片选中态只显示描边。
    private func attachmentGaps(in glyphs: NSRange, container: NSTextContainer,
                                origin: NSPoint) -> [(minX: CGFloat, maxX: CGFloat, chars: NSRange)] {
        guard let storage = textContainers.first?.textView?.textStorage else { return [] }
        let characters = NSIntersectionRange(characterRange(forGlyphRange: glyphs, actualGlyphRange: nil),
                                             NSRange(location: 0, length: storage.length))
        guard characters.length > 0 else { return [] }
        var gaps: [(CGFloat, CGFloat, NSRange)] = []
        storage.enumerateAttribute(.attachment, in: characters) { value, range, _ in
            guard value != nil else { return }
            let bounds = self.boundingRect(forGlyphRange: self.glyphRange(forCharacterRange: range, actualCharacterRange: nil),
                                           in: container).offsetBy(dx: origin.x, dy: origin.y)
            gaps.append((bounds.minX, bounds.maxX, range))
        }
        return gaps
    }

    /// 逐行选区几何：水平范围取「该行字形 ∩ 选区」的字形包围矩形，而不是行片段左缘——
    /// AppKit 原生矩形在选区含行首/换行符时会延伸到片段左缘（缩进/排水区被涂色），
    /// 列表与代码块内容必须精确到文字起点。选中到行尾（含换行符）保留原生「延伸到行右缘」；
    /// 每行垂直居中逻辑（7e2562b）不变。
    func selectionBackgroundRects(_ rects: [NSRect], selectedGlyphs: NSRange, origin: NSPoint) -> [NSRect] {
        guard let view = textContainers.first?.textView as? EditorTextView,
              let container = view.textContainer else { return rects }
        var lines: [(rect: NSRect, glyphs: NSRange)] = []
        enumerateLineFragments(forGlyphRange: selectedGlyphs) { line, _, _, lineGlyphs, _ in
            lines.append((line.offsetBy(dx: origin.x, dy: origin.y), lineGlyphs))
        }
        let rightEdge = origin.x + container.containerSize.width - container.lineFragmentPadding
        return rects.flatMap { rect -> [NSRect] in
            // AppKit can combine adjacent full-width selections into one tall rectangle.
            let fragments = lines.filter { min($0.rect.maxY, rect.maxY) > max($0.rect.minY, rect.minY) }
            guard !fragments.isEmpty else { return [rect] }
            return fragments.flatMap { line -> [NSRect] in
                var minX = rect.minX
                var maxX = rect.maxX
                var gaps: [(minX: CGFloat, maxX: CGFloat, chars: NSRange)] = []
                let clipped = NSIntersectionRange(line.glyphs, selectedGlyphs)
                if clipped.length > 0 {
                    let bounds = boundingRect(forGlyphRange: clipped, in: container)
                        .offsetBy(dx: origin.x, dy: origin.y)
                    minX = bounds.minX
                    maxX = bounds.maxX
                    // 附件字符区间不留选区背景（选中图片以描边表示，见 drawGlyphs）。
                    gaps = attachmentGaps(in: clipped, container: container, origin: origin)
                    if let storage = view.textStorage,
                       NSMaxRange(clipped) == NSMaxRange(line.glyphs) {
                        // 选区覆盖到该行末尾时保留原生「延伸到行右缘」：行末是换行符，
                        // 或行因软折行而延续（行内不含换行符且下个字形仍在同一段落）。
                        // 删除/undo 瞬态下行片段字形范围可能超出文本长度，先夹取。
                        let lineCharacters = NSIntersectionRange(
                            characterRange(forGlyphRange: line.glyphs, actualGlyphRange: nil),
                            NSRange(location: 0, length: storage.length)
                        )
                        if lineCharacters.length > 0 {
                            let string = storage.string as NSString
                            let lineText = string.substring(with: lineCharacters)
                            let nextIndex = NSMaxRange(lineCharacters)
                            let softWrapped = !lineText.hasSuffix("\n") && nextIndex < storage.length
                                && !string.substring(with: NSRange(location: nextIndex, length: 1))
                                    .hasPrefix("\n")
                            if lineText.hasSuffix("\n") || softWrapped {
                                maxX = max(maxX, rightEdge)
                            }
                        }
                    }
                }
                let probe = NSRect(x: minX, y: line.rect.minY, width: maxX - minX, height: line.rect.height)
                let caret = view.insertionPointDrawingRect(probe)
                // 行尾（不含换行符）是附件时，把最右附件缝隙延伸到行右缘，吞掉换行区——
                // 否则选中图片时右侧仍会残留一条背景色带。
                if let storage = view.textStorage, !gaps.isEmpty {
                    let lineCharacters = NSIntersectionRange(
                        characterRange(forGlyphRange: line.glyphs, actualGlyphRange: nil),
                        NSRange(location: 0, length: storage.length))
                    if lineCharacters.length > 0 {
                        let lineText = (storage.string as NSString).substring(with: lineCharacters)
                        let contentEnd = NSMaxRange(lineCharacters) - (lineText.hasSuffix("\n") ? 1 : 0)
                        if NSMaxRange(gaps[gaps.count - 1].chars) == contentEnd {
                            gaps[gaps.count - 1].maxX = maxX
                        }
                    }
                }
                // 横向扣除附件区间：图文混排选中时文字部分保留背景，图片部分只留描边。
                var spans: [(CGFloat, CGFloat)] = [(minX, maxX)]
                for gap in gaps.sorted(by: { $0.0 < $1.0 }) {
                    spans = spans.flatMap { span -> [(CGFloat, CGFloat)] in
                        guard gap.1 > span.0, gap.0 < span.1 else { return [span] }
                        var out: [(CGFloat, CGFloat)] = []
                        if gap.0 > span.0 { out.append((span.0, min(gap.0, span.1))) }
                        if gap.1 < span.1 { out.append((max(gap.1, span.0), span.1)) }
                        return out
                    }
                }
                return spans.filter { $0.1 - $0.0 > 0.5 }.map {
                    NSRect(x: $0.0, y: caret.minY, width: $0.1 - $0.0, height: caret.height)
                }
            }
        }
    }
    override func ensureLayout(for container: NSTextContainer) {
        super.ensureLayout(for: container)
        // TextKit can leave an empty document's extra fragment invalid after a zero-length
        // style-only transaction. Supply it here, in the layout layer, not by moving the caret.
        if textStorage?.length == 0 && extraLineFragmentRect.isEmpty {
            let height = defaultLineHeight(for: TextKitRenderer.font(for: .plain, block: trailingKind))
            setExtraLineFragmentRect(NSRect(x: 0, y: 0, width: container.containerSize.width, height: height),
                                    usedRect: NSRect(x: 0, y: 0, width: 10, height: height), textContainer: container)
        }
    }
    override func setExtraLineFragmentRect(_ fragmentRect: NSRect, usedRect: NSRect, textContainer container: NSTextContainer) {
        var fragment = fragmentRect
        var used = usedRect
        let font = TextKitRenderer.font(for: .plain, block: trailingKind)
        fragment.size.height = defaultLineHeight(for: font)
        used.origin.x = trailingKind.isCode ? TextKitRenderer.codeHorizontalPadding : CGFloat(trailingKind.list?.depth ?? 0) * 22
        used.size.height = fragment.height
        super.setExtraLineFragmentRect(fragment, usedRect: used, textContainer: container)
    }
}

enum TextKitRenderer {
    static let textColor = EditorAppearance.text
    static let codeBackgroundColor = EditorAppearance.code
    static let codeHorizontalPadding: CGFloat = 4
    static let codeVerticalPadding: CGFloat = 4
    static let codeBlockSpacing: CGFloat = 2
    static let headingSpacing: CGFloat = 10
    static let bodySpacing: CGFloat = 6
    static func paragraphStyle(_ kind: BlockKind, includeNativeLists: Bool = false) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = kind == .body || kind.list != nil ? 5 : 4
        style.paragraphSpacing = 0
        style.paragraphSpacingBefore = 0
        if kind.isCode {
            style.headIndent = codeHorizontalPadding
            style.firstLineHeadIndent = codeHorizontalPadding
            style.tailIndent = -codeHorizontalPadding
        }
        if let list = kind.list {
            style.headIndent = CGFloat(list.depth) * 22
            style.firstLineHeadIndent = style.headIndent
            if includeNativeLists {
                style.textLists = (1...list.depth).map { depth in
                    NSTextList(markerFormat: list.kind == .ordered ? .decimal : NSTextList.MarkerFormat(rawValue: ListResolver.unorderedMarkers[depth - 1]), options: 0)
                }
            }
        }
        return style
    }

    static func font(for style: InlineStyle, block: BlockKind) -> NSFont {
        let code = block.isCode || style.marks.contains(.code) || style.font?.monospaced == true
        var size: CGFloat = 14
        var bold = style.marks.contains(.bold)
        if case .heading(let level) = block {
            size = level == 1 ? 22 : level == 2 ? 18 : 15
            bold = true
        }
        if let intent = style.font { size = CGFloat(intent.size) }
        if code { size = 13 }
        let base = code ? (NSFont(name: "Courier", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)) : .systemFont(ofSize: size)
        return bold ? NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask) : base
    }

    static func attributes(_ style: InlineStyle, block: BlockKind, exchange: Bool = false) -> [NSAttributedString.Key: Any] {
        var result: [NSAttributedString.Key: Any] = [
            .font: font(for: style, block: block), .foregroundColor: exchange ? NSColor.textColor : textColor,
            .paragraphStyle: paragraphStyle(block, includeNativeLists: exchange),
        ]
        if style.marks.contains(.italic) { result[.obliqueness] = 0.25 }
        if style.marks.contains(.underline) { result[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if style.marks.contains(.strike) { result[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if !exchange {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            result[.editorStyle] = try? encoder.encode(style)
        }
        return result
    }

    static func renderParagraph(_ paragraph: Paragraph, assets: [UUID: ImageAsset], separator: Bool, exchange: Bool = false) -> NSAttributedString {
        let output = NSMutableAttributedString(string: "")
        for run in paragraph.runs {
            var attrs = attributes(run.style, block: paragraph.kind, exchange: exchange)
            if let id = run.assetID, let asset = assets[id] {
                let attachment = NSTextAttachment(data: asset.data, ofType: asset.type)
                attachment.image = NSImage(data: asset.data)
                let scale = min(1, 72 / asset.height)
                attachment.bounds = NSRect(x: 0, y: -2, width: asset.width * scale, height: asset.height * scale)
                attrs[.attachment] = attachment
                if !exchange { attrs[.editorAsset] = id.uuidString }
            }
            output.append(NSAttributedString(string: run.text, attributes: attrs))
        }
        if separator { output.append(NSAttributedString(string: "\n", attributes: attributes(.plain, block: paragraph.kind, exchange: exchange))) }
        return output
    }

    static func render(_ document: EditorDocument, exchange: Bool = false) -> NSAttributedString {
        let output = NSMutableAttributedString(string: "")
        for i in document.paragraphs.indices {
            output.append(renderParagraph(document.paragraphs[i], assets: document.assets, separator: i < document.paragraphs.count - 1, exchange: exchange))
        }
        if !exchange { applyParagraphLayout(document, to: output) }
        return output
    }

    /// Only replace the changed paragraph span. Unrelated storage, glyphs and scroll position survive.
    static func apply(_ document: EditorDocument, previous: EditorDocument?, to view: NSTextView) {
        guard let storage = view.textStorage else { return }
        (view.layoutManager as? EditorLayoutManager)?.trailingKind = document.paragraphs.last!.kind
        var first = 0, oldEnd = previous?.paragraphs.count ?? 0, newEnd = document.paragraphs.count
        if let previous {
            while first < min(oldEnd, newEnd), previous.paragraphs[first] == document.paragraphs[first] { first += 1 }
            while oldEnd > first, newEnd > first, previous.paragraphs[oldEnd - 1] == document.paragraphs[newEnd - 1] {
                oldEnd -= 1; newEnd -= 1
            }
            // The last equal paragraph may acquire or lose its separator.
            if oldEnd != newEnd && first > 0 { first -= 1 }
        }
        let oldMap = previous.map(PositionMap.init)
        let newMap = PositionMap(document)
        let location = first < newMap.starts.count ? newMap.starts[first] : document.length
        let oldLimit = oldMap.map { oldEnd < $0.starts.count ? $0.starts[oldEnd] : $0.length } ?? storage.length
        let replacement = NSMutableAttributedString(string: "")
        if first < newEnd {
            for i in first..<newEnd {
                replacement.append(renderParagraph(document.paragraphs[i], assets: document.assets, separator: i < document.paragraphs.count - 1))
            }
        }
        let range = NSRange(location: min(location, storage.length), length: max(0, min(oldLimit, storage.length) - min(location, storage.length)))
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: replacement)
        storage.endEditing()
        updateGeometry(document, view: view)
    }

    /// Native input already changed the characters; only decorate the affected paragraphs.
    static func decorate(_ document: EditorDocument, indices: ClosedRange<Int>, view: NSTextView) {
        guard let storage = view.textStorage else { return }
        let map = PositionMap(document)
        (view.layoutManager as? EditorLayoutManager)?.trailingKind = document.paragraphs.last!.kind
        storage.beginEditing()
        for i in indices {
            let rendered = renderParagraph(document.paragraphs[i], assets: document.assets, separator: i < document.paragraphs.count - 1)
            rendered.enumerateAttributes(in: NSRange(location: 0, length: rendered.length)) { attrs, range, _ in
                let target = NSRange(location: map.starts[i] + range.location, length: range.length)
                if NSMaxRange(target) <= storage.length { storage.setAttributes(attrs, range: target) }
            }
        }
        storage.endEditing()
        updateGeometry(document, view: view)
    }

    /// Visual rhythm belongs to the projection, not the document or exchanged rich text.
    static func editorParagraphStyle(_ index: Int, in document: EditorDocument) -> NSParagraphStyle {
        let paragraph = document.paragraphs[index]
        let next = index + 1 < document.paragraphs.count ? document.paragraphs[index + 1] : nil
        let style = paragraphStyle(paragraph.kind).mutableCopy() as! NSMutableParagraphStyle
        if paragraph.kind.isCode {
            if index == 0 || !document.paragraphs[index - 1].kind.isCode {
                style.paragraphSpacingBefore = codeVerticalPadding + (index > 0 ? codeBlockSpacing : 0)
            }
            if next?.kind.isCode != true {
                style.paragraphSpacing = codeVerticalPadding + style.lineSpacing + (next != nil ? codeBlockSpacing : 0)
            }
        } else if !paragraph.isEmpty {
            switch paragraph.kind {
            case .heading:
                style.paragraphSpacing = headingSpacing
            case .body:
                // Code backgrounds already own their boundary spacing.
                style.paragraphSpacing = next?.kind.isCode == true ? 0 : bodySpacing
            case .list:
                // Nested and mixed list items still read as a continuous group.
                style.paragraphSpacing = next?.kind.list != nil || next?.kind.isCode == true ? 0 : bodySpacing
            case .codeLine: break
            }
        }
        return style
    }

    private static func applyParagraphLayout(_ document: EditorDocument, to storage: NSMutableAttributedString) {
        // Neighbors can change even when this paragraph's text did not (e.g. exiting a list).
        // Use the same styles in full, incremental and native-input projections.
        let map = PositionMap(document)
        storage.beginEditing()
        for i in document.paragraphs.indices {
            let range = map.range(of: i, includingSeparator: true)
            guard range.length > 0 else { continue }
            let style = editorParagraphStyle(i, in: document)
            var matches = true
            storage.enumerateAttribute(.paragraphStyle, in: range) { value, _, stop in
                if (value as? NSParagraphStyle) != style { matches = false; stop.pointee = true }
            }
            // Avoid invalidating unrelated glyphs during every keystroke in a long draft.
            if !matches { storage.addAttribute(.paragraphStyle, value: style, range: range) }
        }
        storage.endEditing()
    }

    static func updateGeometry(_ document: EditorDocument, view: NSTextView) {
        if let storage = view.textStorage { applyParagraphLayout(document, to: storage) }
        let markers = ListResolver.resolve(document)
        let maxWidth = markers.values.map { ($0.marker as NSString).size(withAttributes: [.font: ListMarkerRenderer.font(for: $0.kind)]).width }.max() ?? 0
        view.textContainerInset = NSSize(width: max(EditorAppearance.horizontalInset - 5, maxWidth + 4 - 22), height: 20)
        view.defaultParagraphStyle = editorParagraphStyle(document.paragraphs.count - 1, in: document)
        if document.paragraphs.last!.isEmpty {
            view.layoutManager?.invalidateLayout(forCharacterRange: NSRange(location: document.length, length: 0), actualCharacterRange: nil)
        }
        view.needsDisplay = true
    }

    static func decodeNative(_ text: NSAttributedString, assets: [UUID: ImageAsset]) -> EditorDocument {
        var result = EditorDocument(paragraphs: [], assets: assets)
        var current = Paragraph()
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attrs, range, _ in
            let style = (attrs[.editorStyle] as? Data).flatMap { try? JSONDecoder().decode(InlineStyle.self, from: $0) } ?? .plain
            let piece = (text.string as NSString).substring(with: range)
            if let raw = attrs[.editorAsset] as? String, let id = UUID(uuidString: raw), assets[id] != nil {
                for _ in piece.utf16 { current.runs.append(.image(id)) }
                return
            }
            let parts = piece.components(separatedBy: "\n")
            for (i, part) in parts.enumerated() {
                if i > 0 { result.paragraphs.append(current); current = Paragraph() }
                if !part.isEmpty { current.runs.append(InlineRun(text: part, style: style)) }
            }
        }
        result.paragraphs.append(current)
        for i in result.paragraphs.indices { result.paragraphs[i].runs = Paragraph.coalesced(result.paragraphs[i].runs) }
        return result
    }
}
