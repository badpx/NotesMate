import AppKit

enum ClipboardCodec {
    static let fragmentType = NSPasteboard.PasteboardType("com.badpxx.notesmate.editor-fragment.v1")
    private struct Envelope: Codable { var version = 1; var document: EditorDocument }

    static func imageAsset(_ image: NSImage) -> ImageAsset? {
        guard let data = NotesSaver.pngData(for: image), image.size.width > 0, image.size.height > 0 else { return nil }
        return ImageAsset(data: data, width: image.size.width, height: image.size.height)
    }

    static func imageFragment(_ images: [NSImage]) -> EditorDocument {
        var result = EditorDocument()
        for image in images {
            guard let asset = imageAsset(image) else { continue }
            let id = UUID()
            result.assets[id] = asset
            result.paragraphs[0].runs.append(.image(id))
        }
        return result
    }

    static func images(on pasteboard: NSPasteboard) -> [NSImage] {
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type), let image = NSImage(data: data) { return [image] }
        }
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.compactMap { NSImage(contentsOf: $0) }
    }

    static func read(_ pasteboard: NSPasteboard, plainOnly: Bool = false, style: InlineStyle = .plain) -> (EditorDocument, Bool)? {
        if !plainOnly {
            if let data = pasteboard.data(forType: fragmentType), let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
               envelope.version == 1, let valid = try? envelope.document.validated(),
               valid.assets.values.allSatisfy({ NSImage(data: $0.data) != nil }) {
                return (remapped(valid), true)
            }
            let images = images(on: pasteboard)
            if !images.isEmpty { return (imageFragment(images), false) }
            for (type, format) in [(NSPasteboard.PasteboardType.rtfd, NSAttributedString.DocumentType.rtfd), (.rtf, .rtf), (.html, .html)] {
                if let data = pasteboard.data(forType: type),
                   let attributed = try? NSAttributedString(data: data, options: [.documentType: format], documentAttributes: nil) {
                    return (importRich(attributed).trimmingTrailingEmptyParagraphs(), true)
                }
            }
        }
        if let plain = pasteboard.string(forType: .string) {
            return (.plain(plain, style: style).trimmingTrailingEmptyParagraphs(), false)
        }
        return nil
    }

    static func write(_ fragment: EditorDocument, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        if let data = try? JSONEncoder().encode(Envelope(document: fragment)) { pasteboard.setData(data, forType: fragmentType) }
        let rendered = TextKitRenderer.render(fragment, exchange: true)
        if let data = rendered.rtfd(from: NSRange(location: 0, length: rendered.length), documentAttributes: [:]) {
            pasteboard.setData(data, forType: .rtfd)
        }
        pasteboard.setString(fragment.text.replacingOccurrences(of: "\u{FFFC}", with: ""), forType: .string)
    }

    static func remapped(_ source: EditorDocument) -> EditorDocument {
        var result = source
        let mapping = Dictionary(uniqueKeysWithValues: source.assets.keys.map { ($0, UUID()) })
        result.assets = Dictionary(uniqueKeysWithValues: source.assets.map { (mapping[$0.key]!, $0.value) })
        for i in result.paragraphs.indices {
            result.paragraphs[i].id = UUID()
            for j in result.paragraphs[i].runs.indices {
                if let id = result.paragraphs[i].runs[j].assetID { result.paragraphs[i].runs[j].assetID = mapping[id] }
            }
        }
        result.revision = 0
        return result
    }

    static func importRich(_ attributed: NSAttributedString) -> EditorDocument {
        let string = attributed.string as NSString
        var result = EditorDocument(paragraphs: [])
        var location = 0
        while location < string.length {
            let range = string.paragraphRange(for: NSRange(location: location, length: 0))
            let attrs = attributed.attributes(at: location, effectiveRange: nil)
            let lists = (attrs[.paragraphStyle] as? NSParagraphStyle)?.textLists ?? []
            let listKind: BlockKind? = lists.last.map {
                .list($0.markerFormat == .decimal ? .ordered : .unordered, min(ListResolver.maxDepth, lists.count))
            }
            var paragraph = Paragraph(kind: listKind ?? .body)
            var contentLength = range.length
            while contentLength > 0, [UInt16(10), 13, 0x2029].contains(string.character(at: location + contentLength - 1)) { contentLength -= 1 }
            // 标题档位（EditorSpec §8）：段落首个文本 run 粗体且 ≥21px → 标题 1、≥17px → 标题 2；
            // 等宽与其他字号一律归一正文。列表 kind 优先（备忘录列表项不会有标题字号）。
            var headingLevel: Int?
            attributed.enumerateAttributes(in: NSRange(location: location, length: contentLength)) { attributes, subrange, _ in
                if let attachment = attributes[.attachment] as? NSTextAttachment {
                    let image = attachment.image ?? attachment.fileWrapper?.regularFileContents.flatMap(NSImage.init(data:)) ?? attachment.contents.flatMap(NSImage.init(data:))
                    if let image, let asset = imageAsset(image) {
                        let id = UUID(); result.assets[id] = asset; paragraph.runs.append(.image(id))
                    }
                    return
                }
                let font = attributes[.font] as? NSFont ?? .systemFont(ofSize: 15)
                let traits = NSFontManager.shared.traits(of: font)
                let mono = traits.contains(.fixedPitchFontMask) || font.isFixedPitch
                var marks: InlineMarks = []
                if traits.contains(.boldFontMask) { marks.insert(.bold) }
                if traits.contains(.italicFontMask) || ((attributes[.obliqueness] as? NSNumber)?.doubleValue ?? 0) != 0 { marks.insert(.italic) }
                if ((attributes[.underlineStyle] as? NSNumber)?.intValue ?? 0) != 0 { marks.insert(.underline) }
                if ((attributes[.strikethroughStyle] as? NSNumber)?.intValue ?? 0) != 0 { marks.insert(.strike) }
                if headingLevel == nil, !mono, traits.contains(.boldFontMask) {
                    if font.pointSize >= 21 { headingLevel = 1 } else if font.pointSize >= 17 { headingLevel = 2 }
                }
                paragraph.runs.append(InlineRun(text: string.substring(with: subrange), style: InlineStyle(marks: marks, font: mono ? FontIntent(size: 14, monospaced: true) : nil)))
            }
            if let headingLevel, paragraph.kind == .body {
                paragraph.kind = .heading(headingLevel)
            }
            paragraph.runs = Paragraph.coalesced(paragraph.runs)
            // Chromium 等来源把列表标记符写进文本（如 "\t•\t"）：列表段落剥离行首标记前缀，
            // 避免与编辑器自绘标记重复显示；剥空则成为空列表项（内容与目标编辑器一致只出现一个符号）。
            if paragraph.kind.list != nil {
                Self.stripListMarkerPrefix(&paragraph)
            }
            result.paragraphs.append(paragraph)
            location = NSMaxRange(range)
        }
        // 片段尾部的段落结束符不是内容：裁掉尾部空正文段落（粘贴单段标题不新增空行）。
        // 空的列表/标题段落是真实内容（源片段里的空条目），保留。
        while result.paragraphs.count > 1,
              result.paragraphs.last!.isEmpty, result.paragraphs.last!.kind == .body {
            result.paragraphs.removeLast()
        }
        if result.paragraphs.isEmpty { result.paragraphs.append(Paragraph()) }
        return result
    }

    /// 剥离列表段落行首的标记符前缀（可选空白 + •◦▪· 或数字编号 1. 或 -/* + 可选空白），
    /// 按 UTF-16 长度从 runs 头部删除，保留其余 run 样式。
    private static func stripListMarkerPrefix(_ paragraph: inout Paragraph) {
        let text = paragraph.text as NSString
        var index = 0
        func isSpace(_ i: Int) -> Bool { [UInt16(9), 32].contains(text.character(at: i)) }
        while index < text.length, isSpace(index) { index += 1 }
        guard index < text.length else { return }  // 纯空白：不动
        var end = index
        let markers = CharacterSet(charactersIn: "•◦▪·")
        if let scalar = Unicode.Scalar(text.character(at: end)), markers.contains(scalar) {
            end += 1
        } else {
            var digitEnd = end
            while digitEnd < text.length,
                  CharacterSet.decimalDigits.contains(Unicode.Scalar(text.character(at: digitEnd))!) {
                digitEnd += 1
            }
            if digitEnd > end, digitEnd < text.length, text.character(at: digitEnd) == 46 {
                end = digitEnd + 1  // "1." / "12."
            } else if [UInt16(45), 42].contains(text.character(at: end)) {
                end += 1  // "-" / "*"
            } else {
                return  // 无标记前缀
            }
        }
        while end < text.length, isSpace(end) { end += 1 }
        guard end > 0 else { return }
        var remaining = end
        var runs = paragraph.runs
        while remaining > 0, !runs.isEmpty {
            if runs[0].length <= remaining {
                remaining -= runs[0].length
                runs.removeFirst()
            } else {
                runs[0].text = (runs[0].text as NSString).substring(from: remaining)
                remaining = 0
            }
        }
        paragraph.runs = Paragraph.coalesced(runs)
    }
}
