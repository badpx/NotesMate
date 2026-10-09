import Foundation

struct InlineMarks: OptionSet, Codable, Equatable {
    let rawValue: Int
    static let bold = Self(rawValue: 1 << 0)
    static let italic = Self(rawValue: 1 << 1)
    static let underline = Self(rawValue: 1 << 2)
    static let strike = Self(rawValue: 1 << 3)
    static let code = Self(rawValue: 1 << 4)
    static let supported: Self = [.bold, .italic, .underline, .strike, .code]
}

struct FontIntent: Codable, Equatable {
    var size: Int
    var monospaced: Bool
}

struct InlineStyle: Codable, Equatable {
    var marks: InlineMarks = []
    var font: FontIntent?
    static let plain = Self()
}

enum ListKind: String, Codable { case unordered, ordered }

enum BlockKind: Codable, Equatable {
    case body
    case heading(Int)
    case list(ListKind, Int)
    case codeLine

    var list: (kind: ListKind, depth: Int)? {
        if case let .list(kind, depth) = self { return (kind, depth) }
        return nil
    }
    var isCode: Bool { self == .codeLine }
    var isHeading: Bool {
        if case .heading = self { return true }
        return false
    }
    var isValid: Bool {
        switch self {
        case .heading(let level): return (1...3).contains(level)
        case .list(_, let depth): return (1...ListResolver.maxDepth).contains(depth)
        default: return true
        }
    }
}

/// Attachments are atomic UTF-16 positions. No list markers or invisible sentinels are stored.
struct InlineRun: Codable, Equatable {
    var text: String
    var style: InlineStyle = .plain
    var assetID: UUID?

    static func image(_ id: UUID) -> Self { Self(text: "\u{FFFC}", assetID: id) }
    var length: Int { (text as NSString).length }
}

struct Paragraph: Codable, Equatable, Identifiable {
    var id = UUID()
    var kind: BlockKind = .body
    var runs: [InlineRun] = []
    var text: String { runs.map(\.text).joined() }
    var length: Int { runs.reduce(0) { $0 + $1.length } }
    var isEmpty: Bool { runs.allSatisfy { $0.text.isEmpty } }

    init(id: UUID = UUID(), kind: BlockKind = .body, runs: [InlineRun] = []) {
        self.id = id
        self.kind = kind
        self.runs = Self.coalesced(runs)
    }

    func slice(_ range: NSRange) -> [InlineRun] {
        var result: [InlineRun] = []
        var offset = 0
        for run in runs {
            let intersection = NSIntersectionRange(range, NSRange(location: offset, length: run.length))
            if intersection.length > 0 {
                var piece = run
                piece.text = (run.text as NSString).substring(with: NSRange(
                    location: intersection.location - offset, length: intersection.length))
                result.append(piece)
            }
            offset += run.length
        }
        return result
    }

    static func coalesced(_ runs: [InlineRun]) -> [InlineRun] {
        var result: [InlineRun] = []
        for run in runs where !run.text.isEmpty {
            if let last = result.last, last.assetID == nil, run.assetID == nil, last.style == run.style {
                result[result.count - 1].text += run.text
            } else { result.append(run) }
        }
        return result
    }
}

struct ImageAsset: Codable, Equatable {
    var data: Data
    var type: String = "public.png"
    var width: Double
    var height: Double
}

struct EditorDocument: Codable, Equatable {
    var paragraphs: [Paragraph] = [Paragraph()]
    var assets: [UUID: ImageAsset] = [:]
    var revision: UInt64 = 0

    var text: String { paragraphs.map(\.text).joined(separator: "\n") }
    var length: Int { paragraphs.reduce(max(0, paragraphs.count - 1)) { $0 + $1.length } }
    var assetOrder: [UUID] { paragraphs.flatMap { $0.runs.compactMap(\.assetID) } }
    var canSend: Bool {
        !assetOrder.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var isPristine: Bool { paragraphs.count == 1 && paragraphs[0].kind == .body && paragraphs[0].isEmpty }

    static func plain(_ text: String, style: InlineStyle = .plain) -> Self {
        // Hard line breaks share one canonical representation; soft U+2028 stays inside its run.
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\u{2029}", with: "\n")
        return Self(paragraphs: normalized.components(separatedBy: "\n").map {
            Paragraph(runs: $0.isEmpty ? [] : [InlineRun(text: $0, style: style)])
        })
    }

    /// Preserve the left paragraph's identity when splitting/merging. The empty EOF node is real.
    /// 返回粘贴内容末尾在新文档中的位置（光标落点）。
    @discardableResult
    mutating func replace(_ range: NSRange, with fragment: EditorDocument, preserveBlocks: Bool = false) -> Int {
        let map = PositionMap(self)
        let range = map.clamped(range)
        let start = map.position(at: range.location)
        let end = map.position(at: NSMaxRange(range))
        let left = paragraphs[start.index]
        let right = paragraphs[end.index]
        let prefix = left.slice(NSRange(location: 0, length: start.offset))
        let suffix = right.slice(NSRange(location: end.offset, length: right.length - end.offset))
        var inserted = fragment.paragraphs.isEmpty ? [Paragraph()] : fragment.paragraphs
        for i in inserted.indices { inserted[i].id = UUID() }

        // 粘贴内容的段落数与内容末尾位置（光标落点）。
        let pastedCount = inserted.count
        inserted[0].id = left.id
        if preserveBlocks, inserted[0].kind.isHeading, !fragment.paragraphs[0].isEmpty, !left.isEmpty {
            // 规则二（EditorSpec §8）：非空落点（正文/列表项的行首/中间/行尾）粘贴标题——
            // 降级为加粗内联文本，目标段落格式不变，不切割段落。
            inserted[0].kind = left.kind
            for j in inserted[0].runs.indices {
                inserted[0].runs[j].style.font = nil
                inserted[0].runs[j].style.marks.formUnion(.bold)
            }
        } else if !inserted[0].kind.isHeading,
                  !preserveBlocks || start.offset > 0 || (left.isEmpty && left.kind != .body) {
            // 粘贴只插入字符内容：目标段落为空且带非正文块级格式（空列表项/空标题/空代码行）时，
            // 非标题首段继承目标格式；空行/空列表项粘贴标题时标题占据该行（规则一/三）。
            inserted[0].kind = left.kind
        }
        inserted[0].runs = Paragraph.coalesced(prefix + inserted[0].runs)
        let suffixLength = suffix.reduce(0) { $0 + $1.length }
        let last = inserted.count - 1
        // 标题段不并入后缀：片段末段是标题且目标行有后缀时，后缀独立成段（目标段落原格式）。
        let suffixSplit = preserveBlocks && inserted[last].kind.isHeading && suffixLength > 0
        let contentEndIndex = pastedCount - 1
        if suffixSplit {
            // 标题段不并入后缀：后缀独立成段（目标段落原格式）
            inserted.append(Paragraph(kind: right.kind, runs: suffix))
        } else {
            inserted[last].runs = Paragraph.coalesced(inserted[last].runs + suffix)
        }
        let contentEndOffset = inserted[contentEndIndex].length - (suffixSplit ? 0 : suffixLength)
        if !preserveBlocks {
            for i in inserted.indices { inserted[i].kind = left.kind }
        } else if case .list(let listKind, let depth) = left.kind {
            // 富文本多行粘贴进列表项：后续行中的普通段落成为同级列表项（对齐备忘录），
            // 粘贴内容自带的列表段落保留自身层级（可形成嵌套）；标题段落跳出列表。
            for i in inserted.indices where i > 0 && inserted[i].kind.list == nil && !inserted[i].kind.isHeading {
                inserted[i].kind = .list(listKind, depth)
            }
        }
        paragraphs.replaceSubrange(start.index...end.index, with: inserted)
        assets.merge(fragment.assets) { _, new in new }
        let newMap = PositionMap(self)
        return newMap.starts[start.index + contentEndIndex] + contentEndOffset
    }

    func fragment(in range: NSRange) -> EditorDocument {
        let map = PositionMap(self)
        let range = map.clamped(range)
        let indices = map.paragraphs(in: range)
        var output: [Paragraph] = []
        for i in indices {
            let p = paragraphs[i]
            let lower = max(0, range.location - map.starts[i])
            let upper = min(p.length, NSMaxRange(range) - map.starts[i])
            output.append(Paragraph(kind: p.kind, runs: p.slice(NSRange(location: lower, length: max(0, upper - lower)))))
        }
        // A selected separator carries the following empty boundary in clipboard text.
        if range.length > 0, NSMaxRange(range) > 0,
           (text as NSString).character(at: NSMaxRange(range) - 1) == 10 {
            output.append(Paragraph(kind: paragraphs[map.position(at: NSMaxRange(range)).index].kind))
        }
        var result = EditorDocument(paragraphs: output.isEmpty ? [Paragraph()] : output, assets: assets)
        result.pruneAssets()
        return result
    }

    /// 外部剪贴板片段的尾部段落结束符不是内容：裁掉尾部空**正文**段落（EditorSpec §8）。
    /// 空的列表/标题段落是真实内容（源片段里的空条目），保留。
    func trimmingTrailingEmptyParagraphs() -> EditorDocument {
        var result = self
        while result.paragraphs.count > 1,
              result.paragraphs.last!.isEmpty, result.paragraphs.last!.kind == .body {
            result.paragraphs.removeLast()
        }
        return result
    }

    mutating func pruneAssets() {
        let used = Set(assetOrder)
        assets = assets.filter { used.contains($0.key) }
    }

    func validated() throws -> Self {
        guard !paragraphs.isEmpty, Set(paragraphs.map(\.id)).count == paragraphs.count else {
            throw EditorDataError.invalidDocument
        }
        for paragraph in paragraphs {
            guard paragraph.kind.isValid else { throw EditorDataError.invalidDocument }
            for run in paragraph.runs {
                guard !run.text.contains("\n"), !run.text.contains("\r"),
                      run.style.marks.subtracting(.supported).isEmpty else { throw EditorDataError.invalidDocument }
                // Keep the old 12/24pt tiers valid for existing drafts and clipboard fragments.
                if let font = run.style.font, ![12, 14, 15, 16, 18, 22, 24].contains(font.size) { throw EditorDataError.invalidDocument }
                if let id = run.assetID {
                    guard run.text == "\u{FFFC}", let asset = assets[id], !asset.data.isEmpty,
                          asset.width.isFinite, asset.height.isFinite, asset.width > 0, asset.height > 0 else {
                        throw EditorDataError.invalidDocument
                    }
                }
            }
        }
        return self
    }
}

enum EditorDataError: Error { case invalidDocument, unsupportedVersion }

struct EditorSession: Codable, Equatable {
    var selection = NSRange(location: 0, length: 0)
    var affinity: UInt = 1 // NSSelectionAffinity.downstream, without importing AppKit into the core.
    var insertionStyle = InlineStyle.plain
    /// Keeps autoformat reset/tool commands authoritative across programmatic selection notifications.
    var explicitInsertionStyle = false
}

struct EditorSnapshot: Equatable {
    var document: EditorDocument
    var session: EditorSession
}
