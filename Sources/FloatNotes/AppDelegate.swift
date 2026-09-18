import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem?
    private var ballPanel: FloatingBallPanel?
    private var ballView: FloatingBallView?
    private var hotKeys: [GlobalHotKey] = []
    private var watcher: NoteWatcher?

    private var isSelfTest = false

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        // --dump-icons <目录>：把菜单栏图标导出成 PNG，便于用像素检查（AI 没法直接看图）
        if let i = CommandLine.arguments.firstIndex(of: "--dump-icons"),
           i + 1 < CommandLine.arguments.count {
            let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for scale in [1, 2, 4] {
                let img = Self.menuBarIcon()
                let px = 18 * scale
                guard let ctx = CGContext(data: nil, width: px, height: px,
                                          bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                      let tiff = img.tiffRepresentation,
                      let src = NSBitmapImageRep(data: tiff)?.cgImage else { continue }
                ctx.interpolationQuality = .none
                ctx.draw(src, in: CGRect(x: 0, y: 0, width: px, height: px))
                guard let out = ctx.makeImage() else { continue }
                let rep = NSBitmapImageRep(cgImage: out)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: dir.appendingPathComponent("menubar@\(scale)x.png"))
                }
            }
            Self.log("[dump] 菜单栏图标已导出到 \(dir.path)")
            exit(0)
        }

        // --dom-probe：打印编辑器命中测试结果，用来确定「空白处」怎么判定
        if CommandLine.arguments.contains("--dom-probe") {
            runDOMProbe()
            return
        }

        // --screenshot <png路径>：渲染一张「笔记窗口」示意图，给 README 用。
        // 用 WKWebView 自己渲染 + 合成窗口外框，避免依赖屏幕录制权限。
        if let i = CommandLine.arguments.firstIndex(of: "--screenshot"),
           i + 1 < CommandLine.arguments.count {
            let out = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            runScreenshotMode(to: out)
            return
        }

        isSelfTest = CommandLine.arguments.contains("--selftest")

        NoteWindowManager.shared.onLog = { msg in Self.log(msg) }

        setupStatusItem()
        setupFloatingBall()
        setupHotKeys()

        NotificationCenter.default.addObserver(
            forName: Settings.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.applyBallSettings()
            self?.applyActivationPolicy()
        }

        NotificationCenter.default.addObserver(
            forName: .floatNotesResetBall, object: nil, queue: .main
        ) { [weak self] _ in
            self?.resetBallPosition()
        }

        startWatchingNotes()
        installContentDragMonitor()

        Self.log("""
        ─────────────────────────────────────────────
         悬浮笔记 M1
         ⌥⌘N 新建  ⌥⌘E 划词新建  ⌥⌘K 搜索
         ⌥⌘H 显隐全部  ⌥⌘R 全部收起  ⌥⌘L 覆盖菜单栏
        ─────────────────────────────────────────────
        """)

        if CommandLine.arguments.contains("--settings-smoke") {
            // 造一条摘录，让整理窗口有内容可渲染（空状态也算通过，但有内容更能验证列表）
            let smokeID = DailyNote.todayID()
            NoteStore.shared.ensureNote(smokeID)
            NoteStore.shared.appendText(
                DailyNote.entry(for: CapturedSelection(
                    text: "冒烟测试摘录", sourceApp: "Safari", sourceTitle: "冒烟文章",
                    sourceURL: "https://example.com/smoke", method: "AX")),
                to: smokeID)

            SettingsWindowController.shared.show()
            TriageWindowController.shared.show()

            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                let settings = NSApp.windows.filter { $0.isVisible && $0.title.contains("设置") }
                let triage = NSApp.windows.filter { $0.isVisible && $0.title.contains("整理") }
                Self.log("[smoke] 设置窗口 \(settings.count) 个 "
                       + "\(settings.first.map { NSStringFromRect($0.frame) } ?? "无")")
                Self.log("[smoke] 整理窗口 \(triage.count) 个 "
                       + "\(triage.first.map { NSStringFromRect($0.frame) } ?? "无")")

                // 整理窗口能不能真的解析出条目
                let parsed = DailyNoteTriage.parse(NoteStore.shared.load(smokeID))
                Self.log("[smoke] 整理窗口解析到 \(parsed.entries.count) 条摘录")

                NoteStore.shared.delete(smokeID)
                let ok = !settings.isEmpty && !triage.isEmpty && parsed.entries.count >= 1
                Self.log("[smoke] \(ok ? "PASS ✅" : "FAIL ❌")")
                exit(ok ? 0 : 1)
            }
            return
        }

        if isSelfTest {
            NoteWindowManager.shared.open(Self.selftestID, focus: false)
            runSelfTest()
        } else {
            NoteWindowManager.shared.restoreSession()
            if !Settings.shared.hasOnboarded {
                Settings.shared.hasOnboarded = true
                showOnboarding()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NoteStore.shared.flush()
        NoteStore.shared.rememberOpenNotes(NoteWindowManager.shared.openIDs)
    }

    private func showOnboarding() {
        let alert = NSAlert()
        alert.messageText = "悬浮笔记已经就位"
        alert.informativeText = """
        菜单栏多了一个图标，屏幕边缘多了一个悬浮球。

        · 点悬浮球 → 新建笔记；双击直接新建
        · 笔记窗口永远浮在最上层，切到全屏网页也盖不住它
        · 点笔记窗口打字不会打断你正在看的页面

        快捷键：⌥⌘N 新建 · ⌥⌘H 显隐全部 · ⌥⌘R 全部收起 · ⌥⌘L 覆盖菜单栏
        笔记以 Markdown 存在「文稿 › 悬浮笔记」。
        """
        alert.addButton(withTitle: "开始使用")
        alert.addButton(withTitle: "打开设置…")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            SettingsWindowController.shared.show()
        }
    }

    // MARK: - 菜单栏

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = Self.menuBarIcon()
            button.image?.isTemplate = true
            button.toolTip = "悬浮笔记"
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// 菜单栏图标：一张「悬浮卡片」，和 App 图标同一套视觉语言。
    /// 用 template 模式（纯 alpha），系统会自动适配深浅色和选中态。
    private static func menuBarIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { _ in
            let stroke = NSColor.black
            stroke.setStroke()
            stroke.setFill()

            // 卡片轮廓
            let card = NSRect(x: 2.4, y: 3.3, width: 13.2, height: 11.4)
            let cardPath = NSBezierPath(roundedRect: card, xRadius: 2.7, yRadius: 2.7)
            cardPath.lineWidth = 1.35
            cardPath.stroke()

            // 内部三条"文字线"：第一条略粗（像标题），最后一条短一截
            func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
                let r = NSRect(x: x, y: y, width: w, height: h)
                NSBezierPath(roundedRect: r, xRadius: h / 2, yRadius: h / 2).fill()
            }
            let left = card.minX + 2.0
            bar(left, card.maxY - 3.5, 9.2, 1.65)   // 标题行
            bar(left, card.maxY - 6.4, 9.2, 1.05)
            bar(left, card.maxY - 8.9, 5.6, 1.05)

            return true
        }
        img.isTemplate = true
        return img
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let new = NSMenuItem(title: "＋  新建笔记", action: #selector(newNote), keyEquivalent: "n")
        new.keyEquivalentModifierMask = [.option, .command]
        new.target = self
        menu.addItem(new)

        let capture = NSMenuItem(title: "✂️  划词新建（抓取选中文字）",
                                 action: #selector(captureSelection), keyEquivalent: "e")
        capture.keyEquivalentModifierMask = [.option, .command]
        capture.target = self
        menu.addItem(capture)

        let search = NSMenuItem(title: "🔍  搜索笔记…", action: #selector(searchNotes), keyEquivalent: "k")
        search.keyEquivalentModifierMask = [.option, .command]
        search.target = self
        menu.addItem(search)

        let todayID = DailyNote.todayID()
        let todayCount = DailyNote.entryCount(NoteStore.shared.load(todayID))
        let today = NSMenuItem(
            title: "📅  今日笔记（\(todayCount) 条）",
            action: #selector(openTodayNote), keyEquivalent: "t")
        today.keyEquivalentModifierMask = [.option, .command]
        today.target = self
        menu.addItem(today)

        let triage = NSMenuItem(
            title: "📥  整理今日笔记…\(todayCount > 0 ? "（\(todayCount) 条待整理）" : "")",
            action: #selector(openTriage), keyEquivalent: "g")
        triage.keyEquivalentModifierMask = [.option, .command]
        triage.target = self
        menu.addItem(triage)

        menu.addItem(.separator())

        addRecents(to: menu)

        menu.addItem(.separator())

        let collapse = NSMenuItem(title: "全部收起 / 展开", action: #selector(collapseAll), keyEquivalent: "r")
        collapse.keyEquivalentModifierMask = [.option, .command]
        collapse.target = self
        menu.addItem(collapse)

        let toggle = NSMenuItem(title: "显示 / 隐藏全部笔记", action: #selector(toggleAll), keyEquivalent: "h")
        toggle.keyEquivalentModifierMask = [.option, .command]
        toggle.target = self
        menu.addItem(toggle)

        let ball = NSMenuItem(
            title: Settings.shared.showFloatingBall ? "隐藏悬浮球" : "显示悬浮球",
            action: #selector(toggleFloatingBall), keyEquivalent: "b")
        ball.keyEquivalentModifierMask = [.option, .command]
        ball.target = self
        menu.addItem(ball)

        let resetBall = NSMenuItem(
            title: "把悬浮球移回边缘", action: #selector(resetBallPosition), keyEquivalent: "")
        resetBall.target = self
        menu.addItem(resetBall)

        let dock = NSMenuItem(
            title: Settings.shared.showInDock ? "✓ 在程序坞中显示图标" : "在程序坞中显示图标",
            action: #selector(toggleDockIcon), keyEquivalent: "")
        dock.target = self
        menu.addItem(dock)

        let cover = NSMenuItem(
            title: Settings.shared.coverMenuBar ? "✓ 盖住菜单栏和程序坞" : "盖住菜单栏和程序坞",
            action: #selector(toggleCover), keyEquivalent: "l")
        cover.keyEquivalentModifierMask = [.option, .command]
        cover.target = self
        menu.addItem(cover)

        menu.addItem(.separator())

        addCurrentNoteMenu(to: menu)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let gc = NSMenuItem(title: "清理未使用的附件…", action: #selector(cleanupAttachments), keyEquivalent: "")
        gc.target = self
        menu.addItem(gc)

        let perf = NSMenuItem(title: "内存诊断", action: #selector(printPerf), keyEquivalent: "")
        perf.target = self
        menu.addItem(perf)

        let diag = NSMenuItem(title: "窗口诊断", action: #selector(printDiagnostics), keyEquivalent: "")
        diag.target = self
        menu.addItem(diag)

        let folder = NSMenuItem(title: "打开笔记文件夹", action: #selector(openNotesFolder), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出悬浮笔记", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func addRecents(to menu: NSMenu) {
        let recents = NoteStore.shared.recent(limit: 7)
        guard !recents.isEmpty else {
            let empty = NSMenuItem(title: "（还没有笔记）", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        let header = NSMenuItem(title: "最近笔记", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        for id in recents {
            let isOpen = NoteWindowManager.shared.panel(for: id) != nil
            let mi = NSMenuItem(title: "    \(isOpen ? "●" : "○") \(id)", action: nil, keyEquivalent: "")

            let sub = NSMenu()
            let open = NSMenuItem(title: "打开", action: #selector(openRecent(_:)), keyEquivalent: "")
            open.target = self; open.representedObject = id
            sub.addItem(open)

            let reveal = NSMenuItem(title: "在访达中显示", action: #selector(revealRecent(_:)), keyEquivalent: "")
            reveal.target = self; reveal.representedObject = id
            sub.addItem(reveal)

            sub.addItem(.separator())

            let del = NSMenuItem(title: "删除…", action: #selector(deleteRecent(_:)), keyEquivalent: "")
            del.target = self; del.representedObject = id
            sub.addItem(del)

            mi.submenu = sub
            menu.addItem(mi)
        }
    }

    // MARK: - 悬浮球

    private func setupFloatingBall() {
        let panel = FloatingBallPanel(origin: NSPoint(x: 0, y: 0))
        let view = FloatingBallView(frame: NSRect(
            origin: .zero,
            size: NSSize(width: FloatingBallPanel.ballSize, height: FloatingBallPanel.ballSize)))
        view.onClick = { [weak self] in self?.showLauncherMenu(anchor: view) }
        view.onDoubleClick = { [weak self] in self?.newNote() }
        panel.contentView = view
        ballPanel = panel
        ballView = view

        // 恢复上次停的位置；只有从来没放过才用默认那一侧。
        // 注意不能在这里调 applyEdge —— 那会把用户自己摆好的位置又拽回边缘。
        if let saved = UserDefaults.standard.string(forKey: "ballFrame") {
            let r = NSRectFromString(saved)
            if r.width > 10, r.height > 10 {
                panel.setFrame(r, display: false)
                view.finishDrag(animated: false)   // 夹回屏幕内（换过显示器也不怕）
            } else {
                view.placeAtDefaultEdge()
            }
        } else {
            view.placeAtDefaultEdge()
        }
        lastBallEdge = Settings.shared.ballEdge

        if Settings.shared.showFloatingBall {
            panel.orderFrontRegardless()
        }
    }

    /// 响应「在程序坞中显示图标」开关
    private func applyActivationPolicy() {
        let want: NSApplication.ActivationPolicy = Settings.shared.showInDock ? .regular : .accessory
        guard NSApp.activationPolicy() != want else { return }
        NSApp.setActivationPolicy(want)
        Self.log("[app] 激活策略 → \(Settings.shared.showInDock ? "regular（有 Dock 图标）" : "accessory（纯菜单栏）")")
    }

    /// 点 Dock 图标、但一个窗口都没有时，打开今日笔记
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openTodayNote() }
        return true
    }

    /// 自检用：悬浮球当前是否可见
    var ballIsVisible: Bool { ballPanel?.isVisible ?? false }

    private var lastBallEdge: String?

    /// 响应设置变化：显隐 + 贴边
    private func applyBallSettings() {
        guard let panel = ballPanel else { return }

        guard Settings.shared.showFloatingBall else {
            panel.orderOut(nil)
            return
        }

        panel.orderFrontRegardless()

        // 只在「贴边位置」这个设置真的被改了的时候才重新吸附。
        // 启动时 lastBallEdge 已经初始化过，所以不会覆盖恢复出来的位置。
        let edge = Settings.shared.ballEdge
        if lastBallEdge != edge {
            ballView?.applyEdge(animated: lastBallEdge != nil)
            lastBallEdge = edge
        }
    }

    private func showLauncherMenu(anchor: NSView) {
        let menu = NSMenu()
        menu.delegate = self
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: anchor.bounds.minY - 4),
                   in: anchor)
    }

    // MARK: - 热键

    private func setupHotKeys() {
        hotKeys = [
            GlobalHotKey(keyCode: Key.n, modifiers: Key.cmdOption) { [weak self] in self?.newNote() },
            GlobalHotKey(keyCode: Key.h, modifiers: Key.cmdOption) { [weak self] in self?.toggleAll() },
            GlobalHotKey(keyCode: Key.r, modifiers: Key.cmdOption) { [weak self] in self?.collapseAll() },
            GlobalHotKey(keyCode: Key.l, modifiers: Key.cmdOption) { [weak self] in self?.toggleCover() },
            GlobalHotKey(keyCode: Key.e, modifiers: Key.cmdOption) { [weak self] in self?.captureSelection() },
            GlobalHotKey(keyCode: Key.k, modifiers: Key.cmdOption) { [weak self] in self?.searchNotes() },
            GlobalHotKey(keyCode: Key.t, modifiers: Key.cmdOption) { [weak self] in self?.openTodayNote() },
            GlobalHotKey(keyCode: Key.g, modifiers: Key.cmdOption) { [weak self] in self?.openTriage() },
            GlobalHotKey(keyCode: Key.b, modifiers: Key.cmdOption) { [weak self] in self?.toggleFloatingBall() },
        ].compactMap { $0 }
        Self.log("[hotkey] 已注册 \(hotKeys.count)/9 个全局热键")
    }

    // MARK: - 动作

    @objc private func newNote() { NoteWindowManager.shared.newNote() }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        NoteWindowManager.shared.open(id)
    }

    @objc private func revealRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        NoteStore.shared.flush()
        NSWorkspace.shared.activateFileViewerSelecting([NoteStore.shared.url(for: id)])
    }

    @objc private func deleteRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        let alert = NSAlert()
        alert.messageText = "删除「\(id)」？"
        alert.informativeText = "笔记文件会被移到废纸篓，可以恢复。"
        alert.addButton(withTitle: "移到废纸篓")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let url = NoteStore.shared.url(for: id)
        NoteWindowManager.shared.close(id)
        NSWorkspace.shared.recycle([url]) { _, _ in }
        Self.log("[notes] 已删除 \(id)")
    }

    @objc private func toggleAll() { NoteWindowManager.shared.toggleAll() }
    @objc private func collapseAll() { NoteWindowManager.shared.collapseAll() }

    @objc private func resetBallPosition() {
        ballView?.applyEdge(animated: true)
        Self.log("[ball] 已移回\(Settings.shared.ballEdge == "left" ? "左" : "右")边缘")
    }

    /// ⌥⌘B：隐藏 / 显示悬浮球
    @objc private func toggleFloatingBall() {
        Settings.shared.showFloatingBall.toggle()
        let shown = Settings.shared.showFloatingBall
        Self.log("[ball] 悬浮球已\(shown ? "显示" : "隐藏")（⌥⌘B 可切回）")
        // 隐藏时给一次轻提示，免得用户以为功能坏了；显示时不用提示
        if !shown {
            CaptureToast.shared.show("悬浮球已隐藏 · ⌥⌘B 可切回", accent: .systemGray)
        }
    }

    @objc private func toggleDockIcon() {
        Settings.shared.showInDock.toggle()
        applyActivationPolicy()
    }

    @objc private func toggleCover() {
        let lvl = NoteWindowManager.shared.toggleMenuBarCover()
        Self.log("[settings] 置顶层级 → \(lvl.rawValue) (\(lvl.level.rawValue))")
    }

    @objc private func openSettings() { SettingsWindowController.shared.show() }

    @objc private func printPerf() {
        Self.log("[perf] \(Perf.report(windows: NoteWindowManager.shared.openCount))")
    }

    @objc private func printDiagnostics() {
        Self.log("[diagnostics]\n\(NoteWindowManager.shared.diagnostics())")
    }

    // MARK: - M2 动作

    private func startWatchingNotes() {
        let w = NoteWatcher(path: NoteStore.shared.root.path)
        w.start { ids in
            DispatchQueue.main.async {
                NoteWindowManager.shared.reloadFromDisk(ids)
            }
        }
        watcher = w
        Self.log("[sync] 已监听 \(NoteStore.shared.root.path)")
    }

    /// ⌥⌘E：抓取当前选中文字 + 来源，直接开一篇新笔记
    @objc private func captureSelection() {
        guard SelectionCapture.isTrusted else {
            promptAccessibility()
            return
        }

        guard let sel = SelectionCapture.capture() else {
            Self.log("[capture] 没有抓到选中内容，改为新建空笔记")
            NoteWindowManager.shared.newNote()
            return
        }

        Self.log("[capture] 方式=\(sel.method) 字数=\(sel.text.count) "
               + "来源=\(sel.sourceApp ?? "?") 标题=\(sel.sourceTitle ?? "无") "
               + "URL=\(sel.sourceURL ?? "无")")

        if Settings.shared.captureToDailyNote {
            captureToDailyNote(sel)
        } else {
            let markdown = SelectionNote.markdown(for: sel)
            let id = NoteStore.shared.uniqueNoteID(base: SelectionNote.noteTitle(for: sel))
            NoteWindowManager.shared.open(id, prefill: markdown)
            Self.log("[capture] 已弹出新窗口 → \(id)")
        }
    }

    /// 静默路线：追加到今日笔记，只弹一个不抢焦点的提示
    private func captureToDailyNote(_ sel: CapturedSelection) {
        DailyNote.append(entry: DailyNote.entry(for: sel)) { [weak self] id in
            guard let self else { return }
            guard !id.isEmpty else {
                CaptureToast.shared.show("存入失败，请检查笔记目录",
                                         accent: .systemRed)
                Self.log("[capture] 写入今日笔记失败")
                return
            }
            let count = DailyNote.entryCount(NoteStore.shared.load(id))
            CaptureToast.shared.show("已存入今日笔记 · 第 \(count) 条") { [weak self] in
                self?.openTodayNote()
            }
            Self.log("[capture] 已静默存入 \(id)，当前 \(count) 条")
        }
    }

    @objc private func openTriage() {
        TriageWindowController.shared.toggle()
    }

    @objc private func openTodayNote() {
        let id = DailyNote.todayID()
        NoteStore.shared.ensureNote(id)
        NoteWindowManager.shared.open(id)
        Self.log("[daily] 打开今日笔记 \(id)")
    }

    private func promptAccessibility() {
        let alert = NSAlert()
        alert.messageText = "需要「辅助功能」权限才能抓取选中文字"
        alert.informativeText = """
        悬浮笔记要读取你在其他 App 里选中的文字，需要这项系统权限。

        点「打开系统设置」后，在「隐私与安全性 › 辅助功能」里勾选「悬浮笔记」。
        授权后无需重启，直接再按 ⌥⌘E 即可。
        """
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            SelectionCapture.requestPermission()
            if let url = URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @objc private func searchNotes() { SearchWindowController.shared.toggle() }

    @objc private func cleanupAttachments() {
        let preview = AttachmentGC.collect(dryRun: true)
        guard preview.removed > 0 else {
            let a = NSAlert()
            a.messageText = "没有需要清理的附件"
            a.informativeText = "共 \(preview.totalAttachments) 个附件，全部都在使用中。"
            a.addButton(withTitle: "好")
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
            return
        }

        let mb = Double(preview.removedBytes) / 1024 / 1024
        let a = NSAlert()
        a.messageText = "发现 \(preview.removed) 个未使用的附件"
        a.informativeText = String(format: "共 %.2f MB，删除后无法从笔记里恢复（但可以从废纸篓找回）。", mb)
        a.addButton(withTitle: "移到废纸篓")
        a.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }

        var moved = 0
        for name in preview.removedNames {
            let url = NoteStore.shared.attachmentsDir.appendingPathComponent(name)
            NSWorkspace.shared.recycle([url]) { _, _ in }
            moved += 1
        }
        Self.log("[gc] 已清理 \(moved) 个未使用附件")
    }

    // MARK: - 当前笔记（外观 / 导出）

    private func addCurrentNoteMenu(to menu: NSMenu) {
        guard let id = NoteWindowManager.shared.activeNoteID else {
            let none = NSMenuItem(title: "当前笔记（无）", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
            return
        }

        let root = NSMenuItem(title: "当前笔记：\(id.prefix(28))", action: nil, keyEquivalent: "")
        let sub = NSMenu()

        // 透明度
        let opacityItem = NSMenuItem(title: "透明度", action: nil, keyEquivalent: "")
        let opacityMenu = NSMenu()
        let current = Settings.shared.opacity(for: id)
        for pct in [100, 90, 80, 70, 55, 40] {
            let v = Double(pct) / 100.0
            let mi = NSMenuItem(title: "\(abs(current - v) < 0.01 ? "✓ " : "")\(pct)%",
                                action: #selector(setOpacityAction(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = ["id": id, "value": v]
            opacityMenu.addItem(mi)
        }
        opacityItem.submenu = opacityMenu
        sub.addItem(opacityItem)

        // 主题
        let themeItem = NSMenuItem(title: "主题", action: nil, keyEquivalent: "")
        let themeMenu = NSMenu()
        let curTheme = Settings.shared.theme(for: id)
        for (key, label) in [("auto", "跟随系统"), ("light", "浅色"), ("dark", "深色")] {
            let mi = NSMenuItem(title: "\(curTheme == key ? "✓ " : "")\(label)",
                                action: #selector(setThemeAction(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = ["id": id, "value": key]
            themeMenu.addItem(mi)
        }
        themeItem.submenu = themeMenu
        sub.addItem(themeItem)

        // 置顶开关
        let pinned = NoteWindowManager.shared.panel(for: id)?.isPinnedOnTop ?? true
        let pin = NSMenuItem(title: pinned ? "✓ 保持置顶" : "保持置顶",
                             action: #selector(togglePinAction), keyEquivalent: "")
        pin.target = self
        sub.addItem(pin)

        sub.addItem(.separator())

        // 导出
        let exportItem = NSMenuItem(title: "导出 / 复制", action: nil, keyEquivalent: "")
        let exportMenu = NSMenu()
        for (sel, label) in [
            (#selector(exportRTF), "存为 RTF…"),
            (#selector(copyRichText), "复制为富文本"),
            (#selector(copyMarkdown), "复制为 Markdown"),
        ] {
            let mi = NSMenuItem(title: label, action: sel, keyEquivalent: "")
            mi.target = self
            exportMenu.addItem(mi)
        }
        exportItem.submenu = exportMenu
        sub.addItem(exportItem)

        root.submenu = sub
        menu.addItem(root)
    }

    @objc private func setOpacityAction(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let id = info["id"] as? String, let v = info["value"] as? Double else { return }
        Settings.shared.setOpacity(v, for: id)
        Self.log("[appearance] \(id) 透明度 → \(Int(v * 100))%")
    }

    @objc private func setThemeAction(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let id = info["id"] as? String, let v = info["value"] as? String else { return }
        Settings.shared.setTheme(v, for: id)
        Self.log("[appearance] \(id) 主题 → \(v)")
    }

    @objc private func togglePinAction() {
        guard let id = NoteWindowManager.shared.activeNoteID,
              let panel = NoteWindowManager.shared.panel(for: id) else { return }
        panel.setPinnedOnTop(!panel.isPinnedOnTop)
        Self.log("[appearance] \(id) 置顶 → \(panel.isPinnedOnTop)")
    }

    private func withHTML(_ body: @escaping (String?, String) -> Void) {
        guard let id = NoteWindowManager.shared.activeNoteID else { return }
        NoteWindowManager.shared.requestHTML(for: id) { html in
            body(html, id)
        }
    }

    @objc private func exportRTF() {
        withHTML { html, id in
            guard let html, let rtf = NoteExporter.rtfData(fromHTML: html) else {
                Self.log("[export] RTF 转换失败"); return
            }
            if let url = NoteExporter.write(rtf, suggestedName: id, type: "rtf") {
                Self.log("[export] 已导出 \(url.path)")
            }
        }
    }

    @objc private func copyRichText() {
        withHTML { html, id in
            guard let html else { return }
            let plain = NoteExporter.plainText(fromHTML: html) ?? NoteStore.shared.load(id)
            NoteExporter.copyRichText(html: html, plainFallback: plain)
            Self.log("[export] \(id) 已复制为富文本")
        }
    }

    @objc private func copyMarkdown() {
        guard let id = NoteWindowManager.shared.activeNoteID else { return }
        NoteStore.shared.flush()
        let md = NoteStore.shared.load(id)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(md, forType: .string)
        Self.log("[export] \(id) 已复制为 Markdown")
    }

    @objc private func openNotesFolder() {
        NSWorkspace.shared.open(NoteStore.shared.root)
    }

    // MARK: - DOM 探针

    private func runDOMProbe() {
        let size = NSSize(width: 560, height: 620)
        let panel = NotePanel(noteID: "DOM探针", frame: NSRect(origin: .zero, size: size))
        let editor = WebEditorView(frame: NSRect(origin: .zero, size: size))
        editor.setFontSize(15)
        editor.onReady = { editor.load(markdown: Self.screenshotMarkdown) }
        panel.contentView = editor
        panel.orderFrontRegardless()

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            // 用 Swift 原始字符串 #"""..."""#，里面的 \n \s 都原样传给 JS，
            // 否则 Swift 会先把它当自己的转义处理，\s 直接报 invalid escape sequence
            let js = #"""
            (() => {
              const ed = document.querySelector('.bn-editor');
              if (!ed) return 'no .bn-editor found';
              const r = ed.getBoundingClientRect();
              const describe = (el) => {
                const out = [];
                let cur = el;
                for (let i = 0; i < 4 && cur && cur.tagName; i++) {
                  const cls = (typeof cur.className === 'string' && cur.className)
                    ? '.' + cur.className.trim().split(' ').slice(0, 2).join('.') : '';
                  out.push(cur.tagName.toLowerCase() + cls);
                  cur = cur.parentElement;
                }
                return out.join(' < ');
              };
              const pts = [
                ['左上内边距',   r.left + 6,           r.top + 6],
                ['右内边距中部', r.right - 6,          r.top + r.height * 0.4],
                ['底部内边距',   r.left + r.width / 2, r.bottom - 10],
                ['正文行上',     r.left + r.width / 2, r.top + 45],
                ['正文下方空区', r.left + r.width / 2, r.top + r.height * 0.78],
                ['标题上方',     r.left + r.width / 2, r.top + 12],
              ];
              const rows = pts.map(([name, x, y]) => {
                const el = document.elementFromPoint(x, y);
                return name + ' → ' + (el ? describe(el) : 'null');
              });
              const blocks = [...document.querySelectorAll('.bn-block-outer')].map(b => {
                const br = b.getBoundingClientRect();
                return '  block y=' + Math.round(br.top) + '..' + Math.round(br.bottom);
              });
              return 'editor rect t=' + Math.round(r.top) + ' b=' + Math.round(r.bottom)
                + ' l=' + Math.round(r.left) + ' r=' + Math.round(r.right)
                + ' h=' + Math.round(r.height)
                + '\n' + rows.join('\n') + '\n' + blocks.join('\n')
                + '\nviewport h=' + window.innerHeight;
            })()
            """#
            editor.evaluate(js) { result in
                Self.log("[dom-probe]\n\(result ?? "无返回")")
                exit(0)
            }
        }
    }

    // MARK: - 截图模式

    private static let screenshotMarkdown = """
    # 读书笔记示例

    > 数据的质量往往比数量更重要，而清洗成本被系统性低估了。

    摘自 [Attention Is All You Need](https://arxiv.org/abs/1706.03762) · via Safari · 11:30

    ## 我的想法

    - 标注质量决定了模型上限
    - 清洗环节值得单独排期

    - [x] 找一下论文里引用的数据集
    - [ ] 整理成一篇博客

    ## 代码片段

    ```python
    def clean(rows):
        return [r for r in rows if r.valid]
    ```
    """

    private func runScreenshotMode(to out: URL) {
        Self.log("[screenshot] 渲染中…")
        let size = NSSize(width: 560, height: 620)
        let panel = NotePanel(noteID: "截图", frame: NSRect(origin: .zero, size: size))

        let editor = WebEditorView(frame: NSRect(origin: .zero, size: size))
        editor.autoresizingMask = [.width, .height]
        editor.setFontSize(15)
        editor.setFontFamily(FontCatalog.css(for: "pingfang"))
        editor.setTheme("light")
        editor.onReady = {
            editor.load(markdown: Self.screenshotMarkdown)
        }
        panel.contentView = editor
        panel.orderFrontRegardless()

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
            editor.snapshot { image in
                guard let image else {
                    Self.log("[screenshot] ✗ 快照失败"); exit(1)
                }
                let composed = Self.composeWindowMockup(image)
                guard let tiff = composed.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    Self.log("[screenshot] ✗ 编码失败"); exit(1)
                }
                try? png.write(to: out)
                Self.log("[screenshot] ✓ 已输出 \(out.path)（\(Int(composed.size.width))×\(Int(composed.size.height))）")
                exit(0)
            }
        }
    }

    /// 把网页快照包进一个「App 窗口」外框：圆角 + 标题栏 + 投影
    private static func composeWindowMockup(_ content: NSImage) -> NSImage {
        let pad: CGFloat = 44
        let titleH: CGFloat = 34
        let w = content.size.width + pad * 2
        let h = content.size.height + titleH + pad * 2

        let out = NSImage(size: NSSize(width: w, height: h))
        out.lockFocus()

        // 背景透明，只画窗口本体
        let winRect = NSRect(x: pad, y: pad, width: w - pad * 2, height: h - pad * 2)
        let radius: CGFloat = 12

        // 投影
        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(calibratedWhite: 0.0, alpha: 0.28)
        shadow.shadowBlurRadius = 26
        shadow.shadowOffset = NSSize(width: 0, height: -8)
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: winRect, xRadius: radius, yRadius: radius).fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        // 标题栏
        NSGraphicsContext.current?.saveGraphicsState()
        let clip = NSBezierPath(roundedRect: winRect, xRadius: radius, yRadius: radius)
        clip.addClip()
        NSColor(calibratedRed: 0.965, green: 0.965, blue: 0.975, alpha: 1).setFill()
        NSRect(x: winRect.minX, y: winRect.maxY - titleH,
               width: winRect.width, height: titleH).fill()
        // 三个红黄绿圆点
        for (i, c) in [NSColor(calibratedRed: 1.0, green: 0.37, blue: 0.34, alpha: 1),
                       NSColor(calibratedRed: 1.0, green: 0.74, blue: 0.25, alpha: 1),
                       NSColor(calibratedRed: 0.24, green: 0.79, blue: 0.34, alpha: 1)].enumerated() {
            let dot = NSRect(x: winRect.minX + 14 + CGFloat(i) * 17,
                             y: winRect.maxY - titleH / 2 - 5.5, width: 11, height: 11)
            c.setFill()
            NSBezierPath(ovalIn: dot).fill()
        }
        // 标题文字
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.35, alpha: 1)
        ]
        let title = NSAttributedString(string: "读书笔记示例", attributes: attrs)
        title.draw(at: NSPoint(x: winRect.midX - title.size().width / 2,
                               y: winRect.maxY - titleH / 2 - title.size().height / 2))
        NSGraphicsContext.current?.restoreGraphicsState()

        // 内容
        NSGraphicsContext.current?.saveGraphicsState()
        let contentClip = NSBezierPath(
            roundedRect: NSRect(x: winRect.minX, y: winRect.minY,
                                width: winRect.width, height: winRect.height - titleH),
            xRadius: radius, yRadius: radius)
        contentClip.addClip()
        content.draw(in: NSRect(x: winRect.minX, y: winRect.minY,
                                width: winRect.width, height: winRect.height - titleH))
        NSGraphicsContext.current?.restoreGraphicsState()

        // 描边
        NSColor(calibratedWhite: 0.0, alpha: 0.10).setStroke()
        let border = NSBezierPath(roundedRect: winRect, xRadius: radius, yRadius: radius)
        border.lineWidth = 1
        border.stroke()

        out.unlockFocus()
        return out
    }

    // MARK: - 按住内容区空白拖动窗口
    //
    // 笔记窗口的内容区是 WKWebView，它会把鼠标事件全部吃掉，
    // 所以窗口原来只能靠顶部那一条标题栏拖动。
    // 这里让 JS 上报「指针是否停在编辑区空白处」，再用本地事件监听接管拖动。

    private var dragMonitor: Any?
    private var contentDrag: (startMouse: NSPoint, startOrigin: NSPoint, panel: NotePanel)?
    private var contentDragMoved = false

    /// 位移小于这个值当成单击，不吞事件 —— 免得影响正常的点选和放光标
    static let contentDragThreshold: CGFloat = 3

    private func installContentDragMonitor() {
        dragMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            guard let self, let panel = event.window as? NotePanel else { return event }

            switch event.type {
            case .leftMouseDown:
                if NoteWindowManager.shared.isPointerOverBlank(panel) {
                    self.beginContentDrag(panel: panel)
                } else {
                    self.contentDrag = nil
                }
                return event          // 不吞：单击仍然能正常聚焦

            case .leftMouseDragged:
                guard self.contentDrag != nil else { return event }
                return self.updateContentDrag(to: NSEvent.mouseLocation) ? nil : event

            case .leftMouseUp:
                self.endContentDrag()
                return event

            default:
                return event
            }
        }
    }

    func beginContentDrag(panel: NotePanel, at point: NSPoint? = nil) {
        contentDrag = (point ?? NSEvent.mouseLocation, panel.frame.origin, panel)
        contentDragMoved = false
    }

    /// 回传 true 表示这次拖动已被接管（调用方应把事件吞掉）
    @discardableResult
    func updateContentDrag(to point: NSPoint) -> Bool {
        guard let d = contentDrag else { return false }
        let dx = point.x - d.startMouse.x
        let dy = point.y - d.startMouse.y

        if !contentDragMoved {
            guard abs(dx) > Self.contentDragThreshold || abs(dy) > Self.contentDragThreshold else {
                return false          // 还没越过阈值，交给 WebView 自己处理
            }
            contentDragMoved = true
        }
        d.panel.setFrameOrigin(NSPoint(x: d.startOrigin.x + dx,
                                       y: d.startOrigin.y + dy))
        return true
    }

    func endContentDrag() {
        guard let d = contentDrag else { return }
        contentDrag = nil
        contentDragMoved = false

        // 夹回屏幕内（位置会被 windowDidMove 顺手存下来）
        guard let screen = d.panel.screen ?? NSScreen.main else { return }
        let v = screen.visibleFrame
        var f = d.panel.frame
        let x = min(max(f.origin.x, v.minX), max(v.minX, v.maxX - f.width))
        let y = min(max(f.origin.y, v.minY), max(v.minY, v.maxY - f.height))
        if x != f.origin.x || y != f.origin.y {
            f.origin = NSPoint(x: x, y: y)
            d.panel.setFrame(f, display: true)
        }
    }

    // MARK: - 自检（M1 全链路）

    private static let selftestID = "自检笔记"
    private static let tinyPNG =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

    private var finished = false
    private var started = false
    private var domProbe: String?
    private var firstPass = ""
    private var problems: [String] = []
    private var baselineMB: Double = 0

    private static let selftestMarkdown = """
    # 悬浮笔记自检

    这是一段**加粗**文字，还有 `行内代码`。

    ## 清单

    - 第一项
    - 第二项

    - [ ] 未完成待办
    - [x] 已完成待办

    > 引用块测试

    ```swift
    print("code block")
    ```
    """

    private func runSelfTest() {
        Self.log("[selftest] 开始")

        // 同 bundle id 跑两个实例时，它们共用同一个文档目录和 UserDefaults，
        // 会互相关闭彼此的窗口、互相触发文件监听。表现是「拿不到编辑器实例」
        // 这种完全看不出原因的失败 —— 所以先挡掉，给一句能看懂的话。
        if let bid = Bundle.main.bundleIdentifier {
            let me = ProcessInfo.processInfo.processIdentifier
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
                .filter { $0.processIdentifier != me }
            if !others.isEmpty {
                Self.log("[selftest] ✗ 检测到还有 \(others.count) 个悬浮笔记实例在运行"
                       + "（PID \(others.map { String($0.processIdentifier) }.joined(separator: ", "))）")
                Self.log("[selftest]   两个实例共用文档目录与偏好设置，会互相干扰。")
                Self.log("[selftest]   请先退出正在运行的实例，再执行自检。")
                exit(2)
            }
        }

        backupSettings()
        baselineMB = Perf.residentMemoryMB()
        Self.log(String(format: "[selftest] 基线内存 %.1f MB", baselineMB))

        // 只在第一个编辑器就绪时启动，否则后面每开一个窗口都会重跑一遍自检
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(
            forName: .floatNotesEditorReady, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, !self.started else { return }
            self.started = true
            if let token { NotificationCenter.default.removeObserver(token) }
            self.stage2()
        }

        // 这是整个自检的总超时，不是单个阶段。阶段越来越多，留足时间。
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak self] in
            self?.finish(ok: false, reason: "自检总时长超过 90 秒")
        }
    }

    private func stage2() {
        guard !finished else { return }
        Self.log("[selftest] 阶段2 · 写入测试 Markdown")
        guard let ed = NoteWindowManager.shared.editor(for: Self.selftestID) else {
            finish(ok: false, reason: "拿不到编辑器实例"); return
        }
        ed.load(markdown: Self.selftestMarkdown)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.stage3() }
    }

    private func stage3() {
        guard !finished else { return }
        Self.log("[selftest] 阶段3 · DOM 探针")
        guard let ed = NoteWindowManager.shared.editor(for: Self.selftestID) else {
            finish(ok: false, reason: "拿不到编辑器实例"); return
        }
        let js = """
        JSON.stringify({
          hasEditor: !!document.querySelector('.bn-editor'),
          blocks: document.querySelectorAll('.bn-block').length,
          headings: document.querySelectorAll('[data-content-type="heading"]').length,
          checkboxes: document.querySelectorAll('input[type=checkbox]').length,
          textLen: (document.querySelector('.bn-editor')?.innerText || '').length,
          lang: document.documentElement.lang
        })
        """
        ed.evaluate(js) { [weak self] result in
            guard let self else { return }
            Self.log("[selftest] DOM 探针结果: \(result ?? "nil")")
            self.domProbe = result as? String

            // S3 探针：点笔记窗口后，本 App 不该被激活。
            // 判据只看「是不是我们自己」——比较前后两个 App 名会很脆：
            // 用户随手切个窗口就误报，那不叫回归。
            if let p = NoteWindowManager.shared.panel(for: Self.selftestID) {
                let before = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
                let me = NSRunningApplication.current.localizedName ?? "?"
                // App 刚启动时自己就可能是前台（尤其 regular 策略），
                // 那不是「被这次点击抢走的」。所以只判「有没有从别人变成我们」。
                let wasAlreadyMine = (before == me)
                p.orderFrontRegardless()
                p.makeKey()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let after = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
                    let stole = (after == me) && !wasAlreadyMine
                    let note = wasAlreadyMine ? "（起始时本 App 已是前台，本次判定不适用）"
                                              : (stole ? "本 App 被激活 ⚠️" : "未打断 ✅")
                    Self.log("[selftest] S3 焦点: 前=\(before) 后=\(after) 本App=\(me) → \(note)")
                    if stole {
                        self.problems.append("点击笔记窗口把本 App 变成了前台，会打断阅读")
                    }
                }
            }

            Self.log("[selftest] 阶段4 · 导出并落盘")
            ed.requestExport()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.stage5() }
        }
    }

    private func stage5() {
        guard !finished else { return }
        NoteStore.shared.flush()
        let saved = NoteStore.shared.load(Self.selftestID)
        firstPass = saved
        Self.log("[selftest] 落盘 \(saved.count) 字符 → \(NoteStore.shared.url(for: Self.selftestID).path)")

        if let probed = domProbe, let data = probed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if !(obj["hasEditor"] as? Bool ?? false) { problems.append("编辑器 DOM 未渲染") }
            let blocks = obj["blocks"] as? Int ?? 0
            if blocks < 5 { problems.append("块数不足 (\(blocks))") }
            if (obj["headings"] as? Int ?? 0) == 0 { problems.append("标题块未渲染") }
            if (obj["checkboxes"] as? Int ?? 0) == 0 { problems.append("待办复选框未渲染") }
        } else {
            problems.append("DOM 探针无返回")
        }

        for needle in ["悬浮笔记自检", "加粗", "未完成待办", "已完成待办", "code block"] {
            if !saved.contains(needle) { problems.append("落盘缺少「\(needle)」") }
        }

        Self.log("[selftest] 阶段5 · 往返幂等性")
        guard let ed = NoteWindowManager.shared.editor(for: Self.selftestID) else {
            finish(ok: false, reason: "拿不到编辑器实例"); return
        }
        ed.load(markdown: saved)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.stage6() }
    }

    private func stage6() {
        guard !finished else { return }
        guard let ed = NoteWindowManager.shared.editor(for: Self.selftestID) else {
            finish(ok: false, reason: "拿不到编辑器实例"); return
        }
        ed.requestExport()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            NoteStore.shared.flush()
            let second = NoteStore.shared.load(Self.selftestID)
            let stable = (second == self.firstPass)
            Self.log("[selftest] 幂等: \(stable ? "一致 ✅" : "不一致 ⚠️")")
            if !stable { self.problems.append("Markdown 往返非幂等") }
            self.stage7()
        }
    }

    /// M1 新增：图片粘贴完整链路（JS 构造 File → Swift 落盘 → floatnotes:// 取回）
    private func stage7() {
        guard !finished else { return }
        Self.log("[selftest] 阶段7 · 图片粘贴链路")
        guard let ed = NoteWindowManager.shared.editor(for: Self.selftestID) else {
            finish(ok: false, reason: "拿不到编辑器实例"); return
        }
        ed.evaluate("window.FloatNotes._startImageTest('\(Self.tinyPNG)','image/png');") { _ in
            self.pollImageResult(attempt: 0)
        }
    }

    private func pollImageResult(attempt: Int) {
        guard !finished else { return }
        guard let ed = NoteWindowManager.shared.editor(for: Self.selftestID) else {
            finish(ok: false, reason: "拿不到编辑器实例"); return
        }
        if attempt > 40 {
            problems.append("图片链路超时（12 秒无结果）")
            stage8(); return
        }
        ed.evaluate("window.__fnProbe ? JSON.stringify(window.__fnProbe) : 'null'") { [weak self] raw in
            guard let self else { return }
            guard let s = raw as? String, s != "null",
                  let d = s.data(using: .utf8),
                  let outer = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  (outer["done"] as? Bool) == true,
                  let value = outer["value"] as? String else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.pollImageResult(attempt: attempt + 1)
                }
                return
            }

            Self.log("[selftest] 图片链路: \(value)")
            if let vd = value.data(using: .utf8),
               let o = try? JSONSerialization.jsonObject(with: vd) as? [String: Any],
               (o["ok"] as? Bool) == true {
                Self.log("[selftest] 附件经 floatnotes:// 加载成功，尺寸 \(o["width"] ?? "?")×\(o["height"] ?? "?")")
                if let fn = o["filename"] as? String { NoteStore.shared.deleteAttachment(fn) }
            } else {
                self.problems.append("图片粘贴链路失败: \(value)")
            }
            self.stage8()
        }
    }

    /// M1 新增：设置联动 + 全部收起
    private func stage8() {
        guard !finished else { return }
        Self.log("[selftest] 阶段8 · 设置与收起")

        Settings.shared.coverMenuBar = true
        let lvl1 = NoteWindowManager.shared.currentLevel
        Settings.shared.coverMenuBar = false
        let lvl2 = NoteWindowManager.shared.currentLevel
        Self.log("[selftest] 层级设置: cover=true→\(lvl1.rawValue) / false→\(lvl2.rawValue)")
        if lvl1 != .statusBar { problems.append("coverMenuBar=true 未切到 statusBar") }
        if lvl2 != .floating { problems.append("coverMenuBar=false 未切回 floating") }

        NoteWindowManager.shared.collapseAll(force: true)
        let collapsedH = NoteWindowManager.shared.panel(for: Self.selftestID)?.frame.height ?? 0
        NoteWindowManager.shared.collapseAll(force: false)
        let expandedH = NoteWindowManager.shared.panel(for: Self.selftestID)?.frame.height ?? 0
        Self.log("[selftest] 全部收起: 收起高=\(Int(collapsedH)) 展开高=\(Int(expandedH))")
        if collapsedH < 1 || collapsedH >= expandedH {
            problems.append("全部收起未生效 (\(Int(collapsedH)) → \(Int(expandedH)))")
        }

        stage9()
    }

    /// M1 新增：多窗口内存量化
    private func stage9() {
        guard !finished else { return }
        Self.log("[selftest] 阶段9 · 多窗口内存量化")
        for i in 1...4 { NoteWindowManager.shared.open("性能测试-\(i)", focus: false) }

        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            guard let self else { return }
            Perf.sample(seconds: 2.0) { avg, peak, last in
                let n = NoteWindowManager.shared.openCount
                Self.log(String(format: "[selftest] 内存: %ld 窗口 | 基线 %.1f MB | 平均 %.1f MB | 峰值 %.1f MB",
                                n, self.baselineMB, avg, peak))
                let perWindow = (last - self.baselineMB) / Double(max(1, n))
                Self.log(String(format: "[selftest] 每窗口增量约 %.1f MB（含 WebView）", perWindow))
                self.cleanupPerfNotes()
                self.stage10()
            }
        }
    }

    private func cleanupPerfNotes() {
        for i in 1...4 {
            let id = "性能测试-\(i)"
            NoteWindowManager.shared.close(id)
            NoteStore.shared.delete(id)
        }
    }

    // MARK: M2 检查

    private func stage10() {
        guard !finished else { return }
        Self.log("[selftest] 阶段10 · M2 功能检查")

        // A. 划词捕获 → 笔记格式化（纯函数，不需要系统权限）
        let sample = CapturedSelection(
            text: "深度学习需要大量数据\n第二行内容",
            sourceApp: "Safari",
            sourceTitle: "Attention Is All You Need",
            sourceURL: "https://arxiv.org/abs/1706.03762",
            method: "AX"
        )
        let md = SelectionNote.markdown(for: sample)
        Self.log("[selftest] 划词结果:\n\(md)")
        if !md.contains("> 深度学习需要大量数据") { problems.append("划词：引用块缺失") }
        if !md.contains("> 第二行内容") { problems.append("划词：多行未逐行加引用前缀") }
        if !md.contains("https://arxiv.org/abs/1706.03762") { problems.append("划词：来源 URL 缺失") }
        if !md.contains("Attention Is All You Need") { problems.append("划词：来源标题缺失") }

        let title = SelectionNote.noteTitle(for: sample)
        if title.contains("/") || title.contains(":") { problems.append("划词：标题未做文件名合法化") }
        Self.log("[selftest] 笔记标题 = \(title)")

        // B. 全局搜索
        let hits = NoteSearch.search("待办")
        Self.log("[selftest] 搜索「待办」命中 \(hits.count) 条；搜索「绝不存在的词」命中 \(NoteSearch.search("绝不存在的词xyz").count) 条")
        if hits.isEmpty { problems.append("搜索：应该能命中自检笔记") }
        if !NoteSearch.search("绝不存在的词xyz").isEmpty { problems.append("搜索：无关词不该有结果") }

        // C. 附件回收（试运行）
        let gc = AttachmentGC.collect(dryRun: true)
        Self.log("[selftest] 附件回收(dry): 笔记 \(gc.scannedNotes) 篇 / 附件 \(gc.totalAttachments) 个 / 孤儿 \(gc.removed) 个")
        if gc.scannedNotes < 1 { problems.append("附件回收：扫描不到笔记") }

        // D. 应用辅助功能权限 + 无选区时的健壮性
        Self.log("[selftest] 辅助功能权限 = \(SelectionCapture.isTrusted)")
        let policyName: String
        switch NSApp.activationPolicy() {
        case .regular: policyName = "regular（有 Dock 图标）"
        case .accessory: policyName = "accessory（纯菜单栏）"
        default: policyName = "其他"
        }
        Self.log("[selftest] 激活策略 = \(policyName)；S3 焦点检查是在此策略下做的")
        let captured = SelectionCapture.capture()
        Self.log("[selftest] 当前选区捕获 = \(captured == nil ? "无选区（正常）" : "抓到 \(captured!.text.count) 字")")

        stage11()
    }

    /// 外部改动同步：直接写文件模拟 Obsidian 修改，验证打开的窗口会刷新
    private func stage11() {
        guard !finished else { return }
        Self.log("[selftest] 阶段11 · 外部改动同步")

        let id = "外部同步测试"
        let url = NoteStore.shared.url(for: id)
        try? "# v1 原始内容\n\n来自外部编辑器".write(to: url, atomically: true, encoding: .utf8)

        NoteWindowManager.shared.open(id, focus: false)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            // 模拟外部再改一次
            try? "# v2 已被外部修改\n\n来自 Obsidian".write(to: url, atomically: true, encoding: .utf8)
            NoteWindowManager.shared.reloadFromDisk([id])

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard let ed = NoteWindowManager.shared.editor(for: id) else {
                    self.problems.append("外部同步：拿不到编辑器")
                    self.stage12(); return
                }
                ed.evaluate("document.querySelector('.bn-editor')?.innerText || ''") { text in
                    let t = (text as? String) ?? ""
                    let ok = t.contains("v2")
                    let preview = String(t.prefix(40)).replacingOccurrences(of: "\n", with: " ")
                    Self.log("[selftest] 外部同步后编辑器内容 = \(preview)")
                    if !ok { self.problems.append("外部同步：编辑器未刷新到 v2") }
                    self.stage12()
                }
            }
        }
    }

    /// 导出链路：编辑器 → HTML → RTF
    private func stage12() {
        guard !finished else { return }
        Self.log("[selftest] 阶段12 · 导出链路")
        NoteWindowManager.shared.requestHTML(for: Self.selftestID) { [weak self] html in
            guard let self else { return }
            guard let html, !html.isEmpty else {
                self.problems.append("导出：拿不到 HTML")
                self.cleanupM2Notes(); self.finish(ok: false, reason: self.problems.joined(separator: "; ")); return
            }

            let plain = NoteExporter.plainText(fromHTML: html) ?? ""
            let rtf = NoteExporter.rtfData(fromHTML: html)
            Self.log("[selftest] HTML \(html.count) 字符 → 纯文本 \(plain.count) 字符，RTF \(rtf?.count ?? 0) 字节")

            if !html.lowercased().contains("<") { self.problems.append("导出：HTML 结构异常") }
            if plain.isEmpty { self.problems.append("导出：纯文本为空") }
            if (rtf?.count ?? 0) < 50 { self.problems.append("导出：RTF 转换失败") }
            if !plain.contains("加粗") { self.problems.append("导出：正文内容丢失") }

            self.stage13()
        }
    }

    private func cleanupM2Notes() {
        for id in ["外部同步测试", Self.selftestID] {
            NoteWindowManager.shared.close(id)
            NoteStore.shared.delete(id)
            try? FileManager.default.removeItem(at: NoteStore.shared.url(for: id))
        }
    }

    // MARK: M3 检查

    /// 自检会临时改设置，必须在**所有退出路径**上还原，
    /// 包括超时和失败——不然用户会发现自己的偏好被悄悄改掉了。
    private var settingsBackup: [String: Any] = [:]
    private var ballFrameBackup: String?

    private func backupSettings() {
        settingsBackup = [
            "showFloatingBall": Settings.shared.showFloatingBall,
            "coverMenuBar": Settings.shared.coverMenuBar,
            "noteFontFamily": Settings.shared.noteFontFamily,
            "noteFontSize": Settings.shared.noteFontSize,
        ]
        ballFrameBackup = UserDefaults.standard.string(forKey: "ballFrame")
    }

    private func restoreSettings() {
        if let v = settingsBackup["showFloatingBall"] as? Bool { Settings.shared.showFloatingBall = v }
        if let v = settingsBackup["coverMenuBar"] as? Bool { Settings.shared.coverMenuBar = v }
        if let v = settingsBackup["noteFontFamily"] as? String { Settings.shared.noteFontFamily = v }
        if let v = settingsBackup["noteFontSize"] as? Double { Settings.shared.noteFontSize = v }
        if let f = ballFrameBackup {
            UserDefaults.standard.set(f, forKey: "ballFrame")
        }
        if let f = ballFrameBackup {
            let r = NSRectFromString(f)
            if r.width > 10 { ballPanel?.setFrame(r, display: false) }
        }
    }

    private var originalFontFamily: String?
    private var originalFontSize: Double?
    private var dailyEntryBaseline = 0

    private func stage13() {
        guard !finished else { return }
        Self.log("[selftest] 阶段13 · M3 字体与今日笔记")

        originalFontFamily = Settings.shared.noteFontFamily
        originalFontSize = Settings.shared.noteFontSize

        // A. 字体目录
        let keys = FontCatalog.all.map(\.key)
        Self.log("[selftest] 字体选项 \(keys.count) 个：\(FontCatalog.all.map(\.label).joined(separator: " / "))")
        if keys.count < 6 { problems.append("字体选项过少（\(keys.count)）") }
        for need in ["songti", "kaiti", "yuanti", "mono"] {
            if !keys.contains(need) { problems.append("缺少字体选项 \(need)") }
        }
        if FontCatalog.css(for: "songti").isEmpty { problems.append("字体 CSS 为空") }

        // B. 字体真的作用到编辑器上（读 WebKit 的计算样式）
        Settings.shared.noteFontFamily = "kaiti"
        guard let ed = NoteWindowManager.shared.editor(for: Self.selftestID) else {
            problems.append("字体检查：拿不到编辑器")
            stage13c(); return
        }
        // 同时验证「字体」和「字号」都真的作用到了编辑器上
        ed.setFontFamily(FontCatalog.css(for: "kaiti"))
        ed.setFontSize(21)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            let js = """
            (() => {
              const el = document.querySelector('.bn-editor');
              if (!el) return 'null';
              const cs = getComputedStyle(el);
              return JSON.stringify({ family: cs.fontFamily, size: cs.fontSize });
            })()
            """
            ed.evaluate(js) { result in
                let raw = (result as? String) ?? "null"
                Self.log("[selftest] 编辑器计算样式 = \(raw)")
                guard raw != "null", let d = raw.data(using: .utf8),
                      let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                    self.problems.append("拿不到编辑器计算样式")
                    self.stage13c(); return
                }
                let family = (o["family"] as? String) ?? ""
                let size = (o["size"] as? String) ?? ""
                if !family.lowercased().contains("kaiti") {
                    self.problems.append("字体未生效（实际=\(family)）")
                }
                if size != "21px" {
                    self.problems.append("字号未生效（实际=\(size)，期望 21px）")
                }
                self.stage13c()
            }
        }
    }

    /// C. 今日笔记：文件追加路径
    private func stage13c() {
        guard !finished else { return }
        let id = DailyNote.todayID()
        NoteStore.shared.ensureNote(id)

        let sel = CapturedSelection(
            text: "测试摘录第一行\n测试摘录第二行",
            sourceApp: "Safari",
            sourceTitle: "测试文章标题",
            sourceURL: "https://example.com/article-a",
            method: "AX"
        )
        let entry = DailyNote.entry(for: sel)
        Self.log("[selftest] 今日笔记条目格式:\n\(entry)")

        let ok = NoteStore.shared.appendText(entry, to: id)
        let content = NoteStore.shared.load(id)
        dailyEntryBaseline = DailyNote.entryCount(content)

        Self.log("[selftest] 今日笔记 \(id)：写入\(ok ? "成功" : "失败")，共 \(dailyEntryBaseline) 条")
        if !ok { problems.append("今日笔记写入失败") }
        if !content.contains("测试摘录第一行") { problems.append("今日笔记缺正文") }
        if !content.contains("https://example.com/article-a") { problems.append("今日笔记缺来源链接") }
        if !content.contains("## ") { problems.append("今日笔记缺时间小标题") }
        if dailyEntryBaseline < 1 { problems.append("今日笔记条目计数为 0") }

        // D. 今日笔记打开后再追加（走编辑器路径）
        NoteWindowManager.shared.open(id, focus: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self else { return }
            let sel2 = CapturedSelection(
                text: "第二条走编辑器路径",
                sourceApp: "Chrome",
                sourceTitle: "第二篇文章",
                sourceURL: "https://example.com/article-b",
                method: "AX"
            )
            DailyNote.append(entry: DailyNote.entry(for: sel2)) { rid in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    let c2 = NoteStore.shared.load(id)
                    let n2 = DailyNote.entryCount(c2)
                    Self.log("[selftest] 经编辑器追加后共 \(n2) 条（追加前 \(self.dailyEntryBaseline)）")
                    if n2 <= self.dailyEntryBaseline {
                        self.problems.append("经编辑器追加未生效（\(self.dailyEntryBaseline) → \(n2)）")
                    }
                    if !c2.contains("第二条走编辑器路径") {
                        self.problems.append("编辑器追加内容未落盘")
                    }
                    self.stage13e()
                }
            }
        }
    }

    /// E. 轻量提示面板能不能真的显示出来（且不抢焦点）
    private func stage13e() {
        guard !finished else { return }
        let before = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let me = NSRunningApplication.current.localizedName ?? "?"
        let wasAlreadyMine = (before == me)
        CaptureToast.shared.show("自检提示")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            let showing = CaptureToast.shared.isShowing
            let after = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            let stole = (after == me) && !wasAlreadyMine
            Self.log("[selftest] 提示面板可见 = \(showing)，前台 \(before) → \(after)（本App=\(me)）")
            if !showing { self.problems.append("捕获提示面板未显示") }
            if stole { self.problems.append("提示面板把本 App 激活了，会打断阅读") }
            CaptureToast.shared.hide()
            self.cleanupM3()
            self.stage14()
        }
    }

    private func cleanupM3() {
        if let original = originalFontFamily { Settings.shared.noteFontFamily = original }
        if let original = originalFontSize { Settings.shared.noteFontSize = original }
    }

    /// 自检造出来的笔记全部清掉
    private func cleanupAllTestNotes() {
        let ids = [DailyNote.todayID(), "自检主题笔记",
                   Self.selftestID, "外部同步测试"]
        for id in ids {
            NoteWindowManager.shared.close(id)
            NoteStore.shared.delete(id)
            try? FileManager.default.removeItem(at: NoteStore.shared.url(for: id))
        }
    }

    // MARK: M4 检查

    private func stage14() {
        guard !finished else { return }
        Self.log("[selftest] 阶段14 · M4 今日笔记整理")

        let id = DailyNote.todayID()
        // 从干净状态开始：阶段13 也在今日笔记里留过东西，不清掉会串味
        NoteStore.shared.delete(id)
        NoteStore.shared.ensureNote(id)
        NoteStore.shared.delete("自检主题笔记")

        // 造三条摘录（其中一条没有来源链接）
        let samples = [
            CapturedSelection(text: "第一条摘录内容", sourceApp: "Safari",
                              sourceTitle: "文章甲", sourceURL: "https://example.com/a", method: "AX"),
            CapturedSelection(text: "第二条摘录内容", sourceApp: "Chrome",
                              sourceTitle: "文章乙", sourceURL: "https://example.com/b", method: "AX"),
            CapturedSelection(text: "第三条摘录内容", sourceApp: "Preview",
                              sourceTitle: "论文丙", sourceURL: nil, method: "AX"),
        ]
        for s in samples {
            NoteStore.shared.appendText(DailyNote.entry(for: s), to: id)
        }

        // A. 解析
        let parsed = DailyNoteTriage.parse(NoteStore.shared.load(id))
        Self.log("[selftest] 解析出 \(parsed.entries.count) 条：")
        for e in parsed.entries {
            Self.log("   · [\(e.time)] \(e.title) | url=\(e.url ?? "无") | \(e.preview)")
        }
        if parsed.entries.count != 3 { problems.append("解析条目数不对（\(parsed.entries.count)，期望 3）") }
        if parsed.entries.first?.url == nil { problems.append("未提取到来源 URL") }
        if parsed.entries.last?.url != nil { problems.append("无链接的条目不该解析出 URL") }
        if parsed.entries.contains(where: { $0.time.isEmpty }) { problems.append("未提取到时间") }
        if parsed.entries.contains(where: { $0.preview.isEmpty }) { problems.append("未生成预览文本") }

        // B. 归档前两条到主题笔记
        let target = "自检主题笔记"
        NoteStore.shared.ensureNote(target)
        let toMove = Array(parsed.entries.prefix(2))
        let result = DailyNoteTriage.archive(
            entries: toMove, from: id, to: target,
            dateString: DailyNote.dateString()
        )

        let dailyAfter = NoteStore.shared.load(id)
        let targetAfter = NoteStore.shared.load(target)
        let remain = DailyNoteTriage.parse(dailyAfter).entries.count
        let received = DailyNoteTriage.parse(targetAfter).entries.count

        Self.log("[selftest] 归档 \(result.moved) 条 → \(target)；今日笔记剩 \(remain) 条，目标笔记收到 \(received) 条")
        if result.moved != 2 { problems.append("归档数量不对（\(result.moved)）") }
        if remain != 1 { problems.append("今日笔记应剩 1 条，实际 \(remain)") }
        if !targetAfter.contains("第一条摘录内容") || !targetAfter.contains("第二条摘录内容") {
            problems.append("目标笔记缺少归档内容")
        }
        if targetAfter.contains("第三条摘录内容") { problems.append("未勾选的条目被误归档") }
        let ds = DailyNote.dateString()
        if !targetAfter.contains("## \(ds) ") { problems.append("归档后标题未带上日期") }
        if !targetAfter.contains("https://example.com/a") { problems.append("归档后丢失来源链接") }

        // C. 删除剩下的那条
        let rest = DailyNoteTriage.parse(dailyAfter).entries
        let cleaned = DailyNoteTriage.remove(entries: rest, from: dailyAfter)
        NoteStore.shared.replaceAll(id, with: cleaned)
        let finalCount = DailyNoteTriage.parse(NoteStore.shared.load(id)).entries.count
        Self.log("[selftest] 删除剩余条目后今日笔记剩 \(finalCount) 条")
        if finalCount != 0 { problems.append("删除未清空（剩 \(finalCount)）") }

        // 注意：这里不能清场 —— 后面的阶段还要用那个笔记窗口。
        // 清场统一放到 finish() 里，这样失败/超时路径也能清干净。
        stage15()
    }

    // MARK: 悬浮球显隐检查

    private func stage15() {
        guard !finished else { return }
        Self.log("[selftest] 阶段15 · 悬浮球隐藏 / 显示")

        // 菜单构建路径平时测不到，这里主动跑一遍，确认开关确实在菜单里
        let probe = NSMenu()
        menuNeedsUpdate(probe)
        let titles = probe.items.map(\.title)
        let hasToggle = titles.contains { $0.contains("悬浮球") }
        Self.log("[selftest] 菜单共 \(probe.items.count) 项，悬浮球开关存在 = \(hasToggle)")
        if !hasToggle { problems.append("菜单里缺少悬浮球开关") }
        if hidsOnDeactivateProbeMissing(probe) { problems.append("菜单缺少基础项") }

        let original = Settings.shared.showFloatingBall
        let startedVisible = ballIsVisible
        Self.log("[selftest] 初始：showFloatingBall=\(original) 实际可见=\(startedVisible)")

        // 隐藏
        Settings.shared.showFloatingBall = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            let hidden = self.ballIsVisible
            Self.log("[selftest] 设为隐藏后 → 实际可见=\(hidden)")
            if hidden { self.problems.append("悬浮球未隐藏") }

            // 再显示
            Settings.shared.showFloatingBall = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let shown = self.ballIsVisible
                Self.log("[selftest] 设回显示后 → 实际可见=\(shown)")
                if !shown { self.problems.append("悬浮球未恢复显示") }

                // 还原初始值
                Settings.shared.showFloatingBall = original
                self.stage16()
            }
        }
    }

    /// 菜单至少要有这些基础项
    private func hidsOnDeactivateProbeMissing(_ menu: NSMenu) -> Bool {
        let titles = menu.items.map(\.title)
        let needed = ["新建笔记", "搜索笔记", "今日笔记"]
        return !needed.allSatisfy { key in titles.contains { $0.contains(key) } }
    }

    // MARK: 悬浮球拖动检查

    /// 造一个合成鼠标事件。视图内部用的是注入的 mouseLocationProvider，
    /// 所以事件自带的坐标不影响结果，只为触发 mouseDown/Dragged/Up 这三个回调。
    private func syntheticMouse(_ type: NSEvent.EventType, clickCount: Int = 1) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: 0, context: nil,
                           eventNumber: 0, clickCount: clickCount, pressure: 1)
    }

    private func stage16() {
        guard !finished else { return }
        Self.log("[selftest] 阶段16 · 悬浮球拖动")
        guard let view = ballView, let panel = ballPanel, let screen = NSScreen.main else {
            problems.append("拿不到悬浮球"); finish(ok: false, reason: problems.joined(separator: "; ")); return
        }

        let originalFrame = panel.frame
        let v = screen.visibleFrame
        let size = FloatingBallPanel.ballSize

        // A. 两个「拖背景移动」开关都必须关掉，否则会和手写拖动打架
        Self.log("[selftest] 拖背景移动: panel=\(panel.isMovableByWindowBackground) view=\(view.mouseDownCanMoveWindow)")
        if panel.isMovableByWindowBackground {
            problems.append("面板仍开着 isMovableByWindowBackground，会和手写拖动冲突")
        }
        if view.mouseDownCanMoveWindow {
            problems.append("视图仍允许拖背景移动，会和手写拖动冲突")
        }

        // B. 自由拖动：放到屏幕正中，模拟拖 (+80, +60)
        panel.setFrame(NSRect(x: v.midX - size / 2, y: v.midY - size / 2,
                              width: size, height: size), display: false)
        let before = panel.frame.origin

        var fake = NSPoint(x: 1000, y: 1000)
        view.mouseLocationProvider = { fake }
        view.mouseDown(with: syntheticMouse(.leftMouseDown) ?? NSEvent())
        fake = NSPoint(x: 1080, y: 1060)
        view.mouseDragged(with: syntheticMouse(.leftMouseDragged) ?? NSEvent())

        let after = panel.frame.origin
        let dx = after.x - before.x, dy = after.y - before.y
        Self.log(String(format: "[selftest] 拖动位移 = (%.0f, %.0f)，期望 (80, 60)", dx, dy))
        if abs(dx - 80) > 2 || abs(dy - 60) > 2 {
            problems.append(String(format: "拖动位移不对（%.0f, %.0f）", dx, dy))
        }

        // C. 在屏幕中间松手 → 不该被拽回边缘
        view.mouseUp(with: syntheticMouse(.leftMouseUp) ?? NSEvent())
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            let dropped = panel.frame.origin
            let distToRight = v.maxX - panel.frame.maxX
            let distToLeft = panel.frame.minX - v.minX
            Self.log(String(format: "[selftest] 中间松手后位置 x=%.0f（距左 %.0f / 距右 %.0f）",
                            dropped.x, distToLeft, distToRight))
            if distToRight < FloatingBallView.snapThreshold || distToLeft < FloatingBallView.snapThreshold {
                self.problems.append("在屏幕中间松手却被吸附到了边缘")
            }

            // D. 靠近右边缘 → 应该磁吸（用同步的 finishDrag，避免动画影响读数）
            panel.setFrame(NSRect(x: v.maxX - size - 20, y: v.midY,
                                  width: size, height: size), display: false)
            view.finishDrag(animated: false)
            let gapRight = v.maxX - panel.frame.maxX
            Self.log(String(format: "[selftest] 靠近右边缘时距右 %.0f（阈值 %.0f，吸附后应 ≈ %.0f）",
                            gapRight, FloatingBallView.snapThreshold, FloatingBallView.snapMargin))
            if abs(gapRight - FloatingBallView.snapMargin) > 3 {
                self.problems.append(String(format: "靠近右边缘没有磁吸（距右 %.0f）", gapRight))
            }

            // E. 靠近左边缘 → 也应该磁吸
            panel.setFrame(NSRect(x: v.minX + 20, y: v.midY,
                                  width: size, height: size), display: false)
            view.finishDrag(animated: false)
            let gapLeft = panel.frame.minX - v.minX
            Self.log(String(format: "[selftest] 靠近左边缘时距左 %.0f（应 ≈ %.0f）",
                            gapLeft, FloatingBallView.snapMargin))
            if abs(gapLeft - FloatingBallView.snapMargin) > 3 {
                self.problems.append(String(format: "靠近左边缘没有磁吸（距左 %.0f）", gapLeft))
            }

            // F. 跑到屏幕外 → 应该被夹回来
            panel.setFrame(NSRect(x: v.maxX + 500, y: v.minY - 500,
                                  width: size, height: size), display: false)
            view.finishDrag(animated: false)
            let inside = v.contains(panel.frame)
            Self.log("[selftest] 拖出屏幕后被夹回可见区域 = \(inside)")
            if !inside { self.problems.append("拖出屏幕后没有被夹回") }

            // 还原位置
            panel.setFrame(originalFrame, display: false)
            UserDefaults.standard.set(NSStringFromRect(originalFrame), forKey: "ballFrame")
            self.stage17()
        }
    }

    // MARK: 内容区拖动窗口检查

    private func stage17() {
        guard !finished else { return }
        Self.log("[selftest] 阶段17 · 按住内容区空白拖动窗口")

        guard let ed = NoteWindowManager.shared.editor(for: Self.selftestID),
              let panel = NoteWindowManager.shared.panel(for: Self.selftestID) else {
            problems.append("拿不到笔记窗口")
            finish(ok: false, reason: problems.joined(separator: "; ")); return
        }

        // A0. 事件监听有没有真的装上 —— 逻辑对但监听没装上，功能照样是死的
        Self.log("[selftest] 拖动事件监听已安装 = \(dragMonitor != nil)")
        if dragMonitor == nil {
            problems.append("拖动事件监听没有安装成功")
        }

        // A. 空白判定：JS 侧命中测试
        let js = #"""
        (() => {
          const el = document.querySelector('.tiptap, .ProseMirror, .bn-editor');
          if (!el) return 'no editor';
          const r = el.getBoundingClientRect();
          return JSON.stringify({
            leftPad:   window.FloatNotes._testBlankAt(r.left + 6, r.top + r.height * 0.5),
            bottomPad: window.FloatNotes._testBlankAt(r.left + r.width / 2, r.bottom - 8),
            onText:    window.FloatNotes._testBlankAt(r.left + 30, r.top + 20),
          });
        })()
        """#
        ed.evaluate(js) { [weak self] result in
            guard let self else { return }
            let raw = (result as? String) ?? "null"
            Self.log("[selftest] 空白判定 = \(raw)")

            if let d = raw.data(using: .utf8),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                if (o["leftPad"] as? Bool) != true { self.problems.append("左侧内边距没被判定为空白") }
                if (o["bottomPad"] as? Bool) != true { self.problems.append("底部空区没被判定为空白") }
                if (o["onText"] as? Bool) != false { self.problems.append("正文文字上被误判为空白") }
            } else {
                self.problems.append("空白判定无返回")
            }

            self.stage17b(panel: panel)
        }
    }

    /// B. 拖动位移：绝对值定位 + 起拖阈值
    private func stage17b(panel: NotePanel) {
        // ★ 先把窗口摆到屏幕正中再测。否则往「上」拖会撞上
        //   NSWindow.constrainFrameRect（标题栏不许跑到菜单栏上面），
        //   实测位移会被系统截短，看起来像 bug 其实是正常的系统行为。
        if let screen = NSScreen.main {
            let v = screen.visibleFrame
            let size = panel.frame.size
            panel.setFrame(NSRect(x: v.midX - size.width / 2,
                                  y: v.midY - size.height / 2,
                                  width: size.width, height: size.height),
                           display: false)
        }

        let start = NSPoint(x: 1234, y: 567)
        let originBefore = panel.frame.origin

        beginContentDrag(panel: panel, at: start)

        // 1px 位移属于单击，不该移动窗口，也不该吞事件
        let tiny = updateContentDrag(to: NSPoint(x: start.x + 1, y: start.y + 1))
        let afterTiny = panel.frame.origin
        Self.log("[selftest] 1px 位移：接管=\(tiny) 窗口位移=(\(afterTiny.x - originBefore.x), \(afterTiny.y - originBefore.y))")
        if tiny { problems.append("1px 位移就被当成拖动，会误伤点选") }
        if afterTiny != originBefore { problems.append("1px 位移不该移动窗口") }

        // 越过阈值后应精确跟随（往右下拖，避开系统约束）
        let took = updateContentDrag(to: NSPoint(x: start.x + 90, y: start.y - 40))
        let after = panel.frame.origin
        let dx = after.x - originBefore.x, dy = after.y - originBefore.y
        Self.log(String(format: "[selftest] 越过阈值后：接管=%@ 位移=(%.0f, %.0f)，期望 (90, -40)",
                        took ? "是" : "否", dx, dy))
        if !took { problems.append("越过阈值后没有接管拖动") }
        if abs(dx - 90) > 2 || abs(dy + 40) > 2 {
            problems.append(String(format: "窗口位移不对（%.0f, %.0f），期望 (90, -40)", dx, dy))
        }

        endContentDrag()
        panel.setFrame(NSRect(origin: originBefore, size: panel.frame.size), display: false)

        finish(ok: problems.isEmpty, reason: problems.joined(separator: "; "))
    }

    private func finish(ok: Bool, reason: String) {
        guard !finished else { return }
        finished = true

        // 无论走哪条路（成功 / 断言失败 / 超时）都要把用户设置还原、把测试笔记删掉
        restoreSettings()
        cleanupAllTestNotes()

        // ★ 关键：UserDefaults 的写入是异步的，而下面用的是 exit()，
        //   不走 NSApplication 的正常退出流程。不强制落盘的话，
        //   还原后的值还没写进磁盘进程就没了，磁盘上会残留测试中途写的值。
        UserDefaults.standard.synchronize()

        Self.log("[selftest] 窗口诊断:\n\(NoteWindowManager.shared.diagnostics())")
        Self.log("[selftest] \(Perf.report(windows: NoteWindowManager.shared.openCount))")
        if !ok { Self.log("[selftest] ✗ 失败原因: \(reason)") }
        Self.log("[selftest] \(ok ? "PASS ✅" : "FAIL ❌")")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(ok ? 0 : 1) }
    }

    static func log(_ msg: String) {
        FileHandle.standardError.write(("[FloatNotes] " + msg + "\n").data(using: .utf8)!)
    }
}
