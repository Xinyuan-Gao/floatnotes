import AppKit

// MARK: - 固定图片窗口

/// 被「钉」在屏幕上的截图。和笔记窗口一样永远置顶、跟到所有 Space，
/// 也可以拖到任意位置、自由缩放。
final class PinnedImagePanel: NSPanel {

    override var canBecomeKey: Bool { true }     // 要能收 ⌘C
    override var canBecomeMain: Bool { true }

    let image: NSImage

    init(image: NSImage, frame: NSRect) {
        self.image = image
        super.init(
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .borderless, .resizable],
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
        isMovableByWindowBackground = true     // 拖图片本体即可移动
        isReleasedWhenClosed = false
        minSize = NSSize(width: 90, height: 60)
        animationBehavior = .utilityWindow
    }

    /// 让窗口菜单里的「关闭 ⌘W」对固定图真的有效。
    ///
    /// NSWindow 默认的 performClose: 是去找关闭按钮；
    /// 这个面板是 .borderless，根本没有关闭按钮，于是它只会「哔」一声什么都不做 ——
    /// 表现为 ⌘W 按了没反应。这里直接接管，不绕那圈。
    override func performClose(_ sender: Any?) {
        close()
    }

    /// ⌘W 走的是 performKeyEquivalent 这条路（主菜单的快捷键），
    /// 面板得能成为 key 才会被送到这里 —— canBecomeKey 已经是 true。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        // Esc 没在主菜单里，得自己认
        if event.keyCode == 53 {
            close()
            return true
        }
        return false
    }
}

/// 图片本体。按比例缩放填满窗口，外面留一点边当相框。
final class PinnedImageView: NSView {

    let image: NSImage
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onClose: (() -> Void)?
    var onCloseAll: (() -> Void)?

    private let inset: CGFloat = 1
    private var closeButton: NSButton?

    init(image: NSImage, frame: NSRect) {
        self.image = image
        super.init(frame: frame)
        wantsLayer = true
        setupCloseButton()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 鼠标移到图上时，左上角冒出一个 ✕。
    ///
    /// 之前唯一的关闭入口是「右键 → 关闭」，快捷键也没接 ——
    /// 用户根本不知道能关，只能右键翻菜单。
    /// 用真正的子视图而不是自己画+自己命中测试：子视图会先拿到点击，
    /// 所以点 ✕ 不会触发「按住背景拖窗口」，图片其他地方照旧可以按着拖。
    private func setupCloseButton() {
        let size: CGFloat = 18
        let b = NSButton(frame: NSRect(x: 6, y: bounds.height - size - 6,
                                       width: size, height: size))
        b.title = "✕"
        b.isBordered = false
        b.bezelStyle = .circular
        b.font = .systemFont(ofSize: 11, weight: .bold)
        b.contentTintColor = .white
        b.wantsLayer = true
        b.layer?.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.55).cgColor
        b.layer?.cornerRadius = size / 2
        b.target = self
        b.action = #selector(closeAction)
        b.toolTip = "关闭（也可以按 Esc 或 ⌘W）"
        b.isHidden = true
        // 窗口拉高拉矮时，✕ 得一直贴着上边
        b.autoresizingMask = [.minYMargin]
        addSubview(b)
        closeButton = b
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        // .activeAlways：App 不是前台时也要能感应悬停，
        // 否则从别的 App 截完图，鼠标移上去什么都不会出现
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { setHovering(true) }
    override func mouseExited(with event: NSEvent) { setHovering(false) }

    private func setHovering(_ hovering: Bool) {
        closeButton?.isHidden = !hovering
    }

    /// 自检用：✕ 按钮现在是否露着
    var isCloseButtonVisible: Bool { closeButton?.isHidden == false }

    /// 自检用：模拟鼠标移进 / 移出。
    /// 直接调 mouseEntered 需要造一个 NSEvent，没必要 —— 这里只验「悬停 → ✕ 出现」这条线。
    func simulateHover(_ hovering: Bool) { setHovering(hovering) }

    /// 按键落在图上时：Esc 直接关掉。
    /// 截完图窗口就是 key，用户下意识按 Esc 应该就能收掉它。
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {          // Esc
            onClose?()
            return
        }
        super.keyDown(with: event)        // 其余按键交回响应链，别吞掉
    }

    /// ⌘W / ⌘C / ⌘S 在窗口层面就拦下了（见 PinnedImagePanel.performKeyEquivalent），
    /// 这里兜一道，保证视图直接当 firstResponder 时也有效。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "w": onClose?(); return true
        case "c": onCopy?(); return true
        case "s": onSave?(); return true
        default: return false
        }
    }

    override var acceptsFirstResponder: Bool { true }

    /// 视图本身不处理 mouseDown —— 留给窗口的「拖背景移动」，
    /// 这样按住图片任意位置都能拖动它。
    override var mouseDownCanMoveWindow: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let box = bounds.insetBy(dx: inset, dy: inset)

        // 圆角白底（图片是透明 PNG 时也能看清边界）
        let path = CGPath(roundedRect: box, cornerWidth: 6, cornerHeight: 6, transform: nil)
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        NSColor.white.setFill()
        ctx.fill(box)

        // 等比缩放填满
        let src = image.size
        guard src.width > 0, src.height > 0 else { ctx.restoreGState(); return }
        let scale = min(box.width / src.width, box.height / src.height)
        let w = src.width * scale, h = src.height * scale
        let target = NSRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
        image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1.0)
        ctx.restoreGState()

        // 描边
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor(calibratedWhite: 0, alpha: 0.18).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
    }

    // MARK: 交互

    /// ⌘C：把图放进剪贴板，之后就能粘进笔记
    @objc func copy(_ sender: Any?) {
        onCopy?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let copyItem = NSMenuItem(title: "复制图片  ⌘C", action: #selector(copy(_:)), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)

        let saveItem = NSMenuItem(title: "存储为 PNG…  ⌘S", action: #selector(saveAction), keyEquivalent: "")
        saveItem.target = self
        menu.addItem(saveItem)

        menu.addItem(.separator())

        let closeItem = NSMenuItem(title: "关闭  ⌘W / Esc", action: #selector(closeAction), keyEquivalent: "")
        closeItem.target = self
        menu.addItem(closeItem)

        let closeAll = NSMenuItem(title: "关闭全部固定图片", action: #selector(closeAllAction), keyEquivalent: "")
        closeAll.target = self
        menu.addItem(closeAll)

        return menu
    }

    @objc private func saveAction() { onSave?() }
    @objc private func closeAction() { onClose?() }
    @objc private func closeAllAction() { onCloseAll?() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}

// MARK: - 多重管理

final class PinnedImageManager {

    static let shared = PinnedImageManager()

    private var panels: [PinnedImagePanel] = []
    private var cascade = 0

    var count: Int { panels.count }
    var isEmpty: Bool { panels.isEmpty }

    /// 钉一张图。`sourceRect` 是截图时框选的屏幕区域（Cocoa 全局坐标），
    /// 用来把图片摆在它旁边，方便对照。
    @discardableResult
    func pin(_ image: NSImage, sourceRect: NSRect? = nil) -> PinnedImagePanel {
        let size = fittedSize(for: image)
        let origin = placement(for: size, sourceRect: sourceRect)
        let frame = NSRect(origin: origin, size: size)

        let panel = PinnedImagePanel(image: image, frame: frame)
        let view = PinnedImageView(image: image,
                                   frame: NSRect(origin: .zero, size: size))
        view.onCopy = { [weak self] in
            ScreenCapture.copyToPasteboard(image)
            CaptureToast.shared.show("截图已复制 · 可直接 ⌘V 粘进笔记")
            _ = self
        }
        view.onSave = { [weak self] in self?.save(image) }
        view.onClose = { [weak panel] in panel?.close() }
        view.onCloseAll = { [weak self] in self?.closeAll() }

        panel.contentView = view
        panels.append(panel)

        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(view)

        // 关掉时从列表里摘掉
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { [weak self] note in
            guard let p = note.object as? PinnedImagePanel else { return }
            self?.panels.removeAll { $0 === p }
        }

        return panel
    }

    func closeAll() {
        let all = panels
        panels.removeAll()
        for p in all { p.close() }
    }

    func panel(at index: Int) -> PinnedImagePanel? {
        index >= 0 && index < panels.count ? panels[index] : nil
    }

    // MARK: 尺寸与摆放

    /// 图片初始尺寸：**默认按原尺寸 1:1 显示**，只有超出屏幕才等比缩小。
    ///
    /// 之前是压到屏幕 45% —— 那样截出来的图会比实际小一圈，
    /// 对照原文时会觉得「图变了」。钉在屏幕上的意义就是它和原内容一模一样。
    private func fittedSize(for image: NSImage) -> NSSize {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let src = image.size
        guard src.width > 0, src.height > 0 else { return NSSize(width: 300, height: 200) }

        let maxW = screen.width * 0.86
        let maxH = screen.height * 0.86
        let scale = min(1, maxW / src.width, maxH / src.height)
        return NSSize(width: max(80, src.width * scale),
                      height: max(60, src.height * scale))
    }

    /// 摆放在截取区域旁边；放不下就错开叠放
    private func placement(for size: NSSize, sourceRect: NSRect?) -> NSPoint {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let gap: CGFloat = 12

        if let src = sourceRect {
            // 优先放到选取区域正下方
            let below = NSPoint(x: src.minX, y: src.minY - size.height - gap)
            if below.y >= screen.minY + 8, below.x + size.width <= screen.maxX {
                return below
            }
            // 其次放到右边
            let right = NSPoint(x: src.maxX + gap, y: src.maxY - size.height)
            if right.x + size.width <= screen.maxX,
               right.y >= screen.minY + 8, right.y + size.height <= screen.maxY {
                return right
            }
        }

        // 兜底：从右上角往下错开
        let step: CGFloat = 26
        let n = CGFloat(cascade % 8)
        cascade += 1
        let x = screen.maxX - size.width - 24 - n * step
        let y = screen.maxY - size.height - 24 - n * step
        return NSPoint(x: max(screen.minX + 8, x), y: max(screen.minY + 8, y))
    }

    private func save(_ image: NSImage) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "截图 \(Int(Date().timeIntervalSince1970)).png"
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try png.write(to: url, options: .atomic)
            CaptureToast.shared.show("已存为 \(url.lastPathComponent)")
        } catch {
            CaptureToast.shared.show("保存失败", accent: .systemRed)
        }
    }
}
