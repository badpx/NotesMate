import Foundation

/// Semantic export: no inference from the displayed fonts, and no synthetic title paragraph.
enum HTMLExporter {
    struct Result {
        let bodyHTML: String
        let assetIDs: [UUID]
    }

    static func export(_ document: EditorDocument) -> Result {
        var imageIndex = 0
        func renderRuns(_ runs: [InlineRun]) -> String {
            HTMLExporter.renderRuns(runs) { _ in
                defer { imageIndex += 1 }
                return imagePlaceholder(imageIndex)
            }
        }
        let lists = ListResolver.resolve(document)
        var html = ""
        var index = 0
        func renderList(_ depth: Int) -> String {
            var output = ""
            while index < document.paragraphs.count, let item = lists[index], item.exportDepth == depth {
                let kind = item.kind
                let tag = kind == .ordered ? "ol" : "ul"
                output += "<\(tag)>"
                while index < document.paragraphs.count, let row = lists[index], row.exportDepth == depth, row.kind == kind {
                    let content = renderRuns(document.paragraphs[index].runs)
                    output += "<li>" + (content.isEmpty ? "<br>" : content)
                    index += 1
                    if let child = lists[index], child.exportDepth > depth { output += renderList(child.exportDepth) }
                    output += "</li>"
                }
                output += "</\(tag)>"
            }
            return output
        }
        while index < document.paragraphs.count {
            let paragraph = document.paragraphs[index]
            if let item = lists[index] { html += renderList(item.exportDepth); continue }
            if paragraph.kind.isCode {
                html += "<pre style=\"font-family:Courier;font-size:12px\">"
                while index < document.paragraphs.count, document.paragraphs[index].kind.isCode {
                    let content = renderRuns(document.paragraphs[index].runs)
                    html += "<div>" + (content.isEmpty ? "<br>" : content) + "</div>"
                    index += 1
                }
                html += "</pre>"
                continue
            }
            let content = renderRuns(paragraph.runs)
            let body = content.isEmpty ? "<br>" : content
            switch paragraph.kind {
            case .heading(1): html += "<h1 style=\"font-size:24px\">\(body)</h1>"
            case .heading(2): html += "<h2 style=\"font-size:18px\">\(body)</h2>"
            case .heading: html += "<div style=\"font-size:14px\"><b>\(body)</b></div>"
            default: html += "<div>\(body)</div>"
            }
            index += 1
        }
        return Result(bodyHTML: html, assetIDs: document.assetOrder)
    }

    static func imagePlaceholder(_ index: Int) -> String { "<!--NotesMateImage:\(index)-->" }

    static func renderRuns(_ runs: [InlineRun], image: (UUID) -> String = { _ in "" }) -> String {
        runs.map { run in
            if let id = run.assetID { return image(id) }
            var text = preservingWhitespace(run.text)
            if run.style.marks.contains(.code) || run.style.font?.monospaced == true {
                text = "<tt style=\"font-family:Courier;font-size:12px\">\(text)</tt>"
            }
            if run.style.marks.contains(.strike) { text = "<strike>\(text)</strike>" }
            if run.style.marks.contains(.underline) { text = "<u>\(text)</u>" }
            if run.style.marks.contains(.italic) { text = "<i>\(text)</i>" }
            if run.style.marks.contains(.bold) { text = "<b>\(text)</b>" }
            return text
        }.joined()
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// HTML collapses ordinary whitespace, including in <tt>. Encode boundary and
    /// repeated spaces explicitly while retaining ordinary word-wrap opportunities.
    /// Tabs export as four spaces, consistently in body, inline code and code blocks.
    static func preservingWhitespace(_ text: String) -> String {
        let characters = Array(text)
        return characters.enumerated().map { index, character in
            switch character {
            case "\t": return String(repeating: "&nbsp;", count: 4)
            case " ":
                return index == 0 || index == characters.count - 1 || characters[index - 1] == " "
                    || characters[index - 1] == "\u{2028}" || characters[index + 1] == "\u{2028}" ? "&nbsp;" : " "
            case "\u{2028}": return "<br>"
            default: return escape(String(character))
            }
        }.joined()
    }
}
