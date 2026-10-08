# NotesMate

一个常驻 macOS 菜单栏的快速笔记录入工具：点击菜单栏图标弹出录入窗口，写完后一键保存到系统「备忘录」。

A lightweight macOS menu bar app for quickly jotting down notes and saving them to Apple Notes with one click.

[产品官网 / Website](https://badpx.github.io/NotesMate/) · [下载 / Download](https://github.com/badpx/NotesMate/releases/latest)

![NotesMate 输入窗口](docs/design/main-window-v3.png)

## 功能

- **菜单栏常驻**：点击状态栏图标展开/收起录入浮窗，无 Dock 图标打扰
- **快捷呼起**：按全局快捷键 ⌃⌘N（Control + Command + N）展开/收起录入窗口，已有草稿会保留；也可点击右键菜单顶部的“新建笔记”打开并聚焦录入窗口
- **打开备忘录**：按全局快捷键 ⌃⌘O（Control + Command + O），或在菜单栏图标右键菜单中选择“打开备忘录”，即可启动或切换到系统备忘录
- **富文本录入**：支持三级标题、加粗、斜体、下划线、删除线、代码行，以及八级项目符号和编号列表；支持规范限定的 Markdown 输入快捷语法
- **分级全选**：连续按 ⌘A，从当前段落、整个代码块或列表项逐级扩大到全文；最多三次
- **图片附件**：可直接粘贴、拖入图片，或点击底部“添加图片”按钮选择本地图片（支持多选），插入当前光标位置；保存时保留图文顺序
- **一键保存**：保存成功后自动清空录入窗口，保留首段格式，标题由系统备忘录派生
- **指定保存目录**：工具栏的目录菜单列出备忘录各账户下的文件夹，可切换保存目标；所选文件夹被删除时自动回退到默认文件夹
- **草稿恢复**：文字、空段落格式和原始图片自动保存，重启后恢复未保存的草稿
- **置顶模式**：置顶后浮窗不随点击外部收起，方便对照其他窗口整理内容
- **窗口位置记忆**：拖动标题栏可移动浮窗，后续呼起及重启后恢复该位置；显示器变化时自动调整到可见区域
- **开机自启**：右键菜单栏图标可开关登录时自动启动（基于 SMAppService）

## 系统要求

- macOS 13 或更高版本
- 首次保存笔记时，需要在系统弹窗中允许 NotesMate 控制「备忘录」（可在 系统设置 → 隐私与安全性 → 自动化 中管理）

## 构建

需要 Xcode 16 或更高版本：

```bash
xcodebuild -project NotesMate.xcodeproj -scheme NotesMate -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/NotesMate.app
```

或直接用 Xcode 打开 `NotesMate.xcodeproj` 运行。

官网分发使用 Developer ID 签名、公证和 DMG 打包脚本；GitHub Release 发布流程见 [发布说明](docs/Release.md)。

## 技术说明

- SwiftUI + AppKit：`NSStatusItem` + `NSPanel` 浮窗承载 SwiftUI 界面；编辑器使用语义文档模型、统一编辑命令和原生 `NSTextView` / TextKit 投影
- 写入备忘录：通过 AppleScript（`make new note` / `make new attachment`）实现，正文直接从模型导出为规范白名单 HTML，图片按顺序追加为附件；保存目标默认为默认文件夹，可经 AppleScript 枚举账户目录后改存指定文件夹，选择持久化在 UserDefaults
- 草稿：应用支持目录下的 `NotesMate/draft-v1.json` 原子保存模型、输入格式和图片；恢复校验失败时保留损坏源，后续写入前先备份
- 沙盒：开启 App Sandbox，通过 `com.apple.security.temporary-exception.apple-events` 获得控制备忘录的权限
- 应用图标：使用 `NotesMate/Resources/AppIcon.icon`，可直接用 Xcode 附带的 Icon Composer 打开。黄色背景由 Composer 定义，`Assets/note.svg` 是文字与笔形镂空的便笺矢量层；外轮廓由系统生成，不在素材里预先添加圆角底板或透明边距。
- 图标兼容：使用 Xcode 26 构建，macOS 26 使用分层图标，旧版 macOS 使用 Xcode 自动生成的静态回退图标（包含 `AppIcon.icns`），最低系统要求保持 macOS 13.0。原 PNG 和 `AppIcon.appiconset` 保留作设计参考；存在同名 `.icon` 时，Xcode 优先使用 Composer 工程，并自行生成回退图，而不是直接采用原 PNG。旧系统的实际显示效果仍需在对应系统上验证。
- 菜单栏图标：原图保存在 `assets/notesmate-status-icon.png`，采用白色便笺与透明文字、笔形镂空，生成 18pt 的 1x/2x 资源，以 template 模式适应深浅色背景。

## 编辑器测试

```bash
bash scripts/test-editor.sh
bash scripts/build-editor-harness.sh
open build/NotesMateEditorHarness.app
```

测试宿主复用正式编辑器，草稿和发送生成的 `export.html` 位于 `/private/tmp/NotesMateEditorHarness`，不会写入系统备忘录。自动化测试需要可访问 AppKit 和剪贴板的 macOS 用户会话。

格式定义见 [EditorSpec](docs/EditorSpec.md)，架构见 [EditorDesign](docs/EditorDesign.md)，自测证据与待验项目见 [EditorAcceptanceResults](docs/EditorAcceptanceResults.md)。

## License

MIT

## 多语言

界面支持简体中文、繁体中文、英文、日语、韩语、德语、法语、西班牙语、葡萄牙语、意大利语、菲律宾语、印度尼西亚语、马来西亚语、泰语和越南语。按系统首选语言匹配；不支持的语言回退英语。详见 [本地化说明](docs/Localization.md)。

Xcode 工程、target 和共享 Scheme 均名为 **NotesMate**，Swift Package 模块名为 `NotesMateEditor`。Bundle ID 保持 `com.badpxx.notesmate`；此次工程命名调整不改变现有草稿、偏好设置和自动化授权。
