import Foundation

enum EditorCommand {
    case block(BlockKind)
    case list(ListKind)
    case toggle(InlineMarks)
    case indent(Int)
    case newline
    case exitCodeAtDocumentEnd
    case backspaceAtStart
    case replace(NSRange, EditorDocument, preserveBlocks: Bool)
}

enum EditorReducer {
    @discardableResult
    static func apply(_ command: EditorCommand, to state: inout EditorSnapshot) -> Bool {
        let before = state
        let map = PositionMap(state.document)
        state.session.selection = map.clamped(state.session.selection)
        let selection = state.session.selection
        let indices = map.paragraphs(in: selection)
        switch command {
        case .block(let kind):
            guard kind.isValid else { return false }
            for i in indices {
                state.document.paragraphs[i].kind = kind
                for j in state.document.paragraphs[i].runs.indices { state.document.paragraphs[i].runs[j].style.font = nil }
            }
            resetInsertion(&state)
        case .list(let kind):
            // 图片段落恒为正文（EditorSpec §8.2）：列表开关跳过纯附件段。
            let targets = indices.filter { !state.document.paragraphs[$0].isAttachmentOnly }
            guard !targets.isEmpty else { return false }
            let remove = targets.allSatisfy { state.document.paragraphs[$0].kind.list?.kind == kind }
            for i in targets {
                let depth = state.document.paragraphs[i].kind.list?.depth ?? 1
                state.document.paragraphs[i].kind = remove ? .body : .list(kind, depth)
                for j in state.document.paragraphs[i].runs.indices { state.document.paragraphs[i].runs[j].style.font = nil }
            }
            resetInsertion(&state)
        case .indent(let change):
            // Work backwards so original paragraph offsets remain valid while code
            // indentation changes text length. Keep the selection on its original text.
            for i in indices.reversed() {
                if state.document.paragraphs[i].kind.isCode {
                    let paragraph = state.document.paragraphs[i]
                    let removed: Int
                    let inserted: Int
                    if change > 0 {
                        removed = 0
                        inserted = 1
                        state.document.paragraphs[i].runs = Paragraph.coalesced(
                            [InlineRun(text: "\t", style: paragraph.runs.first?.style ?? .plain)] + paragraph.runs)
                    } else {
                        removed = paragraph.text.hasPrefix("\t") ? 1 : paragraph.text.prefix(4).prefix(while: { $0 == " " }).count
                        inserted = 0
                        guard removed > 0 else { continue }
                        state.document.paragraphs[i].runs = paragraph.slice(NSRange(location: removed, length: paragraph.length - removed))
                    }
                    let start = map.starts[i]
                    func adjusted(_ offset: Int) -> Int {
                        if offset < start { return offset }
                        return offset >= start + removed ? offset + inserted - removed : start + inserted
                    }
                    let selection = state.session.selection
                    let lower = adjusted(selection.location)
                    state.session.selection = NSRange(location: lower, length: adjusted(NSMaxRange(selection)) - lower)
                    continue
                }
                guard let list = state.document.paragraphs[i].kind.list else { continue }
                let depth = list.depth + change
                state.document.paragraphs[i].kind = depth < 1 ? .body : .list(list.kind, min(ListResolver.maxDepth, depth))
            }
        case .toggle(let mark):
            if selection.length == 0 {
                if state.session.insertionStyle.marks.contains(mark) { state.session.insertionStyle.marks.subtract(mark) }
                else { state.session.insertionStyle.marks.formUnion(mark) }
                state.session.explicitInsertionStyle = true
            } else {
                var selected: [InlineRun] = []
                for i in indices {
                    let r = NSIntersectionRange(selection, map.range(of: i))
                    selected += state.document.paragraphs[i].slice(NSRange(location: max(0, r.location - map.starts[i]), length: r.length))
                        .filter { $0.assetID == nil }
                }
                let remove = !selected.isEmpty && selected.allSatisfy { $0.style.marks.contains(mark) }
                transformRuns(in: selection, state: &state) { style in
                    if remove { style.marks.subtract(mark) } else { style.marks.formUnion(mark) }
                }
            }
        case .newline:
            if selection.length > 0 {
                state.document.replace(selection, with: .plain(""))
                state.session.selection.length = 0
            }
            let currentMap = PositionMap(state.document)
            let position = currentMap.position(at: state.session.selection.location)
            let paragraph = state.document.paragraphs[position.index]
            if paragraph.isEmpty, let list = paragraph.kind.list {
                state.document.paragraphs[position.index].kind = list.depth > 1 ? .list(list.kind, list.depth - 1) : .body
            } else if paragraph.isEmpty, case .heading = paragraph.kind {
                state.document.paragraphs[position.index].kind = .body
            } else {
                let next: BlockKind
                switch paragraph.kind {
                case .list: next = paragraph.kind
                case .codeLine: next = .codeLine
                default: next = .body
                }
                let fragment = EditorDocument(paragraphs: [Paragraph(kind: paragraph.kind), Paragraph(kind: next)])
                state.document.replace(state.session.selection, with: fragment, preserveBlocks: true)
                if next != paragraph.kind {
                    for j in state.document.paragraphs[position.index + 1].runs.indices {
                        state.document.paragraphs[position.index + 1].runs[j].style.font = nil
                    }
                }
                state.session.selection.location += 1
            }
            resetInsertion(&state)
        case .exitCodeAtDocumentEnd:
            let position = map.position(at: selection.location)
            guard selection.length == 0, position.index == state.document.paragraphs.count - 1,
                  state.document.paragraphs[position.index].kind.isCode else { return false }
            state.document.paragraphs.append(Paragraph())
            state.session.selection = NSRange(location: state.document.length, length: 0)
            resetInsertion(&state)
        case .backspaceAtStart:
            let position = map.position(at: selection.location)
            guard selection.length == 0, position.offset == 0 else { return false }
            let kind = state.document.paragraphs[position.index].kind
            if kind.isCode, position.index > 0, state.document.paragraphs[position.index - 1].kind.isCode {
                // Inside one code block, Backspace deletes the paragraph separator;
                // it must not convert an empty code line into a body paragraph.
                let separator = NSRange(location: selection.location - 1, length: 1)
                state.document.replace(separator, with: .plain(""))
                state.session.selection = NSRange(location: separator.location, length: 0)
                resetInsertion(&state)
                return before != state
            }
            switch kind {
            case .body: return false
            case .list(let type, let depth): state.document.paragraphs[position.index].kind = depth > 1 ? .list(type, depth - 1) : .body
            default:
                state.document.paragraphs[position.index].kind = .body
                // 标题降级为纯正文：粘贴标题自带的显式粗体一并清除；手动 # 标题的粗体来自
                // kind 渲染、无 marks，不受影响。斜体/下划线/删除线保留。
                if kind.isHeading {
                    for j in state.document.paragraphs[position.index].runs.indices {
                        state.document.paragraphs[position.index].runs[j].style.marks.subtract(.bold)
                    }
                }
            }
            for j in state.document.paragraphs[position.index].runs.indices { state.document.paragraphs[position.index].runs[j].style.font = nil }
            resetInsertion(&state)
        case .replace(let range, let fragment, let preserve):
            let safe = map.clamped(range)
            // 光标落在粘贴内容末尾（标题独立成段产生的前缀段落不计入）
            let cursor = state.document.replace(safe, with: fragment, preserveBlocks: preserve)
            state.session.selection = NSRange(location: cursor, length: 0)
        }
        return before != state
    }

    static func resetInsertion(_ state: inout EditorSnapshot) {
        state.session.insertionStyle = .plain
        state.session.explicitInsertionStyle = true
    }

    static func transformRuns(in range: NSRange, state: inout EditorSnapshot, transform: (inout InlineStyle) -> Void) {
        let map = PositionMap(state.document)
        for i in map.paragraphs(in: range) {
            let paragraph = state.document.paragraphs[i]
            let r = NSIntersectionRange(range, map.range(of: i))
            guard r.length > 0 else { continue }
            let start = r.location - map.starts[i]
            var middle = paragraph.slice(NSRange(location: start, length: r.length))
            for j in middle.indices where middle[j].assetID == nil { transform(&middle[j].style) }
            state.document.paragraphs[i].runs = Paragraph.coalesced(
                paragraph.slice(NSRange(location: 0, length: start)) + middle +
                paragraph.slice(NSRange(location: start + r.length, length: paragraph.length - start - r.length)))
        }
    }
}
