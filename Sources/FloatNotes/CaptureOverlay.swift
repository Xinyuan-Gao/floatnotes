import AppKit

/// 全屏框选遮罩 —— 微信截图那种交互：
///
///   1. 拖出一块区域
///   2. 松手后选区**还在**，可以整体拖动位置、可以拉八个把手改大小
///   3. 旁边有小工具栏（✗ 取消 / ✓ 确认），也可以 ↵ 或双击确认、esc 取消
///   4. **确认之后才真正截图**
///
/// 刻意不做成「先截图再选」：遮罩是我们自己的窗口，
/// 确认后先把它关掉、等一帧再截，图里就不会混进遮罩本身。
final class CaptureOverlay {

    static let shared = CaptureOverlay()

    private var window: NSWindow?
    private var view: CaptureOverlayView?
    private var onFinish: ((NSRect?) -> Void)?

    var isActive: Bool { window?.isVisible ?? false }

    /// 自检用：当前有没有有效选区
    var hasSelection: Bool { view?.hasSelection ?? false }

    /// 开始框选。回调里的 rect 是 Cocoa 全局坐标（左下原点）；
    /// 传 nil 表示用户取消了。
    func begin(onFinish: @escaping (NSRect?) -> Void) {
        guard !isActive else { return }
        self.onFinish = onFinish

        // 一张窗口盖住所有屏幕的并集，省得每块屏各开一个
        let union = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
        // ★ 用 nonactivatingPanel 且**不激活本 App**。
        //   之前调了 NSApp.activate，对 regular 策略的 App 来说这会触发
        //   macOS 切到它「所属」的 Space —— 于是用户在全屏 Space 里按截图，
        //   人却被带到了另一个桌面，截到的也是那个桌面。
        //   nonactivating 面板既能拿到键盘（esc / ↵ / 方向键），又不会激活 App。
        let panel = CaptureOverlayWindow(
            contentRect: union,
            styleMask: [.borderless, .nonactivatingPanel],
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
        v.refreshTrackingAreas()

        // 「不激活 App」是刻意为之，这里确认一下面板确实拿到了 key，
        // 否则键盘操作（esc 取消等）会失灵。
        NSLog("[CaptureOverlay] 面板 isKeyWindow=\(panel.isKeyWindow) 本App活跃=\(NSApp.isActive)")
    }

    private func finish(_ localRect: NSRect?) {
        guard let panel = window, view != nil else { return }

        var cocoaRect: NSRect?
        if let r = localRect, r.width >= 2, r.height >= 2 {
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

    /// 自检用：直接摆一个选区
    func simulateSelection(_ rect: NSRect) { view?.simulateSelection(rect) }

    /// 自检用：按坐标模拟一次鼠标动作
    func simulateMouse(_ type: NSEvent.EventType, at point: NSPoint, clickCount: Int = 1) {
        view?.simulateMouse(type, at: point, clickCount: clickCount)
    }

    /// 自检用：当前选区
    var currentSelection: NSRect? { view?.currentSelection }

    /// 自检用：模拟确认
    func simulateConfirm() { view?.confirmCurrentSelection() }
}

/// 遮罩窗口。
///
/// 配了 `.nonactivatingPanel`，所以它能成为 key window 拿到键盘，
/// 但**不会**让本 App 变成前台活跃应用 —— 这样才不会把用户所在的
/// Space 切走（在别的桌面全屏时按截图，人应该留在原地）。
final class CaptureOverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - 八个把手

enum CaptureHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    /// 把手在选区里的相对位置（0…1）
    var unit: CGPoint {
        switch self {
        case .topLeft:     return CGPoint(x: 0, y: 1)
        case .top:         return CGPoint(x: 0.5, y: 1)
        case .topRight:    return CGPoint(x: 1, y: 1)
        case .right:       return CGPoint(x: 1, y: 0.5)
        case .bottomRight: return CGPoint(x: 1, y: 0)
        case .bottom:      return CGPoint(x: 0.5, y: 0)
        case .bottomLeft:  return CGPoint(x: 0, y: 0)
        case .left:        return CGPoint(x: 0, y: 0.5)
        }
    }

    var cursor: NSCursor {
        switch self {
        case .top, .bottom:   return .resizeUpDown
        case .left, .right:   return .resizeLeftRight
        default:              return .crosshair
        }
    }

    var movesLeft: Bool   { self == .topLeft || self == .left || self == .bottomLeft }
    var movesRight: Bool  { self == .topRight || self == .right || self == .bottomRight }
    var movesTop: Bool    { self == .topLeft || self == .top || self == .topRight }
    var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
}

// MARK: - 选区视图

final class CaptureOverlayView: NSView {

    var onFinish: ((NSRect?) -> Void)?

    private(set) var selection: NSRect?

    private enum Mode {
        case idle
        case creating(anchor: NSPoint)
        case moving(grabOffset: NSPoint, original: NSRect)
        case resizing(handle: CaptureHandle, original: NSRect)
    }
    private var mode: Mode = .idle

    private enum ToolbarButton: CaseIterable {
        case cancel, confirm
        var diameter: CGFloat { 28 }
        var symbol: String { self == .cancel ? "✕" : "✓" }
        var tint: NSColor {
            self == .cancel
                ? NSColor(calibratedWhite: 0.34, alpha: 1)
                : NSColor(calibratedRed: 0.20, green: 0.62, blue: 0.36, alpha: 1)
        }
    }

    private var trackingArea: NSTrackingArea?
    private var hoveredHandle: CaptureHandle?
    private var hoveredButton: ToolbarButton?

    private let handleSize: CGFloat = 7
    private let handleSlop: CGFloat = 7
    private let minSide: CGFloat = 8

    var hasSelection: Bool {
        guard let s = selection else { return false }
        return s.width >= minSide && s.height >= minSide
    }

    /// 自检用
    var currentSelection: NSRect? { selection }

    override var acceptsFirstResponder: Bool { true }

    // MARK: 工具栏

    private func toolbarRects(for sel: NSRect) -> [(ToolbarButton, NSRect)] {
        let d = ToolbarButton.confirm.diameter
        let gap: CGFloat = 8
        let totalW = d * 2 + gap

        var x = sel.maxX - totalW
        var y = sel.minY - d - 12
        if y < bounds.minY + 6 { y = sel.maxY + 12 }             // 下面放不下就放上面
        if y + d > bounds.maxY - 6 { y = sel.minY + 12 }
        x = max(bounds.minX + 6, min(x, bounds.maxX - totalW - 6))

        // 取消在左、确认在右 —— 和微信一致，顺手
        return [
            (.cancel,  NSRect(x: x, y: y, width: d, height: d)),
            (.confirm, NSRect(x: x + d + gap, y: y, width: d, height: d)),
        ]
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.setFillColor(NSColor(calibratedWhite: 0, alpha: 0.38).cgColor)
        ctx.fill(bounds)

        guard let sel = selection, sel.width > 0.5, sel.height > 0.5 else {
            drawHint()
            return
        }

        // 挖空选中区域 —— 用户看到的就是真实屏幕内容
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.fill(sel)
        ctx.restoreGState()

        // 边框
        NSColor(calibratedRed: 0.20, green: 0.62, blue: 0.98, alpha: 1).setStroke()
        let border = NSBezierPath(rect: sel.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1.5
        border.stroke()

        drawHandles(for: sel)
        drawSizeBadge(for: sel)
        drawToolbar(for: sel)
    }

    private func drawHint() {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let s = NSAttributedString(string: "拖动选择区域   ·   esc 取消", attributes: attrs)
        let size = s.size()
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let sc = screen else { return }
        let c = NSPoint(x: sc.frame.midX - frame.origin.x,
                        y: sc.frame.midY - frame.origin.y)

        let pad: CGFloat = 16
        let box = NSRect(x: c.x - size.width / 2 - pad, y: c.y - size.height / 2 - pad,
                         width: size.width + pad * 2, height: size.height + pad * 2)
        NSColor(calibratedWhite: 0, alpha: 0.6).setFill()
        NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).fill()
        s.draw(at: NSPoint(x: box.minX + pad, y: box.minY + pad))
    }

    private func drawHandles(for sel: NSRect) {
        for h in CaptureHandle.allCases {
            let p = NSPoint(x: sel.minX + sel.width * h.unit.x,
                            y: sel.minY + sel.height * h.unit.y)
            let r = NSRect(x: p.x - handleSize / 2, y: p.y - handleSize / 2,
                           width: handleSize, height: handleSize)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
            (hoveredHandle == h
                ? NSColor(calibratedRed: 0.20, green: 0.62, blue: 0.98, alpha: 1)
                : NSColor(calibratedWhite: 0.35, alpha: 1)).setStroke()
            let path = NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2)
            path.lineWidth = 1
            path.stroke()
        }
    }

    private func drawSizeBadge(for sel: NSRect) {
        let scale = window?.backingScaleFactor ?? 2
        let w = Int(sel.width.rounded()), h = Int(sel.height.rounded())
        let pxW = Int((sel.width * scale).rounded()), pxH = Int((sel.height * scale).rounded())
        let text = scale > 1.01 ? "\(w) × \(h) pt  ·  \(pxW) × \(pxH) px" : "\(w) × \(h)"

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        let size = s.size()
        let padX: CGFloat = 9, padY: CGFloat = 5

        var box = NSRect(x: sel.minX, y: sel.maxY + 8,
                         width: size.width + padX * 2, height: size.height + padY * 2)
        if box.maxY > bounds.maxY - 4 { box.origin.y = sel.minY - box.height - 8 }
        box.origin.x = max(bounds.minX + 6, min(box.origin.x, bounds.maxX - box.width - 6))

        NSColor(calibratedWhite: 0, alpha: 0.72).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        s.draw(at: NSPoint(x: box.minX + padX, y: box.minY + padY))
    }

    private func drawToolbar(for sel: NSRect) {
        for (button, rect) in toolbarRects(for: sel) {
            let isHot = (hoveredButton == button)
            let grow: CGFloat = isHot ? 1.5 : 0
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: -grow, dy: -grow))
            (isHot ? (button.tint.blended(withFraction: 0.15, of: .white) ?? button.tint)
                   : button.tint).setFill()
            circle.fill()

            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
            let s = NSAttributedString(string: button.symbol, attributes: attrs)
            let size = s.size()
            s.draw(at: NSPoint(x: rect.midX - size.width / 2,
                               y: rect.midY - size.height / 2))
        }
    }

    // MARK: 命中测试

    private func handleHit(at p: NSPoint, in sel: NSRect) -> CaptureHandle? {
        for h in CaptureHandle.allCases {
            let c = NSPoint(x: sel.minX + sel.width * h.unit.x,
                            y: sel.minY + sel.height * h.unit.y)
            let r = NSRect(x: c.x - handleSize / 2 - handleSlop,
                           y: c.y - handleSize / 2 - handleSlop,
                           width: handleSize + handleSlop * 2,
                           height: handleSize + handleSlop * 2)
            if r.contains(p) { return h }
        }
        return nil
    }

    private func buttonHit(at p: NSPoint) -> ToolbarButton? {
        guard let sel = selection else { return nil }
        for (button, rect) in toolbarRects(for: sel)
        where rect.insetBy(dx: -4, dy: -4).contains(p) {
            return button
        }
        return nil
    }

    // MARK: 鼠标

    override func mouseDown(with event: NSEvent) {
        route(.leftMouseDown, at: convert(event.locationInWindow, from: nil),
              clickCount: event.clickCount)
    }

    override func mouseDragged(with event: NSEvent) {
        route(.leftMouseDragged, at: clamp(convert(event.locationInWindow, from: nil)),
              clickCount: 1)
    }

    override func mouseUp(with event: NSEvent) {
        route(.leftMouseUp, at: convert(event.locationInWindow, from: nil),
              clickCount: event.clickCount)
    }

    /// 鼠标处理抽出来，好让自检直接喂坐标进来
    func route(_ type: NSEvent.EventType, at p: NSPoint, clickCount: Int) {
        switch type {
        case .leftMouseDown:    handleDown(p, clickCount: clickCount)
        case .leftMouseDragged: handleDrag(p)
        case .leftMouseUp:      handleUp(p)
        default: break
        }
    }

    private func handleDown(_ p: NSPoint, clickCount: Int) {
        // 1) 工具栏按钮
        if let b = buttonHit(at: p) {
            hoveredButton = b
            needsDisplay = true
            return
        }

        // 2) 已有选区：先看把手，再看是不是拖整体
        if let sel = selection {
            if let h = handleHit(at: p, in: sel) {
                mode = .resizing(handle: h, original: sel)
                return
            }
            if sel.contains(p) {
                if clickCount >= 2 {                 // 双击 = 确认（微信也是这样）
                    if hasSelection { onFinish?(sel) }
                    return
                }
                mode = .moving(grabOffset: NSPoint(x: p.x - sel.minX, y: p.y - sel.minY),
                               original: sel)
                return
            }
        }

        // 3) 其余地方重新拉一块
        selection = NSRect(origin: p, size: .zero)
        mode = .creating(anchor: p)
        needsDisplay = true
    }

    private func handleDrag(_ p: NSPoint) {
        switch mode {
        case .creating(let anchor):
            selection = normalized(anchor, p)

        case .moving(let grab, let original):
            var o = NSPoint(x: p.x - grab.x, y: p.y - grab.y)
            // 拖出屏幕就贴边，别让选区跑丢
            o.x = max(bounds.minX, min(o.x, bounds.maxX - original.width))
            o.y = max(bounds.minY, min(o.y, bounds.maxY - original.height))
            selection = NSRect(origin: o, size: original.size)

        case .resizing(let handle, let original):
            selection = resized(original, handle: handle, to: p)

        case .idle:
            break
        }
        needsDisplay = true
    }

    private func handleUp(_ p: NSPoint) {
        // 工具栏的点击在 mouseUp 才触发，避免误触
        if let b = hoveredButton, let sel = selection {
            let stillOnButton = toolbarRects(for: sel).contains {
                $0.0 == b && $0.1.insetBy(dx: -4, dy: -4).contains(p)
            }
            if stillOnButton {
                hoveredButton = nil
                switch b {
                case .confirm: onFinish?(sel)
                case .cancel:  onFinish?(nil)
                }
                return
            }
        }

        if case .creating = mode {
            // 太小当成误触，清掉重来
            if let s = selection, s.width < minSide || s.height < minSide {
                selection = nil
            }
        }
        mode = .idle
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        hoveredHandle = nil
        hoveredButton = nil
        needsDisplay = true
    }

    func updateHover(at p: NSPoint) {
        let newButton = buttonHit(at: p)
        let newHandle: CaptureHandle? = (newButton == nil && selection != nil)
            ? handleHit(at: p, in: selection!) : nil

        if newButton != hoveredButton || newHandle != hoveredHandle {
            hoveredButton = newButton
            hoveredHandle = newHandle
            needsDisplay = true
        }

        if newButton != nil { NSCursor.pointingHand.set(); return }
        if let h = newHandle { h.cursor.set(); return }
        if let sel = selection, sel.contains(p) { NSCursor.openHand.set(); return }
        NSCursor.crosshair.set()
    }

    // MARK: 键盘

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:                                     // esc
            onFinish?(nil)
        case 36, 76:                                 // return / enter
            if let s = selection, s.width >= minSide, s.height >= minSide {
                onFinish?(s)
            }
        case 123, 124, 125, 126:                     // 方向键
            nudge(keyCode: event.keyCode,
                  fine: event.modifierFlags.contains(.shift))
        default:
            super.keyDown(with: event)
        }
    }

    /// 方向键移动选区；按住 shift 是 1pt 微调，否则 10pt
    private func nudge(keyCode: UInt16, fine: Bool) {
        guard var s = selection else { return }
        let step: CGFloat = fine ? 1 : 10
        switch keyCode {
        case 123: s.origin.x -= step
        case 124: s.origin.x += step
        case 125: s.origin.y -= step
        case 126: s.origin.y += step
        default: return
        }
        s.origin.x = max(bounds.minX, min(s.origin.x, bounds.maxX - s.width))
        s.origin.y = max(bounds.minY, min(s.origin.y, bounds.maxY - s.height))
        selection = s
        needsDisplay = true
    }

    override func cancelOperation(_ sender: Any?) { onFinish?(nil) }

    // MARK: 几何

    private func clamp(_ p: NSPoint) -> NSPoint {
        NSPoint(x: max(bounds.minX, min(p.x, bounds.maxX)),
                y: max(bounds.minY, min(p.y, bounds.maxY)))
    }

    private func normalized(_ a: NSPoint, _ b: NSPoint) -> NSRect {
        NSRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    private func resized(_ original: NSRect, handle: CaptureHandle, to p: NSPoint) -> NSRect {
        var minX = original.minX, maxX = original.maxX
        var minY = original.minY, maxY = original.maxY

        if handle.movesLeft   { minX = min(p.x, maxX - minSide) }
        if handle.movesRight  { maxX = max(p.x, minX + minSide) }
        if handle.movesBottom { minY = min(p.y, maxY - minSide) }
        if handle.movesTop    { maxY = max(p.y, minY + minSide) }

        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: 自检支持

    func simulateSelection(_ rect: NSRect) {
        selection = rect
        mode = .idle
        needsDisplay = true
    }

    func simulateMouse(_ type: NSEvent.EventType, at point: NSPoint, clickCount: Int = 1) {
        route(type, at: point, clickCount: clickCount)
    }

    func confirmCurrentSelection() {
        guard let s = selection, s.width >= minSide, s.height >= minSide else { return }
        onFinish?(s)
    }

    // MARK: 光标与跟踪

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    func refreshTrackingAreas() {
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate],
            owner: self, userInfo: nil
        )
        addTrackingArea(t)
        trackingArea = t
        updateTrackingAreas()
    }

    override func cursorUpdate(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }
}
