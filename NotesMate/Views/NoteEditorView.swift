import SwiftUI
import UniformTypeIdentifiers

struct NoteEditorView: View {
    @Environment(\.displayScale) private var displayScale
    @StateObject private var model: NoteEditorModel
    @State private var isPinned: Bool
    @State private var isSaveHovered = false
    @State private var languageRevision = 0
    @FocusState private var saveFocused: Bool
    @State private var presentingMenuOrSheet = false
    @State private var showSavedNotice = false
    @State private var savedNoticeGeneration = 0
    @State private var folders: [NotesFolder] = []
    @State private var targetFolder: NotesFolder? = FolderCatalog.target
    @State private var isFolderSelectorAvailable = FolderCatalog.isSelectorAvailable
    @State private var catalogState: CatalogState = .loading

    private enum CatalogState {
        case loading, loaded
        case failed(message: String, unauthorized: Bool)
    }

    private let folderLoader: () throws -> [NotesFolder]
    private let onClose: () -> Void
    private let onPinChanged: (Bool) -> Void
    private let onSaved: () -> Void

    init(
        isPinned: Bool,
        onClose: @escaping () -> Void,
        onPinChanged: @escaping (Bool) -> Void,
        onSaved: @escaping () -> Void,
        model: NoteEditorModel = NoteEditorModel(),
        saveAction: ((NotesSaver.NoteContent) -> NotesSaver.SaveResult)? = nil,
        initialFolder: NotesFolder? = FolderCatalog.target,
        folderLoader: @escaping () throws -> [NotesFolder] = { try FolderCatalog.fetch() }
    ) {
        _isPinned = State(initialValue: isPinned)
        self.onClose = onClose
        self.onPinChanged = onPinChanged
        self.onSaved = onSaved
        self._model = StateObject(wrappedValue: model)
        self.saveAction = saveAction
        self.folderLoader = folderLoader
        self._targetFolder = State(initialValue: initialFolder)
    }

    private let saveAction: ((NotesSaver.NoteContent) -> NotesSaver.SaveResult)?

    var body: some View {
        let _ = languageRevision
        VStack(spacing: 0) {
            header
            Color(nsColor: EditorAppearance.separator).frame(height: 1 / displayScale)
            RichTextEditor(model: model, onSend: send)
                .background(Color(nsColor: EditorAppearance.canvas))
                .overlay { EditorTipOverlay(tips: model.tips) }
            Color(nsColor: EditorAppearance.separator).frame(height: 1 / displayScale)
            toolbar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: EditorAppearance.chrome))
        .clipShape(RoundedRectangle(cornerRadius: EditorAppearance.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: EditorAppearance.cornerRadius, style: .continuous)
                .strokeBorder(Color(nsColor: EditorAppearance.outline), lineWidth: 1 / displayScale)
                .allowsHitTesting(false)
        }
        .background(TipWindowObserver(tips: model.tips, bridge: model.bridge).frame(width: 0, height: 0))
        .onChange(of: model.isSaving) { _ in updateTipBlocking() }
        .onChange(of: showSavedNotice) { _ in updateTipBlocking() }
        .onChange(of: presentingMenuOrSheet) { _ in updateTipBlocking() }
        .onChange(of: saveFocused) { model.tips.saveFocus($0) }
        .onDisappear { model.tips.endSession() }
        .onReceive(model.tips.activityEvents) { showSavedNotice = false }
        .onReceive(NotificationCenter.default.publisher(for: EditorLanguage.didChangeNotification)) { _ in
            languageRevision += 1
            model.tips.activity(clearStatus: false)
            model.bridge.textView?.needsDisplay = true
        }
        .onAppear {
            if let message = model.recoveryMessage {
                let alert = NSAlert()
                alert.messageText = EditorLanguage.text("Unable to Restore Draft")
                alert.informativeText = message
                alert.runModal()
            }
            if isFolderSelectorAvailable { reloadCatalog() }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSImage(named: "AppIcon") ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            Text(verbatim: AppIdentity.productName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(nsColor: EditorAppearance.title))
            if model.isSaving {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 14, height: 14)
                    .accessibilityHint(EditorLanguage.text("Saving to Notes…"))
                    .accessibilityLabel(EditorLanguage.text("Saving to Notes"))
            }
            Spacer()
            HStack(spacing: 8) {
                Button {
                    isPinned.toggle()
                    onPinChanged(isPinned)
                } label: {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 11))
                        .frame(width: 22, height: 22)
                        .foregroundStyle(isPinned
                            ? Color(nsColor: EditorAppearance.selectedForeground)
                            : Color(nsColor: EditorAppearance.secondary))
                }
                .buttonStyle(.borderless)
                .modifier(FormatControlHover())
                .accessibilityLabel(isPinned ? EditorLanguage.text("Unpin") : EditorLanguage.text("Keep on Top"))
                .accessibilityHint(EditorLanguage.text("Keep the window open when clicking outside"))
                Button {
                    showSavedNotice = false
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11))
                        .frame(width: 22, height: 22)
                        .foregroundStyle(Color(nsColor: EditorAppearance.secondary))
                }
                .buttonStyle(.borderless)
                .modifier(FormatControlHover())
                .accessibilityLabel(EditorLanguage.text("Close Editor"))
                .accessibilityHint(EditorLanguage.text("Your draft will be kept"))
            }
        }
        .padding(.horizontal, EditorAppearance.horizontalInset)
        .frame(height: EditorAppearance.headerHeight)
        .overlay {
            if showSavedNotice {
                ViewThatFits(in: .horizontal) {
                    Text(EditorLanguage.text("Saved to Apple Notes")).fixedSize()
                    Text(EditorLanguage.text("Saved")).fixedSize()
                }
                    .accessibilityLabel(EditorLanguage.text("Saved to Apple Notes"))
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    .lineLimit(1)
                    .padding(.leading, 130)
                    .padding(.trailing, 84)
                    .allowsHitTesting(false)
            }
        }
        .task(id: savedNoticeGeneration) {
            guard showSavedNotice else { return }
            do { try await Task.sleep(nanoseconds: 2_000_000_000) }
            catch { return }
            showSavedNotice = false
        }
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            Button(action: showBlockMenu) {
                Text("#").font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(nsColor: EditorAppearance.secondary))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .modifier(FormatControlHover())
            .accessibilityLabel(EditorLanguage.text("Paragraph Style"))
            .accessibilityHint(EditorLanguage.text("Paragraph Style"))
            Button(action: showInlineMenu) {
                Text(verbatim: "Aa")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Color(nsColor: EditorAppearance.secondary))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .modifier(FormatControlHover())
            .accessibilityLabel(EditorLanguage.text("Text Style"))
            .accessibilityHint(EditorLanguage.text("Text Style"))

            Button {
                model.toggleList(.unordered)
            } label: {
                Image(systemName: "list.bullet")
                    .foregroundStyle(model.selectedBlock?.list?.kind == .unordered ? Color(nsColor: EditorAppearance.selectedForeground) : Color(nsColor: EditorAppearance.secondary))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .modifier(FormatControlHover())
            .accessibilityLabel(EditorLanguage.text("Bulleted List"))

            Button {
                model.toggleList(.ordered)
            } label: {
                Image(systemName: "list.number")
                    .foregroundStyle(model.selectedBlock?.list?.kind == .ordered ? Color(nsColor: EditorAppearance.selectedForeground) : Color(nsColor: EditorAppearance.secondary))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .modifier(FormatControlHover())
            .accessibilityLabel(EditorLanguage.text("Numbered List"))

            Button(action: chooseImages) {
                Image(systemName: "photo")
                    .foregroundStyle(Color(nsColor: EditorAppearance.secondary))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .modifier(FormatControlHover())
            .accessibilityHint(EditorLanguage.text("Add Image"))
            .accessibilityLabel(EditorLanguage.text("Add Image"))

            Spacer(minLength: 4)

            if isFolderSelectorAvailable {
                Color(nsColor: EditorAppearance.separator)
                    .frame(width: 1 / displayScale, height: 20)

                FolderFolderButton(
                    name: targetFolder?.name ?? EditorLanguage.text("Default"),
                    isSelected: targetFolder != nil,
                    fullName: targetFolder.map { EditorLanguage.format("Save folder: {0}", $0.name) } ?? EditorLanguage.text("Save folder: Default")
                ) {
                    showFolderMenu()
                }
            }

            Button(action: { model.bridge.requestSave() }) {
                Image("SaveNote")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                    .foregroundStyle(model.isEmpty && !model.isComposing
                        ? Color(nsColor: EditorAppearance.disabledForeground)
                        : Color(nsColor: EditorAppearance.saveForeground))
                    .frame(width: 40, height: 28)
                    .background(saveBackgroundColor, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.borderless)
            .disabled(model.isEmpty && !model.isComposing)
            .focused($saveFocused)
            .onHover {
                isSaveHovered = $0
                model.tips.saveHover($0)
            }
            .overlay(alignment: .bottomTrailing) {
                SaveShortcutTip(tips: model.tips).offset(y: -34)
            }
            .animation(.easeOut(duration: 0.12), value: isSaveHovered)
            .accessibilityLabel(EditorLanguage.text("Save to Notes"))
            .accessibilityHint(model.isEmpty
                ? EditorLanguage.text("Add content to save a note")
                : EditorLanguage.text("Command Return"))
        }
        .padding(.horizontal, EditorAppearance.horizontalInset)
        .frame(height: EditorAppearance.toolbarHeight)
        .disabled(model.isSaving)
    }

    /// SwiftUI Menu bridges to NSPopUpButton and ignores the label's hover and hit-area
    /// modifiers. Use a Button for the visible control, then present the native menu.
    private func showBlockMenu() {
        let menu = NSMenu()
        var targets: [MenuActionTarget] = []
        for (title, kind) in [
            (EditorLanguage.text("Heading"), BlockKind.heading(1)),
            (EditorLanguage.text("Body"), .body),
            (EditorLanguage.text("Code Block"), .codeLine),
        ] {
            menu.addItem(Self.makeItem(title, state: model.selectedBlock == kind ? .on : .off, targets: &targets) {
                model.setBlock(kind)
            })
        }
        popUp(menu, keepingAlive: targets)
    }

    private func showInlineMenu() {
        let menu = NSMenu()
        var targets: [MenuActionTarget] = []
        menu.addItem(Self.makeItem(EditorLanguage.text("Bold"), state: model.isActive(.bold) ? .on : .off, targets: &targets) { model.toggleBold() })
        menu.addItem(Self.makeItem(EditorLanguage.text("Italic"), state: model.isActive(.italic) ? .on : .off, targets: &targets) { model.toggleItalic() })
        menu.addItem(Self.makeItem(EditorLanguage.text("Underline"), state: model.isActive(.underline) ? .on : .off, targets: &targets) { model.toggleUnderline() })
        menu.addItem(Self.makeItem(EditorLanguage.text("Strikethrough"), state: model.isActive(.strike) ? .on : .off, targets: &targets) { model.toggleStrike() })
        popUp(menu, keepingAlive: targets)
    }

    /// Use the same native menu presentation for the toolbar's format and folder buttons.
    private func showFolderMenu() {
        let menu = NSMenu()
        var targets: [MenuActionTarget] = []
        switch catalogState {
        case .loading:
            menu.addItem(Self.makeItem(EditorLanguage.text("Loading Notes folders…"), enabled: false, targets: &targets))
        case .failed(let message, let unauthorized):
            menu.addItem(Self.makeItem(EditorLanguage.text("Couldn’t Load Folders — Retry"), targets: &targets) {
                self.retryCatalog(message: message, unauthorized: unauthorized)
            })
        case .loaded:
            for item in Self.buildFolderMenuItems(
                folders: folders,
                targetFolder: targetFolder,
                targets: &targets,
                select: { folder in self.selectFolder(folder) }
            ) {
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        menu.addItem(Self.makeItem(EditorLanguage.text("Reload Folders"), targets: &targets) { self.reloadCatalog() })
        popUp(menu, keepingAlive: targets)
    }

    private func popUp(_ menu: NSMenu, keepingAlive targets: [MenuActionTarget]) {
        presentingMenuOrSheet = true
        model.tips.setBlocked(true)
        defer { presentingMenuOrSheet = false; updateTipBlocking() }
        // popUp 阻塞至菜单关闭，targets 在此期间保持存活（NSMenuItem.target 是弱引用）。
        _ = withExtendedLifetime(targets) {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    /// 废纸篓文件夹（保存到废纸篓没有意义），中英文系统名都排除。
    static let trashedFolderNames: Set<String> = ["Recently Deleted", "最近删除"]

    static func isTrashedFolder(_ folder: NotesFolder) -> Bool {
        trashedFolderNames.contains(folder.name)
    }

    /// 构建目录选择菜单项（internal 以便离线断言结构）。规则：
    /// 过滤废纸篓；多账户才显示组标题（11px 灰字禁用项）且组间分隔线；
    /// 有组标题时文件夹项统一缩进一级（目录数据无层级信息）。
    static func buildFolderMenuItems(
        folders: [NotesFolder],
        targetFolder: NotesFolder?,
        targets: inout [MenuActionTarget],
        select: @escaping (NotesFolder?) -> Void
    ) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        // 选中项是废纸篓时按未选择兜底
        let target = targetFolder.flatMap { isTrashedFolder($0) ? nil : $0 }
        let visible = folders.filter { !isTrashedFolder($0) }

        items.append(makeItem(EditorLanguage.text("Default Folder"), state: target == nil ? .on : .off, targets: &targets) {
            select(nil)
        })

        var order: [String] = []
        var grouped: [String: [NotesFolder]] = [:]
        for folder in visible {
            if grouped[folder.accountName] == nil { order.append(folder.accountName) }
            grouped[folder.accountName, default: []].append(folder)
        }
        let groups = order.map { (account: $0, folders: grouped[$0] ?? []) }
        let showHeaders = groups.count > 1

        for (index, group) in groups.enumerated() {
            if showHeaders {
                if index > 0 { items.append(.separator()) }
                let header = NSMenuItem()
                header.attributedTitle = NSAttributedString(
                    string: group.account,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 11),
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ]
                )
                header.isEnabled = false
                items.append(header)
            }
            for folder in group.folders {
                let item = makeItem(folder.name, state: target == folder ? .on : .off, targets: &targets) {
                    select(folder)
                }
                item.indentationLevel = showHeaders ? 1 : 0
                items.append(item)
            }
        }
        return items
    }

    private static func makeItem(
        _ title: String,
        state: NSControl.StateValue = .off,
        enabled: Bool = true,
        targets: inout [MenuActionTarget],
        action: (() -> Void)? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = enabled
        item.state = state
        if let action {
            let target = MenuActionTarget(action)
            targets.append(target)
            item.target = target
            item.action = #selector(MenuActionTarget.run(_:))
        }
        return item
    }

    private func selectFolder(_ folder: NotesFolder?) {
        // 废纸篓不可作为保存目标（兜底为默认文件夹）
        let folder = folder.flatMap { Self.isTrashedFolder($0) ? nil : $0 }
        FolderCatalog.target = folder
        targetFolder = folder
    }

    private func reloadCatalog() {
        catalogState = .loading
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try folderLoader() }
            DispatchQueue.main.async {
                switch result {
                case .success(let list):
                    folders = list
                    catalogState = .loaded
                    // 保存目标失效（不存在或落在废纸篓）时回落到默认文件夹。
                    if let target = targetFolder,
                       Self.isTrashedFolder(target) || !list.contains(where: { $0.id == target.id }) {
                        selectFolder(nil)
                    }
                case .failure(let error):
                    let scriptError = error as? NotesSaver.ScriptError
                    catalogState = .failed(message: error.localizedDescription,
                                           unauthorized: scriptError.map { NotesAutomationPermission.isAuthorizationError($0.number) } ?? false)
                }
            }
        }
    }

    private func retryCatalog(message: String, unauthorized: Bool) {
        if unauthorized { showError(message: message, unauthorized: true) }
        reloadCatalog()
    }

    private func chooseImages() {
        guard let textView = model.bridge.textView, let window = textView.window,
              window.attachedSheet == nil else { return }
        // Commit an active input-method candidate before remembering the insertion point.
        if textView.hasMarkedText() { textView.unmarkText() }
        let selection = model.bridge.state.session.selection
        presentingMenuOrSheet = true
        model.tips.setBlocked(true)
        let picker = NSOpenPanel()
        picker.title = EditorLanguage.text("Add Image")
        picker.prompt = EditorLanguage.text("Insert")
        picker.allowedContentTypes = [.image]
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = true
        picker.beginSheetModal(for: window) { response in
            defer { presentingMenuOrSheet = false; updateTipBlocking() }
            guard response == .OK else {
                window.makeFirstResponder(textView)
                return
            }
            var images: [NSImage] = []
            for url in picker.urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url), let image = NSImage(data: data),
                      image.isValid else {
                    let alert = NSAlert()
                    alert.messageText = EditorLanguage.text("Unable to Read Image")
                    alert.informativeText = EditorLanguage.format("Couldn’t open “{0}”. Check the file or choose another image.", url.lastPathComponent)
                    alert.beginSheetModal(for: window) { _ in window.makeFirstResponder(textView) }
                    return
                }
                images.append(image)
            }
            model.bridge.select(selection)
            model.bridge.insertImages(images)
            window.makeFirstResponder(textView)
        }
    }

    private var saveBackgroundColor: Color {
        if model.isEmpty && !model.isComposing { return Color(nsColor: EditorAppearance.disabledBackground) }
        return isSaveHovered
            ? Color(nsColor: EditorAppearance.saveHover)
            : Color(nsColor: EditorAppearance.save)
    }

    private func updateTipBlocking() {
        model.tips.setBlocked(model.isSaving || showSavedNotice || presentingMenuOrSheet)
    }

    private func send() {
        guard !model.isSaving, !model.isEmpty, !model.isComposing else { return }
        model.tips.activity()
        model.tips.setBlocked(true)
        showSavedNotice = false
        model.saveAsync(using: saveAction ?? NotesSaver.save) { result in
            defer { updateTipBlocking() }
            switch result {
            case .success:
                FolderCatalog.recordSuccessfulSave()
                isFolderSelectorAvailable = true
                targetFolder = FolderCatalog.target
                reloadCatalog()
                showSavedNotice = true
                savedNoticeGeneration += 1
                DispatchQueue.main.async { onSaved() }
            case .unauthorized:
                model.tips.showInformation(
                    id: "save.automation.permission",
                    message: EditorLanguage.text("Allow NotesMate to control Notes in System Settings → Privacy & Security → Automation, then retry.")
                )
            case .failed(let message):
                showError(message: message, unauthorized: false)
            }
        }
    }

    /// 文件夹名称截断：最多 4 个中文字符宽（全角=1 单位、ASCII=0.5 单位），
    /// 超出部分尾部截断加「…」，保证长名称不撑开工具栏。
    static func truncatedFolderName(_ name: String, maxUnits: Double = 4) -> String {
        var units = 0.0
        var result = ""
        for ch in name {
            let unit = ch.isASCII ? 0.5 : 1.0
            if units + unit > maxUnits { return result + "…" }
            units += unit
            result.append(ch)
        }
        return name
    }

    private func showError(message: String, unauthorized: Bool) {
        model.tips.setBlocked(true)
        defer { updateTipBlocking() }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        if unauthorized {
            alert.messageText = EditorLanguage.text("Permission to Control Notes Required")
            alert.informativeText = message + EditorLanguage.text("\n\nAllow NotesMate to control Notes in System Settings, then try again.")
            alert.addButton(withTitle: EditorLanguage.text("Open System Settings"))
            alert.addButton(withTitle: EditorLanguage.text("Cancel"))
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                NSWorkspace.shared.open(NotesAutomationPermission.settingsURL)
            }
        } else {
            alert.messageText = EditorLanguage.text("Unable to Save to Notes")
            alert.informativeText = message
            alert.addButton(withTitle: EditorLanguage.text("OK"))
            alert.runModal()
        }
    }
}

/// Hover 背景外扩贴合 Button 自身 bounds（点击热区 = hover 背景区）；
/// 热区尺寸由控件 label 的 frame 决定（工具栏按钮 label 带 28×28 frame；
/// 目录按钮 label 带 height: 28，宽度随内容）。
struct FormatControlHover: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHovered && isEnabled ? Color(nsColor: EditorAppearance.hover) : Color.clear)
            }
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}

/// 文件夹选择控件：普通 Button + NSMenu popUp（见 showFolderMenu 注释）。
/// label 布局完全由 SwiftUI 控制，名称区固定 56pt 左对齐，控件总宽度对任意名称恒定。
struct FolderFolderButton: View {
    let name: String
    let isSelected: Bool
    let fullName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .foregroundStyle(Color(nsColor: EditorAppearance.secondary))
                Text(NoteEditorView.truncatedFolderName(name))
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: EditorAppearance.secondary))
                    .lineLimit(1)
                    .frame(width: 56, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(Color(nsColor: EditorAppearance.secondary))
            }
            .padding(.horizontal, 6)
            .frame(height: 28)
        }
        .buttonStyle(.borderless)
        .modifier(FormatControlHover())
        .accessibilityHint(fullName)
        .accessibilityLabel(EditorLanguage.text("Choose Save Folder"))
    }
}

/// NSMenuItem 闭包 action 的 target 桥（NSMenuItem.target 为弱引用，由调用方保活）。
final class MenuActionTarget: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run(_ sender: Any?) { action() }
}
