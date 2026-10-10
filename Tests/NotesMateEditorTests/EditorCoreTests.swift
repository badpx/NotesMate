import XCTest
@testable import NotesMateEditor

final class EditorCoreTests: XCTestCase {
    func testHierarchicalSelectionScopes() {
        let document = EditorDocument(paragraphs: [
            Paragraph(runs: [InlineRun(text: "body")]),
            Paragraph(kind: .codeLine, runs: [InlineRun(text: "code")]),
            Paragraph(kind: .list(.unordered, 1), runs: [InlineRun(text: "A")]),
            Paragraph(kind: .list(.ordered, 2), runs: [InlineRun(text: "B")]),
            Paragraph(kind: .list(.unordered, 3), runs: [InlineRun(text: "C")]),
            Paragraph(kind: .list(.unordered, 2), runs: [InlineRun(text: "D")]),
            Paragraph(kind: .list(.unordered, 1), runs: [InlineRun(text: "E")]),
            Paragraph(kind: .list(.ordered, 1), runs: [InlineRun(text: "F")]),
            Paragraph(runs: [InlineRun(text: "tail")]),
        ])
        let map = PositionMap(document)
        func range(_ first: Int, _ last: Int) -> NSRange {
            NSRange(location: map.starts[first], length: NSMaxRange(map.range(of: last)) - map.starts[first])
        }
        let all = range(0, 8)
        XCTAssertEqual(SelectionExpander.scopes(in: document, at: 0), [range(0, 0), all])
        XCTAssertEqual(SelectionExpander.scopes(in: document, at: 1), [range(1, 1), all])
        XCTAssertEqual(SelectionExpander.scopes(in: document, at: 2), [range(2, 2), all])
        XCTAssertEqual(SelectionExpander.scopes(in: document, at: 3), [range(3, 3), range(2, 5), all])
        XCTAssertEqual(SelectionExpander.scopes(in: document, at: 4), [range(4, 4), range(2, 5), all])
        XCTAssertEqual(SelectionExpander.scopes(in: document, at: 5), [range(5, 5), range(2, 5), all])
        XCTAssertEqual(SelectionExpander.scopes(in: document, at: 6), [range(6, 6), all])
        XCTAssertEqual(SelectionExpander.scopes(in: document, at: 7), [range(7, 7), all])
        XCTAssertEqual(SelectionExpander.scopes(in: document, at: 8), [range(8, 8), all])
        XCTAssertEqual(SelectionExpander.scopes(in: .plain("only"), at: 0), [NSRange(location: 0, length: 4)])

        let orphan = EditorDocument(paragraphs: [
            Paragraph(kind: .list(.unordered, 3), runs: [InlineRun(text: "orphan")]),
            Paragraph(kind: .list(.unordered, 4), runs: [InlineRun(text: "child")]),
            Paragraph(runs: [InlineRun(text: "end")]),
        ])
        let orphanMap = PositionMap(orphan)
        XCTAssertEqual(SelectionExpander.scopes(in: orphan, at: 1), [
            orphanMap.range(of: 1),
            NSRange(location: 0, length: NSMaxRange(orphanMap.range(of: 1))),
            NSRange(location: 0, length: orphanMap.length),
        ])
    }

    func testCodeBlockSelectionScopes() {
        let document = EditorDocument(paragraphs: [
            Paragraph(runs: [InlineRun(text: "before")]),
            Paragraph(kind: .codeLine, runs: [InlineRun(text: "first")]),
            Paragraph(kind: .codeLine),
            Paragraph(kind: .codeLine, runs: [InlineRun(text: "last")]),
            Paragraph(runs: [InlineRun(text: "between")]),
            Paragraph(kind: .codeLine, runs: [InlineRun(text: "other")]),
            Paragraph(runs: [InlineRun(text: "after")]),
        ])
        let map = PositionMap(document)
        let firstBlock = NSRange(location: map.starts[1], length: NSMaxRange(map.range(of: 3)) - map.starts[1])
        let entireDocument = NSRange(location: 0, length: map.length)
        for index in 1...3 {
            XCTAssertEqual(SelectionExpander.scopes(in: document, at: index), [firstBlock, entireDocument])
        }
        XCTAssertEqual(SelectionExpander.scopes(in: document, at: 5), [map.range(of: 5), entireDocument])
        XCTAssertEqual(SelectionExpander.scopes(in: document, at: 4), [map.range(of: 4), entireDocument])
    }

    func testEmptySelectionScopesAdvanceToVisibleContent() {
        let body = EditorDocument.plain("before\n\nafter")
        XCTAssertEqual(SelectionExpander.scopes(in: body, at: 1), [NSRange(location: 0, length: body.length)])

        let list = EditorDocument(paragraphs: [
            Paragraph(runs: [InlineRun(text: "before")]),
            Paragraph(kind: .list(.unordered, 1), runs: [InlineRun(text: "root")]),
            Paragraph(kind: .list(.unordered, 2)),
            Paragraph(kind: .list(.unordered, 3), runs: [InlineRun(text: "child")]),
            Paragraph(kind: .list(.ordered, 1)),
            Paragraph(runs: [InlineRun(text: "after")]),
        ])
        let map = PositionMap(list)
        let subtree = NSRange(location: map.starts[1], length: NSMaxRange(map.range(of: 3)) - map.starts[1])
        let all = NSRange(location: 0, length: map.length)
        XCTAssertEqual(SelectionExpander.scopes(in: list, at: 2), [subtree, all])
        XCTAssertEqual(SelectionExpander.scopes(in: list, at: 4), [all])

        let code = EditorDocument(paragraphs: [
            Paragraph(runs: [InlineRun(text: "before")]),
            Paragraph(kind: .codeLine, runs: [InlineRun(text: "line")]),
            Paragraph(kind: .codeLine),
            Paragraph(runs: [InlineRun(text: "after")]),
        ])
        let codeMap = PositionMap(code)
        XCTAssertEqual(SelectionExpander.scopes(in: code, at: 2), [
            NSRange(location: codeMap.starts[1], length: NSMaxRange(codeMap.range(of: 2)) - codeMap.starts[1]),
            NSRange(location: 0, length: codeMap.length),
        ])
        XCTAssertEqual(SelectionExpander.scopes(in: EditorDocument(), at: 0), [NSRange(location: 0, length: 0)])
    }

    func type(_ text: String, into state: inout EditorSnapshot) {
        for character in text {
            let inserted = String(character)
            EditorReducer.apply(.replace(state.session.selection, .plain(inserted, style: state.session.insertionStyle), preserveBlocks: false), to: &state)
            if let plan = MarkdownTriggerEngine.plan(in: state, inserted: inserted) { MarkdownTriggerEngine.apply(plan, to: &state) }
        }
    }

    func fresh(_ text: String = "") -> EditorSnapshot {
        let document = EditorDocument.plain(text)
        return EditorSnapshot(document: document, session: EditorSession(selection: NSRange(location: document.length, length: 0)))
    }
    func testEmptyDocumentAndEOF_M01_M04() {
        let empty = EditorDocument()
        XCTAssertEqual(empty.paragraphs.count, 1)
        XCTAssertEqual(empty.length, 0)
        let document = EditorDocument.plain("a\n")
        XCTAssertEqual(PositionMap(document).position(at: 2).index, 1)
        XCTAssertEqual(PositionMap(document).range(of: 1), NSRange(location: 2, length: 0))
    }

    func testBlockTriggers_T01_T06() {
        let cases: [(String, BlockKind)] = [("# ", .heading(1)), ("## ", .heading(2)), ("### ", .heading(3)),
            ("- ", .list(.unordered, 1)), ("* ", .list(.unordered, 1)), ("1. ", .list(.ordered, 1)),
            ("99. ", .list(.ordered, 1)), ("``` ", .codeLine)]
        for (input, kind) in cases {
            var state = fresh(); type(input, into: &state)
            XCTAssertEqual(state.document.paragraphs[0].kind, kind, input)
            XCTAssertEqual(state.document.text, "", input)
            XCTAssertEqual(state.session.selection.location, 0)
        }
        for input in ["#### ", "0. ", "100. ", "01. ", "> ", "--- ", " # ", "x- "] {
            var state = fresh(); type(input, into: &state)
            XCTAssertEqual(state.document.text, input)
            XCTAssertEqual(state.document.paragraphs[0].kind, .body)
        }
        for kind in [BlockKind.list(.ordered, 1), .list(.unordered, 3), .codeLine] {
            for input in ["# ", "## ", "### ", "- ", "* ", "1. ", "``` "] {
                var state = fresh(); state.document.paragraphs[0].kind = kind
                type(input, into: &state)
                XCTAssertEqual(state.document.text, input)
                XCTAssertEqual(state.document.paragraphs[0].kind, kind)
            }
        }
    }

    func testInlineTriggersAndNoLeak_T07_T14_T17() {
        for (source, mark) in [("**中文**", InlineMarks.bold), ("__中文__", .bold), ("*中文*", .italic),
                                ("_中文_", .italic), ("~~中文~~", .strike), ("`中文`", .code)] {
            var state = fresh(); type(source, into: &state)
            XCTAssertEqual(state.document.text, "中文", source)
            XCTAssertTrue(state.document.paragraphs[0].runs[0].style.marks.contains(mark))
            type("后续👩🏽‍💻", into: &state)
            XCTAssertEqual(state.document.paragraphs[0].runs.last!.style, .plain)
        }
        for source in ["** a**", "**a **", "abc_def_", "***a***", "~~a~b~~", "**\nword**"] {
            var state = fresh(); type(source, into: &state)
            XCTAssertEqual(state.document.text, source)
        }
        var state = fresh(); type("。**中文**", into: &state)
        XCTAssertEqual(state.document.text, "。中文")
        state = fresh(); type("**a*", into: &state)
        XCTAssertEqual(state.document.text, "**a*")
        type("*", into: &state); XCTAssertEqual(state.document.text, "a")
        state = fresh(); state.document.paragraphs[0].kind = .codeLine
        type("**code**", into: &state); XCTAssertEqual(state.document.text, "**code**")
    }

    func testEnterTabBackspaceMatrix_K01_K13_M02_M05() {
        for level in 1...3 {
            var end = fresh("title"); end.document.paragraphs[0].kind = .heading(level)
            EditorReducer.apply(.newline, to: &end)
            XCTAssertEqual(end.document.paragraphs.map(\.kind), [.heading(level), .body])
            XCTAssertTrue(end.document.paragraphs[1].isEmpty)
            var state = fresh("ab"); state.document.paragraphs[0].kind = .heading(level)
            state.session.selection.location = 1
            EditorReducer.apply(.newline, to: &state)
            XCTAssertEqual(state.document.paragraphs.map(\.kind), [.heading(level), .body])
            XCTAssertEqual(state.document.text, "a\nb")
            state = fresh("a"); state.document.paragraphs[0].kind = .list(.ordered, level)
            EditorReducer.apply(.newline, to: &state)
            XCTAssertEqual(state.document.paragraphs.map(\.kind), [.list(.ordered, level), .list(.ordered, level)])
            XCTAssertTrue(state.document.paragraphs[1].isEmpty)
        }
        var state = fresh(); state.document.paragraphs[0].kind = .list(.unordered, 8)
        let id = state.document.paragraphs[0].id
        for expected in (1...7).reversed().map({ BlockKind.list(.unordered, $0) }) + [.body] {
            EditorReducer.apply(.newline, to: &state)
            XCTAssertEqual(state.document.paragraphs.count, 1)
            XCTAssertEqual(state.document.paragraphs[0].kind, expected)
            XCTAssertEqual(state.document.paragraphs[0].id, id)
        }
        for text in ["", "a"] {
            state = fresh(text); state.document.paragraphs[0].kind = .list(.ordered, 1)
            for expected in [2, 3, 4, 5, 6, 7, 8, 8] {
                EditorReducer.apply(.indent(1), to: &state)
                XCTAssertEqual(state.document.paragraphs[0].kind, .list(.ordered, expected))
            }
            for expected in (1...7).reversed().map({ BlockKind.list(.ordered, $0) }) + [.body] {
                EditorReducer.apply(.indent(-1), to: &state)
                XCTAssertEqual(state.document.paragraphs[0].kind, expected)
            }
        }
        state = fresh("x")
        XCTAssertFalse(EditorReducer.apply(.indent(1), to: &state))
        for kind in [BlockKind.heading(1), .codeLine, .list(.ordered, 1), .list(.ordered, 2), .list(.ordered, 3)] {
            state = fresh("x"); state.document.paragraphs[0].kind = kind; state.session.selection.location = 0
            XCTAssertTrue(EditorReducer.apply(.backspaceAtStart, to: &state))
            XCTAssertEqual(state.document.text, "x")
            if let list = kind.list {
                XCTAssertEqual(state.document.paragraphs[0].kind, list.depth > 1 ? .list(list.kind, list.depth - 1) : .body)
            } else { XCTAssertEqual(state.document.paragraphs[0].kind, .body) }
        }
        state = fresh(); state.document.paragraphs[0].kind = .codeLine
        EditorReducer.apply(.newline, to: &state)
        XCTAssertEqual(state.document.paragraphs.map(\.kind), [.codeLine, .codeLine])
    }

    func testSelectionToggleAndListNumbering_K14_K16_L01_L04() {
        var state = fresh("a\nb\nc")
        state.session.selection = NSRange(location: 0, length: 2)
        EditorReducer.apply(.block(.heading(2)), to: &state)
        XCTAssertEqual(state.document.paragraphs.map(\.kind), [.heading(2), .body, .body])
        state.session.selection = NSRange(location: 0, length: state.document.length)
        EditorReducer.apply(.toggle(.bold), to: &state)
        state.document.paragraphs[1].runs[0].style.marks = []
        EditorReducer.apply(.toggle(.bold), to: &state)
        XCTAssertTrue(state.document.paragraphs.allSatisfy { $0.runs[0].style.marks.contains(.bold) })
        EditorReducer.apply(.toggle(.bold), to: &state)
        XCTAssertTrue(state.document.paragraphs.allSatisfy { $0.runs[0].style.marks.isEmpty })
        let document = EditorDocument(paragraphs: [1, 2, 2, 1, 2].map { Paragraph(kind: .list(.ordered, $0)) })
        let resolved = ListResolver.resolve(document)
        XCTAssertEqual((0..<5).map { resolved[$0]!.number }, [1, 1, 2, 2, 1])
        let orphan = EditorDocument(paragraphs: [Paragraph(kind: .list(.unordered, 3))])
        XCTAssertEqual(ListResolver.resolve(orphan)[0]?.exportDepth, 1)
        XCTAssertEqual(ListResolver.resolve(orphan)[0]?.marker, "◆")
    }

    func testUnicodeMappingAndReplacements_M07_M10() throws {
        let original = EditorDocument.plain("中👩🏽‍💻e\u{301}\n尾\n")
        let map = PositionMap(original)
        for i in 0...original.length {
            let position = map.position(at: i)
            XCTAssertEqual(map.starts[position.index] + position.offset, i)
        }
        var document = original
        let selected = (document.text as NSString).range(of: "👩🏽‍💻e\u{301}\n尾")
        document.replace(selected, with: .plain("新\n内容"))
        XCTAssertEqual(document.text, "中新\n内容\n")
        XCTAssertNoThrow(try document.validated())
        XCTAssertEqual(document.paragraphs[0].id, original.paragraphs[0].id)
    }

    func testHTMLGolden_E01_E09() {
        var document = EditorDocument(paragraphs: [
            Paragraph(runs: [InlineRun(text: "<&>", style: InlineStyle(marks: [.bold, .italic, .underline, .strike, .code]))]),
            Paragraph(kind: .heading(1), runs: [InlineRun(text: "标题")]),
            Paragraph(kind: .heading(2)), Paragraph(kind: .heading(3)),
            Paragraph(kind: .codeLine, runs: [InlineRun(text: "a  <b>")]), Paragraph(kind: .codeLine), Paragraph(),
        ])
        let html = HTMLExporter.export(document).bodyHTML
        XCTAssertTrue(html.hasPrefix("<div><b><i><u><strike><tt"))
        XCTAssertTrue(html.contains("&lt;&amp;&gt;"))
        XCTAssertTrue(html.contains("<h1 style=\"font-size:24px\">标题</h1>"))
        XCTAssertTrue(html.contains("<h2 style=\"font-size:18px\"><br></h2>"))
        XCTAssertTrue(html.contains("<div>a  &lt;b&gt;</div><div><br></div></pre>"))
        document = EditorDocument(paragraphs: [
            Paragraph(kind: .list(.ordered, 1), runs: [InlineRun(text: "A")]),
            Paragraph(kind: .list(.unordered, 3), runs: [InlineRun(text: "B")]),
            Paragraph(kind: .list(.ordered, 1), runs: [InlineRun(text: "C")]),
        ])
        XCTAssertEqual(HTMLExporter.export(document).bodyHTML, "<ol><li>A<ul><li>B</li></ul></li><li>C</li></ol>")
        let script = NotesSaver.makeScript(bodyHTML: "<div>\"\\</div>")
        XCTAssertFalse(script.contains("name:"))
        XCTAssertTrue(script.contains("body:"))
        XCTAssertTrue(script.contains("\\\"\\\\"))
    }

    func testRandomizedCoreInvariants() throws {
        var seed: UInt64 = 0x4e6f7465
        func random(_ max: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1; return Int((seed >> 32) % UInt64(max)) }
        var state = fresh()
        for _ in 0..<800 {
            let offset = random(state.document.length + 1)
            state.session.selection = NSRange(location: offset, length: 0)
            let commands: [EditorCommand] = [.block(.heading(random(3) + 1)), .list(.ordered), .indent(1), .indent(-1), .newline,
                .replace(state.session.selection, .plain("中"), preserveBlocks: false), .backspaceAtStart, .toggle(.strike)]
            EditorReducer.apply(commands[random(commands.count)], to: &state)
            XCTAssertNoThrow(try state.document.validated())
            XCTAssertLessThanOrEqual(NSMaxRange(state.session.selection), state.document.length)
            XCTAssertEqual(Set(state.document.paragraphs.map(\.id)).count, state.document.paragraphs.count)
            XCTAssertFalse(HTMLExporter.export(state.document).bodyHTML.isEmpty)
        }
    }

    func testEmptyPairsAndWhitespace_T08() {
        for source in ["****", "____", "~~~~", "``", "x * *", "**\u{00A0}a**", "**a*b**"] {
            var state = fresh(); type(source, into: &state)
            XCTAssertEqual(state.document.text, source)
        }
    }

    func testBlocksAcrossEmptyParagraphs_K15_K16_K13() {
        var state = fresh("a\n\nb")
        state.session.selection = NSRange(location: 0, length: state.document.length)
        EditorReducer.apply(.list(.ordered), to: &state)
        XCTAssertTrue(state.document.paragraphs.allSatisfy { $0.kind == .list(.ordered, 1) })
        state.document.paragraphs[1].kind = .body
        EditorReducer.apply(.list(.ordered), to: &state)
        XCTAssertTrue(state.document.paragraphs.allSatisfy { $0.kind == .list(.ordered, 1) })
        EditorReducer.apply(.list(.ordered), to: &state)
        XCTAssertTrue(state.document.paragraphs.allSatisfy { $0.kind == .body })
        state = fresh("code"); state.document.paragraphs[0].kind = .codeLine
        EditorReducer.apply(.newline, to: &state)
        XCTAssertEqual(state.document.paragraphs.map(\.kind), [.codeLine, .codeLine])
    }

    func testListInterruptionsAndEmptyHTML_L03_E07_E08() {
        let document = EditorDocument(paragraphs: [Paragraph(),
            Paragraph(kind: .list(.ordered, 1), runs: [InlineRun(text: "large", style: InlineStyle(font: FontIntent(size: 24, monospaced: false)))]),
            Paragraph(kind: .list(.unordered, 1)), Paragraph(kind: .list(.ordered, 1)), Paragraph(),
            Paragraph(kind: .list(.ordered, 1)), Paragraph()])
        let numbers = ListResolver.resolve(document)
        XCTAssertEqual(numbers[1]?.number, 1); XCTAssertEqual(numbers[3]?.number, 1); XCTAssertEqual(numbers[5]?.number, 1)
        let html = HTMLExporter.export(document).bodyHTML
        XCTAssertTrue(html.hasPrefix("<div><br></div>"))
        XCTAssertTrue(html.hasSuffix("<div><br></div>"))
        XCTAssertFalse(html.contains("h1")); XCTAssertFalse(html.contains("24px"))
    }

    /// 图片段落恒为正文（EditorSpec §8.2）：列表项任意落点插入图片都独立成正文行，
    /// 前缀保留在原列表项、后缀独立成段保留列表格式（对齐标题独立成段语义）。
    func testImageParagraphsStayBodyWhenInsertedIntoLists() {
        let id = UUID()
        let asset = ImageAsset(data: Data([0x01, 0x02]), width: 20, height: 20)
        func imageFragment(_ count: Int = 1) -> EditorDocument {
            EditorDocument(paragraphs: (0..<count).map { _ in Paragraph(runs: [.image(id)]) }, assets: [id: asset])
        }
        func listDoc(_ text: String, _ kind: ListKind = .unordered) -> EditorDocument {
            EditorDocument(paragraphs: [Paragraph(kind: .list(kind, 1), runs: text.isEmpty ? [] : [InlineRun(text: text)])])
        }

        // 空列表项：图片占据该行，成为正文
        var doc = listDoc("")
        doc.replace(NSRange(location: 0, length: 0), with: imageFragment())
        XCTAssertEqual(doc.paragraphs.map(\.kind), [.body])
        XCTAssertEqual(doc.text, "\u{FFFC}")

        // 行首：图片独立正文行在前，原文保留列表格式
        doc = listDoc("item")
        var fragment = imageFragment(); fragment.paragraphs.append(Paragraph())
        doc.replace(NSRange(location: 0, length: 0), with: fragment)
        XCTAssertEqual(doc.paragraphs.map(\.kind), [.body, .list(.unordered, 1)])
        XCTAssertEqual(doc.text, "\u{FFFC}\nitem")

        // 中间：前缀留在列表项，图片独立正文行，后缀独立成段保留列表格式
        doc = listDoc("item")
        fragment = imageFragment(); fragment.paragraphs.insert(Paragraph(), at: 0); fragment.paragraphs.append(Paragraph())
        doc.replace(NSRange(location: 2, length: 0), with: fragment)
        XCTAssertEqual(doc.paragraphs.map(\.kind), [.list(.unordered, 1), .body, .list(.unordered, 1)])
        XCTAssertEqual(doc.text, "it\n\u{FFFC}\nem")

        // 行尾（有序列表）：原列表项不变，图片正文行在后
        doc = listDoc("item", .ordered)
        fragment = imageFragment(); fragment.paragraphs.insert(Paragraph(), at: 0)
        doc.replace(NSRange(location: 4, length: 0), with: fragment)
        XCTAssertEqual(doc.paragraphs.map(\.kind), [.list(.ordered, 1), .body])
        XCTAssertEqual(doc.text, "item\n\u{FFFC}")

        // 连续多张各自独立正文行
        doc = listDoc("ab")
        fragment = imageFragment(2); fragment.paragraphs.insert(Paragraph(), at: 0); fragment.paragraphs.append(Paragraph())
        doc.replace(NSRange(location: 1, length: 0), with: fragment)
        XCTAssertEqual(doc.paragraphs.map(\.kind), [.list(.unordered, 1), .body, .body, .list(.unordered, 1)])
        XCTAssertEqual(doc.assetOrder.count, 2)

        // 富文本多行粘贴进列表项（preserveBlocks=true）：文字行成为同级列表项，图片行仍正文
        doc = listDoc("x")
        let rich = EditorDocument(paragraphs: [
            Paragraph(runs: [InlineRun(text: "p1")]),
            Paragraph(runs: [.image(id)]),
            Paragraph(runs: [InlineRun(text: "p2")]),
        ], assets: [id: asset])
        doc.replace(NSRange(location: 1, length: 0), with: rich, preserveBlocks: true)
        XCTAssertEqual(doc.paragraphs.map(\.kind), [.list(.unordered, 1), .body, .list(.unordered, 1)])
        XCTAssertEqual(doc.text, "xp1\n\u{FFFC}\np2")

        // 导出：图片段输出 <div>，不被 <li> 包裹；图片中断后编号重启（§11.5）
        doc = EditorDocument(paragraphs: [
            Paragraph(kind: .list(.ordered, 1), runs: [InlineRun(text: "一")]),
            Paragraph(runs: [.image(id)]),
            Paragraph(kind: .list(.ordered, 1), runs: [InlineRun(text: "二")]),
        ], assets: [id: asset])
        let html = HTMLExporter.export(doc).bodyHTML
        XCTAssertTrue(html.contains("<div>\(HTMLExporter.imagePlaceholder(0))</div>"))
        XCTAssertFalse(html.contains("<li>\(HTMLExporter.imagePlaceholder(0))"))
        XCTAssertEqual(ListResolver.resolve(doc)[2]?.number, 1)
    }

    /// 列表开关跳过纯图片段（EditorSpec §8.2）：图片行不产生列表标记；混合选区只作用于文字行。
    func testListToggleSkipsAttachmentOnlyParagraphs() {
        let id = UUID()
        let asset = ImageAsset(data: Data([0x01, 0x02]), width: 20, height: 20)
        var state = EditorSnapshot(document: EditorDocument(paragraphs: [
            Paragraph(runs: [.image(id)]),
            Paragraph(runs: [InlineRun(text: "文字")]),
        ], assets: [id: asset]), session: EditorSession())
        state.session.selection = NSRange(location: 0, length: 1)
        XCTAssertFalse(EditorReducer.apply(.list(.unordered), to: &state))
        XCTAssertEqual(state.document.paragraphs[0].kind, .body)
        state.session.selection = NSRange(location: 0, length: state.document.length)
        EditorReducer.apply(.list(.ordered), to: &state)
        XCTAssertEqual(state.document.paragraphs.map(\.kind), [.body, .list(.ordered, 1)])
    }
}
