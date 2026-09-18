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

    static let ballSize: CGFloat = 52

    init(origin: NSPoint) {
        super.init(
            contentRect: NSRect(origin: origin,
                                size: NSSize(width: Self.ballSize, height: Self.ballSize)),
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
        // ★ 必须关掉：AppKit 自带的「拖背景移动窗口」会和下面手写的拖动同时生效，
        //   两个机制一起移动窗口，手感就是抖的、跟不上的。
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
    }
}

/// 悬浮球内容视图。
///
/// 拖动全程由这里接管，用**全局鼠标坐标做绝对定位**而不是逐帧累加增量 ——
/// 增量算法是自引用的（窗口一移动，光标在窗口内的坐标就跟着变），会产生滞后和抖动。
final class FloatingBallView: NSView {

    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    /// 可注入，便于自检时模拟鼠标轨迹
    var mouseLocationProvider: () -> NSPoint = { NSEvent.mouseLocation }

    private var dragStartMouse: NSPoint = .zero
    private var dragStartOrigin: NSPoint = .zero
    private var didDrag = false
    private(set) var isDragging = false

    /// 靠近屏幕左右边缘多少距离内才磁吸
    static let snapThreshold: CGFloat = 56
    /// 吸附后离边缘留多少
    static let snapMargin: CGFloat = 12

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        // 拖动时略微放大，给出「抓住了」的反馈
        let inset: CGFloat = isDragging ? 2.5 : 5
        let path = NSBezierPath(ovalIn: bounds.insetBy(dx: inset, dy: inset))

        let baseAlpha: CGFloat = isDragging ? 1.0 : 0.96
        let gradient = NSGradient(colors: [
            NSColor(calibratedRed: 0.36, green: 0.44, blue: 0.98, alpha: baseAlpha),
            NSColor(calibratedRed: 0.55, green: 0.33, blue: 0.94, alpha: baseAlpha)
        ])
        gradient?.draw(in: path, angle: -90)

        NSColor.white.setStroke()
        let plus = NSBezierPath()
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        let arm: CGFloat = isDragging ? 12 : 11
        plus.lineWidth = isDragging ? 2.9 : 2.6
        plus.lineCapStyle = .round
        plus.move(to: NSPoint(x: c.x - arm, y: c.y)); plus.line(to: NSPoint(x: c.x + arm, y: c.y))
        plus.move(to: NSPoint(x: c.x, y: c.y - arm)); plus.line(to: NSPoint(x: c.x, y: c.y + arm))
        plus.stroke()
    }

    // MARK: 拖动

    /// 明确告诉 AppKit：这个视图不该触发「拖背景移动窗口」
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        dragStartMouse = mouseLocationProvider()
        dragStartOrigin = window?.frame.origin ?? .zero
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }

        let now = mouseLocationProvider()
        let dx = now.x - dragStartMouse.x
        let dy = now.y - dragStartMouse.y

        if !didDrag, abs(dx) > 2 || abs(dy) > 2 {
            didDrag = true
            isDragging = true
            needsDisplay = true
        }
        guard didDrag else { return }

        // 绝对定位：起点 + 总位移。窗口怎么动都不会影响这个计算。
        window.setFrameOrigin(NSPoint(x: dragStartOrigin.x + dx,
                                      y: dragStartOrigin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        if isDragging {
            isDragging = false
            needsDisplay = true
        }

        if didDrag {
            finishDrag(animated: true)
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

    // MARK: 落点处理

    /// 松手后：先保证不跑出屏幕，然后**只在靠近左右边缘时**才磁吸。
    /// 停在屏幕中间就原地保留 —— 之前是无条件拉回边缘，所以横向根本摆不了。
    @discardableResult
    func finishDrag(animated: Bool) -> NSRect? {
        guard let window, let screen = window.screen ?? NSScreen.main else { return nil }
        let v = screen.visibleFrame
        var f = window.frame

        // 1) 不跑出屏幕
        let pad: CGFloat = 4
        f.origin.x = min(max(f.origin.x, v.minX + pad), v.maxX - f.width - pad)
        f.origin.y = min(max(f.origin.y, v.minY + pad), v.maxY - f.height - pad)

        // 2) 磁吸
        let distLeft = f.minX - v.minX
        let distRight = v.maxX - f.maxX
        if distLeft < Self.snapThreshold {
            f.origin.x = v.minX + Self.snapMargin
        } else if distRight < Self.snapThreshold {
            f.origin.x = v.maxX - f.width - Self.snapMargin
        }

        window.setFrame(f, display: true, animate: animated)
        UserDefaults.standard.set(NSStringFromRect(f), forKey: "ballFrame")
        return f
    }

    /// 把球移到设置里指定的那一侧（设置里点「移回边缘」时用）
    func applyEdge(animated: Bool) {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let v = screen.visibleFrame
        var f = window.frame
        f.origin.x = Settings.shared.ballEdge == "left"
            ? v.minX + Self.snapMargin
            : v.maxX - f.width - Self.snapMargin
        f.origin.y = min(max(f.origin.y, v.minY + Self.snapMargin),
                         v.maxY - f.height - Self.snapMargin)
        window.setFrame(f, display: true, animate: animated)
        UserDefaults.standard.set(NSStringFromRect(f), forKey: "ballFrame")
    }

    /// 首次启动（没有存过位置）时放到默认那一侧
    func placeAtDefaultEdge() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let v = screen.visibleFrame
        var f = window.frame
        f.origin.x = Settings.shared.ballEdge == "left"
            ? v.minX + Self.snapMargin
            : v.maxX - f.width - Self.snapMargin
        if f.origin.y < v.minY || f.origin.y > v.maxY - f.height {
            f.origin.y = v.midY - f.height / 2
        }
        window.setFrame(f, display: false)
        UserDefaults.standard.set(NSStringFromRect(f), forKey: "ballFrame")
    }
}
