import AppKit

/// 捕获成功的轻量提示：屏幕底部一个胶囊，淡入 → 停留 → 淡出。
///
/// 刻意做成**不抢焦点**（`.nonactivatingPanel` + 不激活 App），
/// 否则每次划词都把焦点从文章上抢走，就等于没解决"打断阅读"这个问题。
final class CaptureToast {

    static let shared = CaptureToast()

    private var panel: NSPanel?
    private var view: ToastView?
    private var dismissWork: DispatchWorkItem?

    private let width: CGFloat = 250
    private let height: CGFloat = 44

    func show(_ text: String, accent: NSColor = .systemGreen,
              onClick: (() -> Void)? = nil) {
        dismissWork?.cancel()

        let panel = self.panel ?? makePanel()
        self.panel = panel

        view?.text = text
        view?.accent = accent
        view?.onClick = { [weak self] in
            self?.hide()
            onClick?()
        }
        view?.needsDisplay = true

        position(panel)

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }

        let work = DispatchWorkItem { [weak self] in self?.hide() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.9, execute: work)
    }

    /// 自检 / 调试用
    var isShowing: Bool { panel?.isVisible ?? false }

    func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.32
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false
        )
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isReleasedWhenClosed = false
        p.ignoresMouseEvents = false

        let v = ToastView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        p.contentView = v
        view = v
        return p
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let v = screen.visibleFrame
        let x = v.midX - width / 2
        let y = v.minY + 76
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }
}

/// 胶囊本体
final class ToastView: NSView {

    var text: String = ""
    var accent: NSColor = .systemGreen
    var onClick: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1.5, dy: 1.5)
        let capsule = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)

        NSColor(calibratedWhite: 0.11, alpha: 0.93).setFill()
        capsule.fill()

        NSColor(calibratedWhite: 1.0, alpha: 0.10).setStroke()
        capsule.lineWidth = 1
        capsule.stroke()

        // 左侧状态点
        let dot = NSBezierPath(ovalIn: NSRect(x: 15, y: bounds.midY - 7, width: 14, height: 14))
        accent.setFill()
        dot.fill()

        // 白色对勾
        NSColor.white.setStroke()
        let check = NSBezierPath()
        check.lineWidth = 2
        check.lineCapStyle = .round
        check.move(to: NSPoint(x: 18.5, y: bounds.midY - 0.5))
        check.line(to: NSPoint(x: 21.5, y: bounds.midY - 3.5))
        check.line(to: NSPoint(x: 26, y: bounds.midY + 3.5))
        check.stroke()

        // 文案
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        let size = s.size()
        s.draw(at: NSPoint(x: 38, y: (bounds.height - size.height) / 2))
    }

    override func mouseUp(with event: NSEvent) { onClick?() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
