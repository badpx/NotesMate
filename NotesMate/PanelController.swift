import AppKit
import SwiftUI

/// 边缘 resize 热区划分（窗口坐标，y 轴向上）。
/// 光标热区与拖拽命中共用同一套几何，保证「看到什么光标就能拖什么」。
private func edgeCursorRects(in bounds: NSRect) -> [(rect: NSRect, cursor: NSCursor)] {
    let edge: CGFloat = 6
    let corner: CGFloat = 18
    return [
        (NSRect(x: 0, y: 0, width: corner, height: corner), .neswDiagonalResize),
        (NSRect(x: bounds.width - corner, y: 0, width: corner, height: corner), .nwseDiagonalResize),
        (NSRect(x: corner, y: 0, width: bounds.width - corner * 2, height: edge), .resizeUpDown),
        (NSRect(x: 0, y: corner, width: edge, height: bounds.height - corner), .resizeLeftRight),
        (NSRect(x: bounds.width - edge, y: corner, width: edge, height: bounds.height - corner), .resizeLeftRight),
    ]
}

private func findTextView(in view: NSView) -> NSTextView? {
    if let textView = view as? NSTextView { return textView }
    for subview in view.subviews {
        if let found = findTextView(in: subview) { return found }
    }
    return nil
}

final class NotePanel: NSPanel {
    override var canBecomeKey: Bool { true }

    var resizeHandler: PanelResizeHandler?

    private weak var editorTextView: NSTextView?
    private var trackingEdges: PanelResizeHandler.Edges?
    private var trackingUpMonitor: Any?

    /// 命中检测：左/右/下边缘（6pt）与两个底角（18pt）。顶部保留给标题栏拖动，不参与。
    static func edges(at point: NSPoint, in bounds: NSRect) -> PanelResizeHandler.Edges? {
        let edge: CGFloat = 6
        let corner: CGFloat = 18
        if point.x < corner && point.y < corner { return [.left, .bottom] }
        if point.x >= bounds.width - corner && point.y < corner { return [.right, .bottom] }
        var edges: PanelResizeHandler.Edges = []
        if point.x < edge { edges.insert(.left) }
        if point.x >= bounds.width - edge { edges.insert(.right) }
        if point.y < edge { edges.insert(.bottom) }
        return edges.isEmpty ? nil : edges
    }

    private func editorClipView() -> NSView? {
        if editorTextView == nil, let contentView {
            editorTextView = findTextView(in: contentView)
        }
        return editorTextView?.enclosingScrollView?.contentView
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown where attachedSheet == nil:
            if let contentView, let edges = Self.edges(at: event.locationInWindow, in: contentView.bounds) {
                // 边缘 resize：AppKit 层追踪拖拽（SwiftUI 手势在浮窗变形/叠加层级下不可靠）。
                // 吞掉按下事件，编辑器不参与本次拖拽。
                trackingEdges = edges
                Self.cursor(for: edges).set()
                resizeHandler?.beginTracking(at: NSEvent.mouseLocation)
                trackingUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
                    self?.endTracking()
                    return nil
                }
                return
            }
            if let contentView {
                // Match the custom title bar; leave side resize handles and Pin/Close untouched.
                let dragRect = NSRect(x: 6, y: contentView.bounds.height - EditorAppearance.headerHeight,
                                      width: max(0, contentView.bounds.width - 90), height: EditorAppearance.headerHeight)
                if dragRect.contains(event.locationInWindow) {
                    performDrag(with: event)
                    return
                }
            }
        case .leftMouseDragged:
            if let trackingEdges {
                resizeHandler?.resize(edges: trackingEdges)
                return
            }
        case .leftMouseUp:
            if trackingEdges != nil {
                endTracking()
                return
            }
        default:
            break
        }
        super.sendEvent(event)
        // NSTextView 会在事件分发中把自己的 I-beam 盖过 cursorRect 的结果，
        // 因此在 mouseMoved/cursorUpdate 分发结束后统一按鼠标位置裁定光标：
        // 边缘热区用 resize 光标，文本区用 I-beam，其余用箭头。拖动中不动光标。
        guard event.type == .mouseMoved || event.type == .cursorUpdate,
              NSEvent.pressedMouseButtons == 0,
              let contentView else { return }
        let point = event.locationInWindow
        if let hit = edgeCursorRects(in: contentView.bounds).first(where: { $0.rect.contains(point) }) {
            hit.cursor.set()
            return
        }
        // 文本区判断用几何包含而非 hitTest：SwiftUI 布局更新期间 hitTest 结果不稳定。
        if let clipView = editorClipView(),
           clipView.bounds.contains(clipView.convert(point, from: nil)) {
            NSCursor.iBeam.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private func endTracking() {
        trackingEdges = nil
        if let trackingUpMonitor {
            NSEvent.removeMonitor(trackingUpMonitor)
            self.trackingUpMonitor = nil
        }
        resizeHandler?.endResize()
        NSCursor.arrow.set()
    }

    private static func cursor(for edges: PanelResizeHandler.Edges) -> NSCursor {
        if edges.contains([.left, .bottom]) { return .neswDiagonalResize }
        if edges.contains([.right, .bottom]) { return .nwseDiagonalResize }
        if edges.contains(.bottom) { return .resizeUpDown }
        return .resizeLeftRight
    }
}

/// 浮窗内容容器：负责边缘热区的 resize 光标。
/// SwiftUI 的 onContinuousHover + NSCursor.push 会被 AppKit 的 cursorUpdate 机制覆盖，
/// 因此光标用 NSView 的 cursorRect 实现（另由 NotePanel.sendEvent 兜底强制）。
private final class PanelContentView: NSView {
    override func resetCursorRects() {
        for entry in edgeCursorRects(in: bounds) {
            addCursorRect(entry.rect, cursor: entry.cursor)
        }
    }
}

private extension NSCursor {
    /// 右下角（↘↖）斜向调整尺寸光标：macOS 15+ 用系统原生，旧系统回退到自绘。
    static let nwseDiagonalResize: NSCursor = {
        if #available(macOS 15, *) {
            return NSCursor.frameResize(position: .bottomRight, directions: .all)
        }
        return NSCursor.diagonalResize(flip: false)
    }()

    /// 左下角（↙↗）斜向调整尺寸光标。
    static let neswDiagonalResize: NSCursor = {
        if #available(macOS 15, *) {
            return NSCursor.frameResize(position: .bottomLeft, directions: .all)
        }
        return NSCursor.diagonalResize(flip: true)
    }()

    /// macOS 13/14 没有公开的斜向 resize 光标（frameResize 系列要 macOS 15），自行绘制：
    /// 一条对角线加两端 L 形箭头，白描边保证深浅背景都可见。
    private static func diagonalResize(flip: Bool) -> NSCursor {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
                NSPoint(x: flip ? 16 - x : x, y: y)
            }
            // 坐标系 y 轴向上：NW 端在 (4, 12)，SE 端在 (12, 4)。
            let outline = NSBezierPath()
            let body = NSBezierPath()
            for path in [outline, body] {
                path.move(to: point(4, 12))
                path.line(to: point(12, 4))
                path.move(to: point(4, 8))
                path.line(to: point(4, 12))
                path.line(to: point(8, 12))
                path.move(to: point(12, 8))
                path.line(to: point(12, 4))
                path.line(to: point(8, 4))
            }
            outline.lineWidth = 3.5
            outline.lineCapStyle = .round
            outline.lineJoinStyle = .round
            NSColor.white.setStroke()
            outline.stroke()
            body.lineWidth = 1.5
            body.lineCapStyle = .round
            body.lineJoinStyle = .round
            NSColor.black.setStroke()
            body.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 8, y: 8))
    }
}

/// 浮窗边缘拖动手柄：由 NotePanel 的 AppKit 事件追踪驱动，调整浮窗尺寸并回调持久化。
/// 只支持左、右、下三个方向，顶部保留给标题栏拖动。
final class PanelResizeHandler {
    struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1 << 0)
        static let right = Edges(rawValue: 1 << 1)
        static let bottom = Edges(rawValue: 1 << 2)
    }

    /// 用户可手动调整的最小尺寸。
    static let minSize = NSSize(width: 360, height: 200)

    private weak var panel: NSPanel?
    private var startFrame: NSRect?
    private var startMouse: NSPoint?

    var onResizeEnd: ((NSSize) -> Void)?

    init(panel: NSPanel) {
        self.panel = panel
    }

    /// 按下边缘时调用：记录拖拽基准（frame 与屏幕坐标下的鼠标位置）。
    func beginTracking(at mouse: NSPoint) {
        startFrame = panel?.frame
        startMouse = mouse
    }

    /// 拖拽中调用。位移用屏幕坐标（面板随拖动实时变形，视图坐标系随之下移会产生正反馈）。
    func resize(edges: Edges, at mouse: NSPoint = NSEvent.mouseLocation) {
        guard let panel else { return }
        if startFrame == nil {
            startFrame = panel.frame
            startMouse = mouse
        }
        guard let startFrame, let startMouse else { return }
        let delta = CGSize(width: mouse.x - startMouse.x, height: mouse.y - startMouse.y)
        panel.setFrame(Self.frame(applying: delta, to: startFrame, edges: edges), display: true)
    }

    /// 纯几何：按边与位移计算目标 frame（可离线测试）。
    static func frame(
        applying delta: CGSize,
        to startFrame: NSRect,
        edges: Edges,
        minSize: NSSize = PanelResizeHandler.minSize
    ) -> NSRect {
        var frame = startFrame
        if edges.contains(.right) {
            frame.size.width = max(minSize.width, startFrame.width + delta.width)
        }
        if edges.contains(.left) {
            let width = max(minSize.width, startFrame.width - delta.width)
            frame.origin.x = startFrame.maxX - width
            frame.size.width = width
        }
        if edges.contains(.bottom) {
            // 屏幕坐标 y 轴向上：向下拖动时 delta.height 为负，高度增加。
            let height = max(minSize.height, startFrame.height - delta.height)
            frame.origin.y = startFrame.maxY - height
            frame.size.height = height
        }
        return frame
    }

    func endResize() {
        guard let panel, startFrame != nil else { return }
        startFrame = nil
        startMouse = nil
        onResizeEnd?(panel.frame.size)
    }
}

final class PanelController {
    func prepareToQuit() -> Bool { model.prepareToQuit() }
    var isSaving: Bool { model.isSaving }
    func prepareToQuit(completion: @escaping (Bool) -> Void) { model.prepareToQuit(completion: completion) }
    private let model = NoteEditorModel()
    private let panel: NotePanel
    private let resizeHandler: PanelResizeHandler
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    private var moveObserver: NSObjectProtocol?
    private weak var anchorButton: NSStatusBarButton?

    private static let panelSizeKey = "panelSize"
    private static let panelOriginKey = "panelOrigin"
    private static let defaultPanelSize = NSSize(width: 380, height: 410)

    /// 置顶时点击面板外部不自动收起。
    private(set) var isPinned = false
    var isVisible: Bool { panel.isVisible }

    init() {
        let storedSize = UserDefaults.standard.string(forKey: Self.panelSizeKey).map(NSSizeFromString)
        let size = storedSize.flatMap { size in
            size.width >= PanelResizeHandler.minSize.width && size.height >= PanelResizeHandler.minSize.height
                ? size : nil
        } ?? Self.defaultPanelSize
        let panel = NotePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.isMovable = true
        panel.animationBehavior = .utilityWindow
        panel.contentMinSize = PanelResizeHandler.minSize
        self.panel = panel

        let resizeHandler = PanelResizeHandler(panel: panel)
        panel.resizeHandler = resizeHandler
        resizeHandler.onResizeEnd = { [weak panel] size in
            UserDefaults.standard.set(NSStringFromSize(size), forKey: Self.panelSizeKey)
            if UserDefaults.standard.string(forKey: Self.panelOriginKey) != nil, let panel {
                UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: Self.panelOriginKey)
            }
        }
        self.resizeHandler = resizeHandler

        let contentView = NoteEditorView(
            isPinned: false,
            onClose: { [weak self] in self?.close() },
            onPinChanged: { [weak self] pinned in self?.isPinned = pinned },
            onSaved: { [weak self] in
                guard let self, self.panel.isKeyWindow else { return }
                self.focusEditor()
            },
            model: model
        )
        let hostingView = NSHostingView(rootView: contentView)
        let container = PanelContentView(frame: NSRect(origin: .zero, size: size))
        hostingView.frame = container.bounds
        hostingView.autoresizingMask = [.width, .height]
        container.addSubview(hostingView)
        panel.contentView = container
        // performDrag can return before the final window frame is applied. Persist actual move
        // notifications instead of assuming its return marks the end of the drag.
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak panel] _ in
            guard let panel, panel.isVisible else { return }
            UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: Self.panelOriginKey)
        }
    }

    deinit {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        stopEventMonitors()
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if panel.isVisible {
            close()
        } else {
            show(relativeTo: button)
        }
    }

    @discardableResult
    func show(relativeTo button: NSStatusBarButton, welcomeMessage: String? = nil) -> Bool {
        guard positionPanel(relativeTo: button) else { return false }
        model.tips.beginSession(initialMessage: welcomeMessage)
        anchorButton = button
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        focusEditor()
        startEventMonitors()
        return true
    }

    func close() {
        model.tips.endSession()
        // Also capture the final position before hiding, including a just-completed drag.
        if panel.isVisible {
            UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: Self.panelOriginKey)
        }
        stopEventMonitors()
        panel.orderOut(nil)
    }

    private func positionPanel(relativeTo button: NSStatusBarButton) -> Bool {
        guard let buttonWindow = button.window,
              button.bounds.width > 0, button.bounds.height > 0 else { return false }
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        guard buttonRect.minX.isFinite, buttonRect.minY.isFinite,
              buttonRect.width > 0, buttonRect.height > 0 else { return false }
        // 状态栏窗口的 .screen 在多屏下不可靠（可能与按钮实际所在屏不符），
        // 按菜单栏按钮所在屏幕选定目标屏；未完成布局的按钮可能暂时位于 (0, 0)。
        guard let buttonScreen = NSScreen.screens.first(where: { screen in
            buttonRect.midX >= screen.frame.minX && buttonRect.midX <= screen.frame.maxX &&
            buttonRect.midY >= screen.frame.maxY - 100 && buttonRect.midY <= screen.frame.maxY + 50
        }) else { return false }
        if let stored = UserDefaults.standard.string(forKey: Self.panelOriginKey) {
            let origin = NSPointFromString(stored)
            // Older builds could persist the panel's initial (0, 0) when the
            // first status item had no window. Treat only that value as unset.
            if origin.x.isFinite, origin.y.isFinite, origin != .zero {
                let savedFrame = NSRect(origin: origin, size: panel.frame.size)
                let screen = NSScreen.screens.filter { $0.visibleFrame.intersects(savedFrame) }.max {
                    let a = $0.visibleFrame.intersection(savedFrame)
                    let b = $1.visibleFrame.intersection(savedFrame)
                    return a.width * a.height < b.width * b.height
                } ?? buttonScreen
                // Keep the title bar reachable after a monitor is unplugged or its resolution changes.
                let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
                let size = NSSize(width: min(panel.frame.width, visible.width),
                                  height: min(panel.frame.height, visible.height))
                let adjusted = NSPoint(x: min(max(origin.x, visible.minX), visible.maxX - size.width),
                                       y: min(max(origin.y, visible.minY), visible.maxY - size.height))
                panel.setFrame(NSRect(origin: adjusted, size: size), display: false)
                return true
            }
        }
        // 面板必须完整落在屏幕可见区域内（四角热区可达）：先按可见区域夹取尺寸，再夹取位置。
        let visible = buttonScreen.visibleFrame.insetBy(dx: 8, dy: 8)
        let size = NSSize(width: min(panel.frame.width, visible.width),
                          height: min(panel.frame.height, visible.height))
        let origin = NSPoint(
            x: min(max(buttonRect.midX - size.width / 2, visible.minX), visible.maxX - size.width),
            y: min(max(buttonRect.minY - size.height - 6, visible.minY), visible.maxY - size.height)
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        return true
    }

    private func focusEditor() {
        guard let contentView = panel.contentView,
              let textView = findTextView(in: contentView) else { return }
        guard panel.makeFirstResponder(textView) else { return }
        // Refresh after the key/first-responder transition and panel ordering have settled.
        DispatchQueue.main.async { [weak self, weak textView] in
            guard let self, let textView = textView as? EditorTextView,
                  self.panel.isVisible, self.panel.isKeyWindow,
                  self.panel.firstResponder === textView else { return }
            textView.redrawVisibleSelectionAfterFocus()
            self.panel.displayIfNeeded()
        }
    }

    // MARK: - 点击外部收起

    private func startEventMonitors() {
        stopEventMonitors()

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self, !self.isPinned, self.panel.attachedSheet == nil else { return }
            if self.isEventOnAnchorButton(at: NSEvent.mouseLocation) { return }
            self.close()
        }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, !self.isPinned, self.panel.attachedSheet == nil else { return event }
            if event.window == self.panel { return event }
            if event.window != nil, event.window == self.anchorButton?.window { return event }
            self.close()
            return event
        }
    }

    private func stopEventMonitors() {
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
    }

    private func isEventOnAnchorButton(at screenPoint: NSPoint) -> Bool {
        guard let button = anchorButton, let window = button.window else { return false }
        return window.frame.contains(screenPoint)
    }
}
