# 编辑器实施与验收结果

日期：2026-09-20。对应 [格式规范](EditorSpec.md)、[设计方案](EditorDesign.md) 和 [99 项验收矩阵](EditorAcceptance.md)。

后续五项交互反馈的修复与复验见 §8。旧产物误测后的重新验收见 §9；仅修复滚动见 §10，八级列表扩展见 §11。之前各节保留历史记录，以最新章节及 EditorSpec 为当前状态。

命名说明：当前工程、target、模块和新构建产物均使用 NotesMate。下文保留历史验收时真实使用的旧进程、测试笔记标题与构建产物路径；复现时请使用本节已更新的命令。

草稿兼容清理说明：用户确认 2026-09-24 首次官网分发 v1.0 时已使用 JSON，发布前 RTFD 测试数据已清理。因此已移除 RTFD 草稿迁移及对应两项测试；下文 D05 和测试数量保留当时的验收事实，不代表当前功能或当前测试总数。JSON 草稿恢复与 RTFD 剪贴板交换仍保留。

## 1. 结论

新组件已接入正式应用：语义文档统一管理段落、行内格式和图片；原生 TextKit 负责输入与显示；导出、草稿、工具栏和历史均走模型。

本机 **44 项自动化测试全部通过**（Core 11、AppKit 24、持久化 9），Debug / Release 应用构建均成功。实际窗口已完成一条标题、列表、行内格式、撤销重做和本地发送的交互链路。

**完整发布验收尚未通过。** 实际中文候选窗、排水区鼠标点击/拖选、复杂折行与窗口缩放、macOS 13、系统 Notes 端到端仍需补验。下面分别列出已经执行的证据和缺口；44 个测试方法不能等同于 99 项矩阵全部通过。

## 2. 环境与复现

| 项目 | 实测环境 |
|---|---|
| 系统 | macOS 26.6.2，Apple Silicon |
| 编译器 | Xcode 26.0，Build 17A324 |
| 目标系统 | macOS 13.0 起；本轮没有 macOS 13 运行环境 |
| 自动化 | XCTest，真实 NSTextView / NSTextStorage / UndoManager / 独立 NSPasteboard |
| GUI 宿主 | `Tests/ManualHarness/main.swift`，复用正式 NoteEditorView 和 EditorTextView |
| 草稿隔离 | 自动化每例独立临时目录；GUI 使用 `/private/tmp/NotesMateEditorHarness` |
| GUI 保存 | 注入本地 HTML writer，没有向系统备忘录写入测试笔记 |
| 输入法 | 本机已选五笔 `com.apple.inputmethod.SCIM.WBX`；自动化未能建立可观察的真实中文候选会话 |

```bash
bash scripts/test-editor.sh

xcodebuild -project NotesMate.xcodeproj -scheme NotesMate \
  -configuration Debug -derivedDataPath build/editor-app CODE_SIGNING_ALLOWED=NO build
xcodebuild -project NotesMate.xcodeproj -scheme NotesMate \
  -configuration Release -derivedDataPath build/editor-release CODE_SIGNING_ALLOWED=NO build

bash scripts/build-editor-harness.sh
open build/NotesMateEditorHarness.app
```

本轮 `swift test` 使用 `build/editor-tests` scratch 目录和 `/private/tmp/notesmate-*` 模块/包缓存。受限 shell 中系统剪贴板服务不可用，因此原生测试在允许访问该服务的本机进程中执行；没有改变系统权限设置。构建使用 `CODE_SIGNING_ALLOWED=NO`，不代表已验证分发签名或公证。

最终测试摘要：`Executed 44 tests, with 0 failures (0 unexpected)`。应用两种配置均返回 `BUILD SUCCEEDED`。构建日志另有本机 CoreSimulator 服务不可用和无 AppIntents 元数据可提取的提示，没有 Swift 编译错误。

本地日志：`build/editor-test.log`、`build/editor-debug-build.log`、`build/editor-release-build.log`、`build/editor-harness-build.log`。这些是被 Git 忽略的本轮产物，重新运行可复现。

## 3. 自动化证据入口

- [EditorCoreTests.swift](../Tests/NotesMateEditorTests/EditorCoreTests.swift)：触发子集、键盘矩阵、Unicode、列表编号、HTML 和 800 步固定种子随机命令不变量。
- [EditorAppKitTests.swift](../Tests/NotesMateEditorTests/EditorAppKitTests.swift)：原生输入、IME API、历史、剪贴板、空末段布局、增量/全量投影一致性和长文档输入。
- [EditorPersistenceTests.swift](../Tests/NotesMateEditorTests/EditorPersistenceTests.swift)：空格式草稿、generation、图片 JSON 草稿、损坏源保留、保存失败与 revision 保护；当时的 RTFD 迁移测试已退役。

投影比较先经过 TextKit 字体 fallback 归一，再比较属性；附件比较数据、尺寸和模型 asset ID，不比较独立 NSTextAttachment 对象地址。随机测试覆盖状态不变量，不宣称覆盖所有随机 IME、鼠标或历史事件。

长文档样例：1,500 段、末尾连续插入 8 个字符，最终一次 Debug 测量合计约 **112ms**。这仅是本机无窗口输入样例，不是逐键延迟承诺，也不能代替滚动/缩放性能验收。普通绘制复用段落位置索引与列表编号，只遍历可见段；composition 预览随输入失效，滚动重绘复用预览。

## 4. 矩阵覆盖记录

“通过”指表中列明的自动化/GUI 检查通过；“部分”表示该 ID 仍有未执行的交互或变体。IME API 检查通过不能代替真实候选窗验收。测试方法中的 ID 是定位提示，最终覆盖边界以下表为准。

### 文档与范围

| ID | 结果 | 已执行证据 / 缺口 |
|---|---|---|
| M01–M05 | 通过 | 初始空节点、EOF 映射、正文末尾转列表、单字符列表 Enter、删光文字仍保留列表；GUI 观察空列表 |
| M06 | 通过 | 列表项内插入图片独立成正文行（不再续列表）；Enter 后续正文；保留末尾空段并验证复制/剪切往返 |
| M07 | 通过 | 中文、组合音符和复合 emoji 的范围映射、原生 Backspace 与替换 |
| M08 | 通过 | 半开区间末端位于下一段起点，不改变下一段 |
| M09 | 部分 | 选区与 upstream affinity 经 undo 恢复；真实反向拖选待验 |
| M10 | 通过 | 跨段 Delete 合并及 undo 恢复原 ID；全选带图列表 cut / undo / redo / paste |

### Markdown 触发

| ID | 结果 | 已执行证据 / 缺口 |
|---|---|---|
| T01–T05 | 通过 | 各合法块前缀、非法编号/标题/引用/分割线、非段首及前置空格；GUI 验证 H1 与无序列表 |
| T06 | 通过 | 有序/无序列表、代码中逐一键入各标题、列表、代码前缀，保持原文和块类型 |
| T07–T11 | 通过 | 全部行内标志、空内容/首尾空白/内部同符号、下划线边界、中文标点、半个闭合双星号 |
| T12–T14 | 通过 | 自动格式后继续输入不泄漏；选择通知和重布局不覆盖复位；工具栏粗体主动开启可继续输入 |
| T15 | 通过 | Undo 恢复字面标记，布局不重触发；Redo 恢复格式 |
| T16–T17 | 通过 | replacementRange 替换与多字符提交、代码内容不再解析、跨段/三连/前导零不触发 |
| T18 | 通过 | 同一 `- [ ]` 分别逐键输入与纯文本粘贴，前者普通列表、后者整串原文 |

### 键盘与选区

| ID | 结果 | 已执行证据 / 缺口 |
|---|---|---|
| K01 | 通过 | 原生入口 Enter 新建正文，并验证投影 |
| K02 | 通过 | H1/H2/H3 分别在中间和末尾 Enter；GUI H1 末尾 Enter |
| K03–K08 | 通过 | 三级列表续排、空项逐层退出、空/非空 Tab 同规则、上限无空历史、一级 Shift+Tab 退出、非列表无操作 |
| K09 | 通过 | 标题/代码段首 Backspace 降级；标题 Forward Delete 仍普通删字 |
| K10 | 通过 | L1/L2/L3 段首 Backspace 分别退出或降低一层，文字保留 |
| K11 | 部分 | 长折行列表内部删字不降级；未在真实视觉折行起点逐键验证 |
| K12–K13 | 通过 | 非空选区原生删除、非空代码续行、空代码保留并新建正文 |
| K14 | 部分 | marks 命令、空输入意图、选区样式已测，GUI 验证 ⌘I；全部实体快捷键组合尚未逐一 GUI 操作 |
| K15–K16 | 通过 | 跨段块格式包含中间空段；混合 marks/list 统一开启，再统一关闭 |
| K17 | 部分 | 主键盘/小键盘事件各调用保存一次；GUI ⌘Return 本地保存；真实 Notes 发送与按钮组合待端到端复验 |

### 列表与布局

| ID | 结果 | 已执行证据 / 缺口 |
|---|---|---|
| L01 | 部分 | 模型三级、末尾空项 66pt、排水区命中 44pt；GUI 二级空项；三种符号视觉对照未全验 |
| L02–L04 | 通过 | 父项切换编号 `1,1,2,2,1`、种类切换/正文中断重启、悬空层级导出合法嵌套 |
| L05 | 部分 | 长段输入、段落缩进与图片尺寸；混合字号/附件/emoji 同行的基线和折行视觉待验 |
| L06 | 部分 | 110 项列表、`100.` 编号及左边界不裁切几何检查；9/10/99/100 视觉对照待验 |
| L07 | 部分 | 初始/末尾空列表有正确几何，GUI 可见；中间空列表的完整视觉检查待验 |
| L08 | 部分 | 排水区坐标映射有测试；真实鼠标点击/拖选未完成，见 §6 |
| L09 | 部分 | 1,500 段输入测量、索引缓存；最小窗、Retina、连续滚动的视觉与响应待验 |
| L10 | 部分 | 字号归一、段落属性和局部投影一致性；全格式混排的实际视觉检查待验 |
| L11 | 通过 | GUI 初始占位、空标题/列表时隐藏、发送后恢复占位 |
| L12 | 部分 | 字体/缩进后的布局 API 已检查；真实候选窗锚点待验 |

### 输入法与剪贴板

| ID | 结果 | 已执行证据 / 缺口 |
|---|---|---|
| I01 | 部分 | marked text 中的标志保留；真实拼音星号/空格/回车待验 |
| I02 | 通过（API） | 提交前处于组合态，提交后仍跳过自动格式 |
| I03 | 部分 | 组合态拒绝格式命令与 ⌘Return/⌘B；真实 Tab/Shift+Tab 候选交互待验 |
| I04 | 部分 | 跨段选区组合提交/undo、草稿不含拼音中间态；取消/重新选候选待真实 IME 验证 |
| I05 | 部分 | 空列表组合的预览与索引更新；滚动/缩放后的真实候选定位待验 |
| I06 | 部分 | requestSave 先 unmark、同步模型再回调；候选窗打开时实际点击发送待验 |
| P01–P05 | 通过 | 文本不解析、字号档位、允许 marks/列表归一、PNG/TIFF 去重、坏 PNG 回退 TIFF |
| P06 | 部分 | Finder 文件 URL 多图读取和一次 undo 已测；两张不同图片的顺序视觉对照待验 |
| P07 | 部分 | RTFD 文本与多图混排、图数据保存；鼠标拖入文件事件待验 |
| P08 | 通过 | ≤72pt 缩略、图片 undo/redo、剪切恢复、草稿原始数据往返 |
| P09–P10 | 通过 | 规范外属性不进入模型；粘贴前缀后直接键入才触发，undo 后重排不补转换 |
| P11 | 通过 | 内部模型片段、标准 RTFD 回退、混合深度/空项/图片 cut→undo→redo→paste 保留结构和图片数据 |

### 历史、草稿与导出

| ID | 结果 | 已执行证据 / 缺口 |
|---|---|---|
| U01–U05 | 通过 | 自动转换与普通输入分组、原生 NSTextView 对照、格式/Tab/粘贴/删除同栈、增量投影 undo/redo |
| U06 | 部分 | 跨段 IME 提交一次撤销恢复；真实候选取消路径待验 |
| U07–U08 | 通过 | undo 后新编辑丢弃 redo，附件仍可恢复；保存失败保稿、成功清历史，revision 防止误清新内容 |
| D01–D04 | 通过 | 只改格式自动排队；空标题/列表/粗体输入意图恢复；清空不复活旧稿；串行 generation 只保留最新状态 |
| D05 | 通过 | flat RTFD 粗体迁移、目录 RTFD 带图迁移；源文件保留，清空后不复活 |
| D06 | 部分 | 损坏 JSON 原文件保留/备份、缺 asset 拒绝、写入路径错误不静默成功；进程在原子写入时被杀的故障注入未执行 |
| D07 | 通过 | 附件历史快照可恢复，persist 仅保留引用 asset；清空模型/历史后 assets 为空 |
| E01–E05 | 通过 | HTML 断言：首段格式、标题和代码段、合法父 li 内嵌套、文本转义、确定性 marks 嵌套 |
| E06 | 通过 | 图文和仅图附件顺序、无 U+FFFC；重复引用同一 asset 按两次出现导出 |
| E07–E09 | 通过 | 首尾空段、粘贴大字号不误猜标题、不可表达字号仅导出降级、AppleScript 无 name 且引号/反斜线转义 |
| E10 | 部分 | 注入 writer 的成功、拒绝、revision 保护；实际 AppleScript 权限/附件失败及 Notes 呈现未端到端执行 |

## 5. 实际窗口操作记录

使用独立 NSPanel 宿主，操作正式工具栏和编辑区：

1. 依次键入 `#`、空格，观察空 24pt 标题；输入 `Heading` 后 Enter，下一段正文。
2. 输入 `Body `、`**`、`bold`、`**`、` normal`，观察加粗范围正确，后续正文没有格式泄漏。
3. 新段输入 `-`、空格、Tab，观察二级空列表的标记和 caret；输入 `child`，连续 Enter 验证空项逐级退出。
4. 粘贴 `中文斜体测试`，选中后 ⌘I；观察中文合成斜体。打开段落菜单，验证五种样式及正文选中态；Undo / Redo 恢复一致。
5. 在 `child` 起点插入 `X`，Undo 恢复。⌘Return 保存本地 HTML，窗口显示 `saved locally`，编辑区清空、占位恢复、发送按钮禁用。

本地文件内容已核对：

```html
<h1 style="font-size:24px">Heading</h1><div>Body <b>bold</b> normal</div><ul><li>child</li></ul><div><i>中文斜体测试</i></div><div><br></div>
```

二级孤立列表导出压缩为根列表符合规范 D7；没有虚构空父项。此处的 `<i>` 不代表系统备忘录能可靠呈现中文斜体，仍沿用规范中的既定系统限制。

## 6. 未完成真机项及复验步骤

- **真实输入法**：自动化文字输入不能建立可观察的中文候选会话，尝试切换也未获得候选窗；API 测试只能证明桥接状态和撤销行为。需在拼音、五笔等真实输入法下执行 I01–I06、L12，尤其验证取消、重转换、组合时 Tab 和发送。
- **鼠标/窗口**：工具能读取 NSPanel 的 AX 与截图并执行文本/菜单操作，但坐标点击返回 `noWindowsAvailable`，因此不能把几何单测当成真实 gutter 点击或拖选通过。需在 L1–L3、长行、图片行分别点击排水区、拖选、使用 Home/方向键，缩放至最小窗口并滚动复验。
- **macOS 13**：目标编译通过不等于最低系统运行通过。需在 macOS 13 运行相同测试与上述人工链路，重点观察 TextKit EOF、UndoManager 与 IME。
- **系统备忘录**：本轮只检查 HTML/AppleScript 和注入 writer。发布前需用独立测试笔记验证保存、拒绝权限、附件失败和成功后清空；不重新探测已经冻结的 HTML 白名单和附件位置约束。

## 7. 本轮发现并修正的边界

- 空文本或末尾换行的列表没有有效 extra line fragment，修正为布局层提供几何，模型不插入隐藏占位字符。
- 原生连续输入与结构事务发生在同一事件时，Undo 分组可能关闭后未重建，补齐事件边界并与原生 NSTextView 对照。
- 自动格式复位可能被 selection/布局通知覆盖，显式输入意图独立保存并回归。
- 测试宿主没有 Edit 菜单时常见剪贴板快捷键不分派，编辑器补齐 ⌘A/C/X/V。
- 仅开启粗体但没有字符的草稿会被视为空稿，持久化扩展为保存 session 输入意图。
- 列表绘制仍重建全文位置索引，改为已提交模型索引和 IME 预览缓存。

未发现尚未修复的自动化失败。上述真机缺口仍是发布验收条件，不应将此报告解读为所有输入边界已穷尽。

## 8. 首轮使用反馈修复（2026-09-20）

| 反馈 | 处理和实测结果 |
|---|---|
| 标题输入后 `#` 保留 | 暂未复现。逐键 `# + 空格`、`## + 空格`、`### + 空格` 的模型/投影均删除前缀，再进入中文 marked text 并提交仍只有标题文字。GUI 通过实际 `Shift+3` 和空格按键再次验证前缀消失。仍需明确报告问题时的具体输入序列；未扩展语法为无空格触发，也未让工具栏无条件删除正文中的 `#`。 |
| 首次列表光标跑到行首 | 修正空段光标几何。原生 `firstRect` 在零字符列表中返回无效空矩形，不能用 extra fragment 的 x 正确就推断实际 caret 正确。现在由模型的段落缩进和 TextKit 的行片段统一提供空段绘制与输入法锚点，并显式刷新插入点。真实窗口中初次 `1. + 空格` 后光标位于编号右侧。 |
| 第二行首个中文使标记闪烁 | 修正组合预览的失效时机：开始 native marked-text 修改前清缓存，修改过程中的同步查询不复用缓存，返回后再缓存稳定预览；文档变更的索引和列表缓存也在同步布局前发布。新增 NSTextStorage 编辑通知内的断言，保证首次组合字符已经存在时不会仍把该行视为空行。真实候选输入仍无法由本机自动化建立，因此帧级闪烁待实际中文输入法复验。 |
| Shift+Tab / Enter 后 caret 未回缩 | 语义事务结束时立即完成布局、刷新 caret 和候选坐标；空段坐标与标记深度使用同一模型。自动化覆盖 `22 → 44 → 22 → 0` 及文末空列表退出；GUI 验证三级降为二级，以及继续 Enter 退出为正文，均无需额外输入字符。 |
| 回车后未滚到新空行 | GUI 修复前复现：连续回车后文档没有滚动条，caret 不在视口内。现在将最后一个 extra fragment 纳入文档高度，同步更新滚动容器中的文档 frame，再将空行 caret 滚入视口。GUI 输入正文后连续回车 35 次，无需追加字符就出现滚动条并显示末尾 caret。 |

修改落点：`EditorTextView.emptyCaretRect / finishSemanticLayout`、`AppKitInputBridge.applyProjection / runMarkedInput / presentation`。没有往文档插入隐藏占位字符，也没有改动标志识别子集。

新增四项 AppKit 回归：

- `testEmptyParagraphCaretGeometryImmediatelyAfterCommands`：真实 NSWindow 下立即读取空段 screen rect，首次列表及升降级位置无需后续字符纠正。修复前此例 12 条坐标断言失败，修复后通过。
- `testReturnScrollsEmptyLastLineImmediately`：在查询 `firstRect` 之前记录滚动状态，断言回车后末尾空行已经在视口内。
- `testHeadingPrefixIsConsumedBeforeTextAndComposition`：三级标题前缀均清除，后续中文组合提交仍无标志残留。
- `testFirstMarkedCharacterNeverUsesStaleEmptyListPreview`：有序/无序列表第二行进入组合时，在 native storage 编辑通知回调内断言预览文本、位置、列表语义已经一致。

全量 `swift test`：48 项（AppKit 28、Core 11、持久化 9），0 failures。Debug 和 Release 应用构建均成功。日志为 `build/editor-followup-test.log`、`build/editor-followup-debug.log`、`build/editor-followup-release.log`；修复前坐标失败记录为 `build/editor-followup-before.log`。

布局刷新采用公开的 [NSTextView.updateInsertionPointStateAndRestartTimer](https://developer.apple.com/documentation/appkit/nstextview/updateinsertionpointstateandrestarttimer(_:)) 及输入上下文坐标失效接口；候选窗的实际呈现仍须按前述真机门槛验收。

## 9. 撤下 2/4/5 追加修复，重新验收

用户确认之前使用旧产物验收。重新核对后，第 2、4 项只能确认无窗口可见性的坐标 API 异常，不能据此确认实际可见光标出现同样问题；之前“已修复并验证”的结论过强。第 5 项确实在新方案的隔离 NSPanel 宿主中观察到，但正式应用尚需复验。

为便于比较，已将第 2、4、5 项作为一个整体从工作区撤下，包括 `emptyCaretRect`、`firstRect` / 插入点绘制覆盖、`finishSemanticLayout` 及两个配套回归测试。恢复原先的 `scrollRangeToVisible` 路径；**保留语义编辑器重构、第 3 项 IME 预览失效时序修复及其测试、标题前缀测试**。

暂存记录：`ae05f1abec2efbb7a25aeb2cf9874e27621e5cdf`，创建时为 `stash@{0}`，名称 `editor-followup-245: empty caret and Return scrolling; isolated from new editor`。只含 3 个文件中的 95 行追加和 1 行替换，不包含整个编辑器重构。

由于新组件本身尚未提交、相关文件仍是 untracked，暂存使用独立临时索引和基线快照，不改变真实暂存区或当前分支。恢复这组改动应提取差异应用：

```bash
git diff ae05f1abec2efbb7a25aeb2cf9874e27621e5cdf^1 ae05f1abec2efbb7a25aeb2cf9874e27621e5cdf -- | git apply
```

另保存同一补丁于 `build/editor-stash-245/restore-245.patch`，已执行 `git apply --check` 验证。该特殊基线下不使用普通 `git stash pop` 覆盖尚未跟踪的新组件文件。

重新验收产物独立输出至：`build/editor-retest-no-245/Build/Products/Debug/NoteMenu.app`。请先退出旧的 NoteMenu 进程，再从这个路径启动；此前其他 build 目录仍保留各自旧版本。

该版本 Debug 构建成功，剩余 46 项自动化测试全部通过（撤下的 2 项测试随修复一起暂存）。对应日志：`build/editor-retest-no-245-build.log`、`build/editor-retest-no-245-tests.log`。

## 10. 用户复验后仅修复问题 5

用户在新产物中确认只复现回车不立即滚动。本轮在 §9 的工作区基础上，仅增加 `EditorTextView.scrollSelectionAfterLayout` 并由语义投影完成后调用：先完成 TextKit 布局，将末尾无 glyph 的空行计入文档高度，再滚入该行。没有恢复 `emptyCaretRect`、`firstRect` 覆盖、插入点绘制覆盖或插入点计时器更新，第 2、4 项修复继续保留在 stash 中。第 3 项维持 §9 的已有状态，本轮未作调整。

新增 `testReturnScrollsToTrailingEmptyLineWithoutFurtherTyping`，分别覆盖正文、无序列表和有序列表。断言使用真实末尾行片段，而非可能无效的原生 `firstRect`，并在任何补充布局查询之前捕获视口和文档高度。修复前 6 条断言失败：末尾空行到达 550pt 时文档高度仍为 200pt、视口未覆盖新行；修复后全部通过。

全量 47 项自动化测试通过，Debug / Release 构建成功。GUI 宿主输入正文后连续回车 35 次，未输入后续字符，滚动条已接近底部且末尾空行 caret 可见。

本次验收产物：

- Debug：`build/editor-scroll-fix/Build/Products/Debug/NoteMenu.app`
- Release：`build/editor-scroll-fix-release/Build/Products/Release/NoteMenu.app`

日志：`build/editor-scroll-before.log`、`build/editor-scroll-tests.log`、`build/editor-scroll-debug.log`、`build/editor-scroll-release.log`。

原 `ae05f1abec2efbb7a25aeb2cf9874e27621e5cdf` stash 完整保留，含旧的组合修复方案；§9 中的整包恢复命令仅用于历史参考，现在已有独立滚动修复，不应再整包叠加。

## 11. 列表上限扩展到八级

按用户提供的系统备忘录截图，将有序/无序列表上限统一改为 8。无序标记依次为 `● ○ ◆ ◇ ■ □ ▲ △`，使用较小的 8pt 形状字形匹配正文旁的项目符比例；编号仍用 14pt 十进制数字。缩进保持每级 22pt，第八级为 176pt，再按 Tab 不新增层级或撤销项。

最大深度和符号表集中在 ListResolver。模型验证、Tab、富文本导入及标准 RTFD 交换同步更新；外部超过八层的列表导入时限制为八层。已有三级草稿仍兼容，新八级草稿沿用原版本格式，无须迁移。HTML 仍使用合法的嵌套 ul/ol，不扩展既定白名单。

新增八级列表集成测试，验证所有标记、每级缩进、两类列表 RTFD 往返、八层 HTML、外部十级导入限制以及非法第九级模型拒绝。更新上限 Tab / Undo、八级空项逐层 Enter 退出、八级空草稿恢复测试。全量 48 项测试通过，Debug 构建成功。

GUI 已逐级创建 L1–L8 列表，观察到八种对应形状，第八级再按 Tab 保持原层级。验收产物：`build/editor-eight-levels/Build/Products/Debug/NoteMenu.app`；日志：`build/editor-eight-tests.log`、`build/editor-eight-build.log`。

## 12. 后台图文混排保存（2026-09-20）

已接入 HTML 图片位置槽位、逐次出现的独立临时文件、先附件交付再完整正文重写。保存成功条件包括附件数量与每张导出 PNG 的字节校验；之后才清理临时文件。失败时草稿由现有模型保留，尝试删除本次未完成笔记；回滚失败则保留图片并提示检查备忘录。

自动化覆盖：重复图片位置、用户文本转义、路径编码、图片缺失时不创建笔记、成功清理、错误附件回滚、回滚失败保留文件、延迟就绪重试、纯文字单次后台创建。

`Tests/ManualHarness/InlineSaveProbe.swift` 使用正式 `NoteEditorModel.exportContent` 和 `NotesSaver.save`，仅将目标文件夹重定向至本次独立测试文件夹（不使用真实草稿）。实际创建两条笔记：

- “NoteMenu 正式保存验收”：正文 → 红图 → 同段正文 → 列表及蓝图 → 二级列表 → 正文 → 重复红图 → 最后正文。最终 3 张图按出现顺序导出，字节校验通过；GUI 图文顺序与重复图片正确。
- 纯图片：最终 1 张蓝图，保存后临时文件已清理，再次独立导出图片字节校验通过；GUI 正文只有 1 张图片。Notes 列表摘要仍曾显示创建中间态的“2张照片”，正文与脚本附件数均为 1，属于此轮观察到的摘要刷新差异。

两次保存均未改变前台应用，无粘贴、无导入确认。Notes 会把图片排成独立显示行；同段图文的先后顺序保留，但不承诺与编辑器完全一致的横向布局。未测试其它 macOS 版本及跨设备同步。

实机执行日志：`build/inline-implementation-results.log`。构建：`build/editor-inline-images/Build/Products/Debug/NoteMenu.app`。本轮只写入专用测试笔记，未修改已有用户笔记。

## 13. 保存等待提示（2026-09-20）

标题 NoteMenu 后增加小尺寸进度动画。模型发布 isSaving，保存期间禁用工具栏、编辑和重复保存；串行后台任务处理保存，主线程接收结果并恢复状态。后台脚本最初通过系统 osascript 解释器运行；2026-09-21 因真实应用权限违例改为进程内 OSAKit 独立语言实例，沿用相同的 Notes AppleScript 保存与图片校验流程。

62 项自动化测试通过，包含后台执行、重复请求拦截、失败状态恢复、快照后的内容保护和真实系统解释器烟测。Debug 构建成功。此次 GUI 动画验收被自动审批阻止：本地测试宿主启动被视为运行未识别应用，需要用户确认；未宣称动画已通过视觉验收。上一节原生同步保存的 Notes 实测不能替代本轮异步路径的端到端验收。

## 14. 按段落类型处理 Tab（2026-09-20）

列表维持整行层级增减、上限八级及一级退为正文。代码块 Tab 在行首插入制表符，Shift+Tab 删除行首制表符或最多四个前导空格；普通文本/标题 Tab 插入制表符并替换选区，Shift+Tab 无操作。组合输入期间仍由系统输入法处理 Tab。

65 项自动化测试通过，新增/更新覆盖：普通行光标与选区替换、代码行中光标、空代码行、多行选区边界、空格回退、撤销重做及投影一致性。Debug 构建产物位于 `build/editor-tab-behavior/Build/Products/Debug/NoteMenu.app`。本轮未执行 GUI 键盘验收。

### 2026-09-21：后台保存权限修复

- 系统日志确认 Notes 拒绝 osascript 子进程的 `core/crel` 创建事件，返回 `-10004`，与正文内容和代码块 HTML 无关。
- 改用 NoteMenu 进程内 OSAKit；每次调用创建独立 OSALanguageInstance，检查引擎支持线程安全后在原串行后台队列执行。保留沙盒与原权限声明，不增加权限或改用剪贴板。
- 错误码直接从 OSAKit 错误字典保留，不再解析子进程 stderr。失败保留草稿、附件验证及回滚行为不变。
- Debug 构建通过；66 项自动测试通过，包含实际后台 AppleScript 执行及 -10004 错误码保留测试。
- 独立命令行探针复用正式 NotesSaver：纯文字 `1`、正文加代码块均真实创建成功、读取内容验证成功，随后仅删除本次创建的测试笔记。
- 验证边界：命令行探针不等同正式应用沙盒验证。桌面工具两次访问新版应用均超时，因此正式应用内保存及带图保存仍待实机验收。


### 2026-09-21：后续验收与代码块交互

- 用户已实测确认 OSAKit 修复后，正式应用保存恢复正常；该结论补充前述命令行探针的验证边界。
- 输入字号：正文/列表/H3 15pt，H2 18pt，H1 22pt，代码 14pt；输入颜色及代码背景按 EditorSpec。
- 代码块连续 Enter 保留空行；末行 ↓ 进入正文，文档末尾自动增加正文段落。块内行首 Backspace 一次合并代码行，保持格式及光标位置。
- 背景按文字行几何绘制，排除段后间距，覆盖末尾空行及退出前后高度一致性。最终参数：左右内边距 4pt，上下内边距 2pt，上下外间距 2pt，圆角 4pt。
- 右键菜单分为“新建笔记/打开备忘录”和“开机自启动/退出”两组。
