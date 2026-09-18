import AppKit

/// 全屏框选遮罩。快捷键唤起后盖住所有屏幕，拖拽选一块区域。
///
/// 刻意不做成「先截图再选」：遮罩是我们自己的窗口，
/// 选完先把它关掉、等一帧再截，截图里就不会混进遮罩本身。
final class CaptureOverlay {

    static let shared = CaptureOverlay()

    private var window: NSWindow?
    private var view: CaptureOverlayView?
    private var onFinish: ((NSRect?) -> Void)?

    var isActive: Bool { window?.isVisible ?? false }

    /// 开始框选。回调里的 rect 是 Cocoa 全局坐标（左下原点）；
    /// 传 nil 表示用户取消了。
    func begin(onFinish: @escaping (NSRect?) -> Void) {
        guard !isActive else { return }
        self.onFinish = onFinish

        // 一张窗口盖住所有屏幕的并集，省得每块屏各开一个
        let union = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
        let panel = CaptureOverlayWindow(
            contentRect: union,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver              // 盖住菜单栏和 Dock
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true

        let v = CaptureOverlayView(frame: NSRect(origin: .zero, size: union.size))
        v.onFinish = { [weak self] rect in self?.finish(rect) }
        panel.contentView = v

        window = panel
        view = v

        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(v)
        NSApp.activate(ignoringOtherApps: true)
        v.updateTrackingAreas()
    }

    private func finish(_ localRect: NSRect?) {
        guard let panel = window, view != nil else { return }

        var cocoaRect: NSRect?
        if let r = localRect, r.width >= 2, r.height >= 2 {
            // 视图坐标 → Cocoa 全局坐标
            cocoaRect = NSRect(x: panel.frame.origin.x + r.origin.x,
                               y: panel.frame.origin.y + r.origin.y,
                               width: r.width, height: r.height)
        }

        panel.orderOut(nil)
        window = nil
        view = nil

        let cb = onFinish
        onFinish = nil
        cb?(cocoaRect)
    }

    /// 外部强制取消（比如权限中途失效）
    func cancel() { finish(nil) }
}

/// 遮罩窗口：需要能成为 key 才能收到 esc
final class CaptureOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - 绘制与交互

final class CaptureOverlayView: NSView {

    var onFinish: ((NSRect?) -> Void)?

    private var anchor: NSPoint?
    private var cursor: NSPoint?
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    private var selection: NSRect? {
        guard let a = anchor, let c = cursor else { return nil }
        return NSRect(x: min(a.x, c.x), y: min(a.y, c.y),
                      width: abs(c.x - a.x), height: abs(c.y - a.y))
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 整片压暗
        ctx.setFillColor(NSColor(calibratedWhite: 0, alpha: 0.38).cgColor)
        ctx.fill(bounds)

        guard let sel = selection, sel.width > 1, sel.height > 1 else {
            drawHint()
            return
        }

        // 选中的那块钱挖空 —— 清成完全透明，用户看到的就是真实屏幕内容
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.fill(sel)
        ctx.restoreGState()

        // 边框
        ctx.saveGState()
        NSColor(calibratedRed: 0.36, green: 0.44, blue: 0.98, alpha: 1).setStroke()
        let border = NSBezierPath(rect: sel.insetBy(dx: -0.75, dy: -0.75))
        border.lineWidth = 1.5
        border.stroke()
        ctx.restoreGState()

        drawSizeBadge(for: sel)
    }

    private func drawHint() {
        let text = "拖动选择要固定的区域   ·   esc 取消"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        let size = s.size()

        // 画在主屏（鼠标所在屏）中间偏上
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let sc = screen else { return }
        let centerInView = NSPoint(x: sc.frame.midX - frame.origin.x,
                                   y: sc.frame.midY - frame.origin.y)

        let pad: CGFloat = 16
        let box = NSRect(x: centerInView.x - size.width / 2 - pad,
                         y: centerInView.y - size.height / 2 - pad,
                         width: size.width + pad * 2,
                         height: size.height + pad * 2)
        NSColor(calibratedWhite: 0, alpha: 0.6).setFill()
        NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).fill()
        s.draw(at: NSPoint(x: box.minX + pad, y: box.minY + pad))
    }

    private func drawSizeBadge(for sel: NSRect) {
        // 尺寸按屏幕点算，和系统截图的习惯一致
        let scale = window?.backingScaleFactor ?? 2
        let ptW = Int((sel.width).rounded())
        let ptH = Int((sel.height).rounded())
        let text = "\(ptW) × \(ptH)"

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        let size = s.size()
        let pad: CGFloat = 8

        var box = NSRect(x: sel.midX - size.width / 2 - pad,
                         y: sel.minY - size.height - pad * 2 - 8,
                         width: size.width + pad * 2,
                         height: size.height + pad * 2)
        // 贴着屏幕下沿时改画到选区里面
        if box.minY < bounds.minY + 4 { box.origin.y = sel.minY + 8 }

        NSColor(calibratedWhite: 0, alpha: 0.72).setFill()
        NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7).fill()
        s.draw(at: NSPoint(x: box.minX + pad, y: box.minY + pad))

        _ = scale
    }

    // MARK: 鼠标

    override func mouseDown(with event: NSEvent) {
        anchor = convert(event.locationInWindow, from: nil)
        cursor = anchor
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        cursor = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        cursor = convert(event.locationInWindow, from: nil)
        let sel = selection
        // 太小当成误触，不算选择
        if let s = sel, s.width >= 4, s.height >= 4 {
            onFinish?(s)
        } else {
            anchor = nil; cursor = nil
            needsDisplay = true
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {            // esc
            onFinish?(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onFinish?(nil)
    }

    // MARK: 光标

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func updateTrackingAreas() {
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.activeAlways, .mouseMoved, .cursorUpdate],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
        super.updateTrackingAreas()
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }
}
