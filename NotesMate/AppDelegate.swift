import AppKit
import Carbon
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panelController: PanelController!
    private var hotKeys: [EventHotKeyRef] = []
    private var hotKeyHandler: EventHandlerRef?
    private static let newNoteHotKeyID = EventHotKeyID(signature: 0x4E4D4E55, id: 1)
    private static let openNotesHotKeyID = EventHotKeyID(signature: 0x4E4D4E55, id: 2)
    private static let didShowFirstLaunchEditorKey = "didShowFirstLaunchEditor"
    private static let firstLaunchAnchorRetryLimit = 50

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        FolderCatalog.prepareForLaunch(hadOpenedEditorBefore: UserDefaults.standard.bool(forKey: Self.didShowFirstLaunchEditorKey))

        panelController = PanelController()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let icon = NSImage(named: "StatusIcon")
            icon?.size = NSSize(width: 18, height: 18)
            icon?.isTemplate = true
            icon?.accessibilityDescription = AppIdentity.productName
            button.image = icon
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        registerHotKeys()
        refreshNotesAutomationPermission()
        // The status item may need more than one run-loop turn to acquire a window
        // and its final menu-bar frame. Never show or persist an unanchored panel.
        DispatchQueue.main.async { [weak self] in self?.showFirstLaunchEditorWhenReady() }
    }

    private func showFirstLaunchEditorWhenReady(attempt: Int = 0) {
        guard !UserDefaults.standard.bool(forKey: Self.didShowFirstLaunchEditorKey) else { return }
        if panelController.isVisible {
            UserDefaults.standard.set(true, forKey: Self.didShowFirstLaunchEditorKey)
            return
        }
        if let button = statusItem.button {
            let welcome = EditorLanguage.format("Hello, welcome to {0}.\nCapture ideas and save to Apple Notes.", AppIdentity.productName)
            if panelController.show(relativeTo: button, welcomeMessage: welcome) {
                UserDefaults.standard.set(true, forKey: Self.didShowFirstLaunchEditorKey)
                return
            }
        }
        guard attempt < Self.firstLaunchAnchorRetryLimit else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.showFirstLaunchEditorWhenReady(attempt: attempt + 1)
        }
    }

    private func recordManualFirstLaunchOpen() {
        if panelController.isVisible {
            UserDefaults.standard.set(true, forKey: Self.didShowFirstLaunchEditorKey)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !panelController.prepareToQuit() else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = EditorLanguage.text("Draft could not be saved locally. Keep the app open to avoid losing changes.")
        alert.addButton(withTitle: EditorLanguage.text("Cancel"))
        alert.addButton(withTitle: EditorLanguage.text("Quit NotesMate"))
        alert.window.level = .statusBar
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        for hotKey in hotKeys { UnregisterEventHotKey(hotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshNotesAutomationPermission()
    }

    private func refreshNotesAutomationPermission() {
        DispatchQueue.global(qos: .utility).async {
            NotesAutomationPermission.refreshIfNotesIsRunning()
        }
    }

    private func registerHotKeys() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr,
                  identifier.signature == AppDelegate.newNoteHotKeyID.signature else {
                return OSStatus(eventNotHandledErr)
            }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            switch identifier.id {
            case AppDelegate.newNoteHotKeyID.id:
                delegate.toggleNoteWindow()
            case AppDelegate.openNotesHotKeyID.id:
                DispatchQueue.main.async { [weak delegate] in delegate?.openNotes(nil) }
            default:
                return OSStatus(eventNotHandledErr)
            }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)

        var failures: [String] = []
        for (keyCode, identifier, label) in [
            (kVK_ANSI_N, Self.newNoteHotKeyID, EditorLanguage.text("New Note ⌃⌘N")),
            (kVK_ANSI_O, Self.openNotesHotKeyID, EditorLanguage.text("Open Notes ⌃⌘O")),
        ] {
            var hotKey: EventHotKeyRef?
            let status = handlerStatus == noErr
                ? RegisterEventHotKey(UInt32(keyCode), UInt32(controlKey | cmdKey), identifier,
                                      GetApplicationEventTarget(), 0, &hotKey)
                : handlerStatus
            if status == noErr, let hotKey {
                hotKeys.append(hotKey)
            } else {
                failures.append(EditorLanguage.format("{0} (error: {1})", label, String(status)))
            }
        }
        // 一个快捷键注册失败时，仍保留另一个可用的快捷键。
        if hotKeys.isEmpty, let hotKeyHandler {
            RemoveEventHandler(hotKeyHandler)
            self.hotKeyHandler = nil
        }
        guard !failures.isEmpty else { return }
        let message = failures.joined(separator: "\n")
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = EditorLanguage.text("Unable to Register Shortcuts")
            alert.informativeText = EditorLanguage.format("These shortcuts may be in use by another app:\n{0}\nYou can still use the menu bar icon’s context menu.", message)
            alert.addButton(withTitle: EditorLanguage.text("OK"))
            alert.runModal()
        }
    }

    private func toggleNoteWindow() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let button = self.statusItem.button else { return }
            self.panelController.toggle(relativeTo: button)
            self.recordManualFirstLaunchOpen()
        }
    }

    @objc private func newNote(_ sender: Any?) {
        // 等菜单关闭后再激活面板，避免菜单跟踪结束时夺走输入焦点。
        DispatchQueue.main.async { [weak self] in
            guard let self, let button = self.statusItem.button else { return }
            self.panelController.show(relativeTo: button)
            self.recordManualFirstLaunchOpen()
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            panelController.toggle(relativeTo: sender)
            recordManualFirstLaunchOpen()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()

        let newNoteItem = NSMenuItem(
            title: EditorLanguage.text("New Note"),
            action: #selector(newNote(_:)),
            keyEquivalent: "n"
        )
        newNoteItem.keyEquivalentModifierMask = [.control, .command]
        newNoteItem.target = self
        menu.addItem(newNoteItem)

        let openNotesItem = NSMenuItem(
            title: EditorLanguage.text("Open Notes"),
            action: #selector(openNotes(_:)),
            keyEquivalent: "o"
        )
        openNotesItem.keyEquivalentModifierMask = [.control, .command]
        openNotesItem.target = self
        menu.addItem(openNotesItem)
        if NotesAutomationPermission.shouldShowAuthorizationMenu {
            let permissionItem = NSMenuItem(
                title: EditorLanguage.text("Authorize Access to Notes"),
                action: #selector(authorizeNotes(_:)),
                keyEquivalent: ""
            )
            permissionItem.target = self
            menu.addItem(permissionItem)
        }
        menu.addItem(.separator())

        let launchItem = NSMenuItem(
            title: EditorLanguage.text("Launch at Login"),
            action: #selector(toggleLaunchAtLogin(_:)),
            keyEquivalent: ""
        )
        launchItem.target = self
        launchItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(launchItem)

        #if DEBUG
        menu.addItem(.separator())
        let languageItem = NSMenuItem(title: EditorLanguage.text("Language"), action: nil, keyEquivalent: "")
        let languageMenu = NSMenu()
        let systemItem = NSMenuItem(
            title: EditorLanguage.text("Follow System Language"),
            action: #selector(selectDebugLanguage(_:)),
            keyEquivalent: ""
        )
        systemItem.target = self
        systemItem.state = EditorLanguage.debugOverride == nil ? .on : .off
        languageMenu.addItem(systemItem)
        languageMenu.addItem(.separator())
        for (code, name) in Self.debugLanguageNames {
            let item = NSMenuItem(title: name, action: #selector(selectDebugLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = code
            item.state = EditorLanguage.debugOverride == code ? .on : .off
            languageMenu.addItem(item)
        }
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)
        menu.addItem(.separator())
        #endif

        let quitItem = NSMenuItem(
            title: EditorLanguage.text("Quit NotesMate"),
            action: #selector(quit(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    #if DEBUG
    private static let debugLanguageNames: [(String, String)] = [
        ("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"), ("en", "English"),
        ("ja", "日本語"), ("ko", "한국어"), ("de", "Deutsch"),
        ("fr", "Français"), ("es", "Español"), ("pt", "Português"),
        ("it", "Italiano"), ("fil", "Filipino"), ("id", "Bahasa Indonesia"),
        ("ms", "Bahasa Melayu"), ("th", "ไทย"), ("vi", "Tiếng Việt"),
    ]

    @objc private func selectDebugLanguage(_ sender: NSMenuItem) {
        let language = sender.representedObject as? String
        DispatchQueue.main.async { EditorLanguage.setDebugOverride(language) }
    }
    #endif

    @objc private func authorizeNotes(_ sender: Any?) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Notes") else {
            showOpenNotesError(EditorLanguage.text("Apple Notes could not be found."))
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] notes, error in
            if let error {
                DispatchQueue.main.async { self?.showOpenNotesError(error.localizedDescription) }
                return
            }
            guard let notes else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let status = NotesAutomationPermission.determine(for: notes, askUserIfNeeded: true)
                if status != noErr {
                    DispatchQueue.main.async {
                        NSWorkspace.shared.open(NotesAutomationPermission.settingsURL)
                    }
                }
            }
        }
    }

    @objc private func openNotes(_ sender: Any?) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Notes") else {
            showOpenNotesError(EditorLanguage.text("Apple Notes could not be found."))
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, error in
            guard let error else { return }
            DispatchQueue.main.async { self?.showOpenNotesError(error.localizedDescription) }
        }
    }

    private func showOpenNotesError(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = EditorLanguage.text("Unable to Open Notes")
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: EditorLanguage.text("OK"))
        alert.runModal()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = EditorLanguage.text("Unable to Update Launch at Login")
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: EditorLanguage.text("OK"))
            alert.runModal()
        }
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }
}
