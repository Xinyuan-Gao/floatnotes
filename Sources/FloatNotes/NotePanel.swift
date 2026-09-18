import AppKit

/// 窗口层级阶梯。默认 `.floating`；若实测盖不住全屏应用，逐级往上调。
enum PanelLevel: String, CaseIterable {
    case floating, statusBar, screenSaver

    var level: NSWindow.Level {
        switch self {
        case .floating:    return .floating      // 3
        case .statusBar:   return .statusBar     // 25
        case .screenSaver: return .screenSaver   // 1000
        }
    }

    var next: PanelLevel {
        let all = PanelLevel.allCases
        let i = all.firstIndex(of: self)!
        return all[min(i + 1, all.count - 1)]
    }
}

/// 笔记窗口：永远置顶、跨 Space、可浮在别的 App 全屏之上、点击不激活本 App。
final class NotePanel: NSPanel {

    // 必须为 true，否则无法输入文字
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    let noteID: String

    init(noteID: String, frame: NSRect, level: PanelLevel = .floating) {
        self.noteID = noteID
        super.init(
            contentRect: frame,
            styleMask: [.nonactivatingPanel,        // ★ 点击不激活本 App（不打断阅读）
                        .titled,
                        .closable,
                        .resizable,
                        .fullSizeContentView,
                        .utilityWindow],
            backing: .buffered,
            defer: false
        )
        applyFloating(level: level)

        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        minSize = NSSize(width: 280, height: 180)
        animationBehavior = .utilityWindow
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    /// 置顶行为集中在这里，方便 M0 阶段逐项验证 / 调整
    func applyFloating(level: PanelLevel) {
        self.level = level.level
        collectionBehavior = [
            .canJoinAllSpaces,      // 所有桌面都出现
            .fullScreenAuxiliary,   // ★ 能浮在别的 App 的全屏 Space 之上
            .stationary             // 切 Space 时不跟着滑动
        ]
        isFloatingPanel = true
        hidesOnDeactivate = false   // ★ 切走 App 不消失
        becomesKeyOnlyIfNeeded = false
    }

    /// 折叠成一条细栏（像 Stickies 那样）
    private var expandedFrame: NSRect?
    private(set) var isCollapsed = false

    static let collapsedHeight: CGFloat = 30

    /// 设置收起状态（幂等，可重复调用）
    func setCollapsed(_ collapsed: Bool) {
        guard collapsed != isCollapsed else { return }
        isCollapsed = collapsed

        if collapsed {
            expandedFrame = frame
            minSize = NSSize(width: 160, height: Self.collapsedHeight)
            var f = frame
            f.origin.y += f.height - Self.collapsedHeight
            f.size.height = Self.collapsedHeight
            setFrame(f, display: true, animate: true)
        } else {
            minSize = NSSize(width: 280, height: 180)
            if let saved = expandedFrame {
                setFrame(saved, display: true, animate: true)
            } else {
                var f = frame
                f.size.height = max(180, f.height)
                setFrame(f, display: true, animate: true)
            }
            expandedFrame = nil
        }
    }

    func toggleCollapse() { setCollapsed(!isCollapsed) }

    /// 每笔记独立透明度（像 Stickies 的 Translucent）
    func applyAppearance(opacity: Double) {
        alphaValue = CGFloat(min(max(opacity, 0.35), 1.0))
    }

    /// 每笔记独立置顶开关：关掉后就是普通窗口，会被别的窗口遮挡
    private(set) var isPinnedOnTop = true

    func setPinnedOnTop(_ pinned: Bool) {
        isPinnedOnTop = pinned
        if pinned {
            applyFloating(level: Settings.shared.panelLevel)
        } else {
            level = .normal
            collectionBehavior = [.fullScreenAuxiliary]
            isFloatingPanel = false
        }
    }
}

/// 悬浮球：屏幕上那个"按钮"。无边框、置顶、可拖动、点击弹菜单。
final class FloatingBallPanel: NSPanel {
    override var canBecomeKey: Bool { false }   // 悬浮球不需要键盘
    override var canBecomeMain: Bool { false }

    init(origin: NSPoint) {
        let size = NSSize(width: 52, height: 52)
        super.init(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
    }
}

/// 悬浮球内容视图：拖动移动窗口（松手自动贴边），轻点弹菜单，双击直接新建笔记。
final class FloatingBallView: NSView {
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    private var dragOrigin: NSPoint = .zero
    private var didDrag = false

    override func draw(_ dirtyRect: NSRect) {
        let inset = bounds.insetBy(dx: 5, dy: 5)
        let path = NSBezierPath(ovalIn: inset)

        // 渐变圆
        let gradient = NSGradient(colors: [
            NSColor(calibratedRed: 0.36, green: 0.44, blue: 0.98, alpha: 0.96),
            NSColor(calibratedRed: 0.55, green: 0.33, blue: 0.94, alpha: 0.96)
        ])
        gradient?.draw(in: path, angle: -90)

        // 白色 "+"
        NSColor.white.setStroke()
        let plus = NSBezierPath()
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        let arm: CGFloat = 11
        plus.lineWidth = 2.6
        plus.lineCapStyle = .round
        plus.move(to: NSPoint(x: c.x - arm, y: c.y)); plus.line(to: NSPoint(x: c.x + arm, y: c.y))
        plus.move(to: NSPoint(x: c.x, y: c.y - arm)); plus.line(to: NSPoint(x: c.x, y: c.y + arm))
        plus.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        dragOrigin = event.locationInWindow
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window = window else { return }
        if abs(event.locationInWindow.x - dragOrigin.x) > 2
            || abs(event.locationInWindow.y - dragOrigin.y) > 2 {
            didDrag = true
        }
        let current = event.locationInWindow
        var origin = window.frame.origin
        origin.x += current.x - dragOrigin.x
        origin.y += current.y - dragOrigin.y
        window.setFrameOrigin(origin)
    }

    override func mouseUp(with event: NSEvent) {
        if didDrag {
            snapToEdge()
            return
        }
        if event.clickCount >= 2 {
            onDoubleClick?()
        } else {
            onClick?()
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        onClick?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    // MARK: - 贴边吸附

    /// 松手后吸附到设置里指定的那一侧，并记住纵向位置。
    private func snapToEdge() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let v = screen.visibleFrame
        let margin: CGFloat = 14
        var f = window.frame

        f.origin.x = Settings.shared.ballEdge == "left"
            ? v.minX + margin
            : v.maxX - f.width - margin

        // 纵向限制在屏幕内
        f.origin.y = min(max(f.origin.y, v.minY + margin), v.maxY - f.height - margin)

        window.setFrame(f, display: true, animate: true)
        UserDefaults.standard.set(NSStringFromRect(f), forKey: "ballFrame")
    }

    /// 按当前设置贴边（启动时 / 切换左右时调用）
    func applyEdge(animated: Bool) {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let v = screen.visibleFrame
        let margin: CGFloat = 14
        var f = window.frame
        f.origin.x = Settings.shared.ballEdge == "left"
            ? v.minX + margin
            : v.maxX - f.width - margin
        f.origin.y = min(max(f.origin.y, v.minY + margin), v.maxY - f.height - margin)
        window.setFrame(f, display: true, animate: animated)
        UserDefaults.standard.set(NSStringFromRect(f), forKey: "ballFrame")
    }
}
