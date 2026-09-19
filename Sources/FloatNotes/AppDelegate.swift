import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem?
    private var ballPanel: FloatingBallPanel?
    private var ballView: FloatingBallView?
    private var hotKeys: [GlobalHotKey] = []
    private var watcher: NoteWatcher?

    private var isSelfTest = false

    // MARK: - 主菜单
    //
    // 纯代码创建的 App 默认没有主菜单。而 macOS 的 ⌘C / ⌘V / ⌘X / ⌘A / ⌘Z
    // 并不是系统自动处理的 —— 它们靠「编辑」菜单里那些标准 selector
    // （copy: / paste: …）沿响应链转发。没有这个菜单，剪贴板快捷键
    // 就完全没有入口，WKWebView 永远收不到 paste:，表现就是「粘不进去」。

    func applicationWillFinishLaunching(_ notification: Notification) {
        buildMainMenu()
    }

    private func buildMainMenu() {
        func item(_ title: String, _ action: String, _ key: String = "",
                  _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: Selector(action), keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            return i
        }

        let main = NSMenu()

        // ── 应用菜单 ──
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(item("关于悬浮笔记", "orderFrontStandardAboutPanel:", ""))
        appMenu.addItem(.separator())
        appMenu.addItem(item("隐藏悬浮笔记", "hide:", "h"))
        appMenu.addItem(.separator())
        appMenu.addItem(item("退出悬浮笔记", "terminate:", "q"))
        main.addItem(appItem)

        // ── 编辑菜单（关键：剪贴板快捷键的入口）──
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editItem.submenu = editMenu
        editMenu.addItem(item("撤销", "undo:", "z"))
        editMenu.addItem(item("重做", "redo:", "z", [.command, .shift]))
        editMenu.addItem(.separator())
        editMenu.addItem(item("剪切", "cut:", "x"))
        editMenu.addItem(item("复制", "copy:", "c"))
        editMenu.addItem(item("粘贴", "paste:", "v"))
        editMenu.addItem(item("删除", "delete:", ""))
        editMenu.addItem(.separator())
        editMenu.addItem(item("全选", "selectAll:", "a"))
        main.addItem(editItem)

        // ── 窗口菜单 ──
        let winItem = NSMenuItem()
        let winMenu = NSMenu(title: "窗口")
        winItem.submenu = winMenu
        winMenu.addItem(item("最小化", "performMiniaturize:", "m"))
        winMenu.addItem(item("关闭", "performClose:", "w"))
        main.addItem(winItem)

        NSApp.mainMenu = main
    }

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

        // --perm-check <输出文件>：把屏幕录制权限的判定结果写出来并退出。
        // 用来区分「从终端直接跑（会继承终端的权限身份）」和「正常启动」两种情况。
        if let i = CommandLine.arguments.firstIndex(of: "--perm-check") {
            let out = (i + 1 < CommandLine.arguments.count)
                ? CommandLine.arguments[i + 1] : "/tmp/floatnotes-perm.txt"
            let trusted = CGPreflightScreenCaptureAccess()
            var report = """
            时间: \(Date())
            bundle: \(Bundle.main.bundlePath)
            bundleID: \(Bundle.main.bundleIdentifier ?? "?")
            CGPreflightScreenCaptureAccess: \(trusted)
            父进程 PID: \(getppid())
            """
            // 自己的 cdhash —— TCC 对 ad-hoc 签名就是按它认的
            if let exe = Bundle.main.executableURL {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
                p.arguments = ["-dvvv", exe.path]
                let pipe = Pipe()
                p.standardError = pipe
                try? p.run()
                p.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? ""
                for line in text.split(separator: "\n") where line.contains("CDHash=") || line.contains("Signature=") {
                    report += "\n\(line)"
                }
            }
            try? report.write(to: URL(fileURLWithPath: out), atomically: true, encoding: .utf8)
            exit(trusted ? 0 : 1)
        }

        // --save-probe <报告文件>：验证「笔记到底能不能写进 ~/Documents」。
        // ★ 这个探针必须用 `open -n --args` 启动，不能直接从终端跑：
        //   从终端跑会继承终端的磁盘授权，测出来一切正常，而用户双击打开的 App
        //   是另一个身份。屏幕录制那次就是被这个坑骗过一回，磁盘权限同理。
        if let i = CommandLine.arguments.firstIndex(of: "--save-probe") {
            let out = (i + 1 < CommandLine.arguments.count)
                ? CommandLine.arguments[i + 1] : "/tmp/floatnotes-save.txt"
            let fm = FileManager.default
            var report = "时间: \(Date())\n"
            report += "父进程 PID: \(getppid())\n"
            report += "bundle: \(Bundle.main.bundlePath)\n"
            let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
            report += "Documents: \(docs.path)（可写=\(fm.isWritableFile(atPath: docs.path))）\n"
            let root = NoteStore.shared.root
            report += "笔记根目录: \(root.path)\n"
            report += "  存在=\(fm.fileExists(atPath: root.path)) 可写=\(fm.isWritableFile(atPath: root.path))\n"
            if let attrs = try? fm.attributesOfItem(atPath: root.path) {
                report += "  权限=\((attrs[.posixPermissions] as? NSNumber)?.stringValue ?? "?") "
                report += "属主=\(attrs[.ownerAccountName] as? String ?? "?")\n"
            }
            if let listing = try? fm.contentsOfDirectory(atPath: root.path) {
                report += "  目录内容(\(listing.count)): \(listing.prefix(8).joined(separator: ", "))\n"
            } else {
                report += "  目录内容: ★列不出来（很可能没有磁盘授权）\n"
            }

            // 1. 裸写一个文件 —— 绕开 NoteStore 的错误吞噬，看到真正的 error
            let probeID = "保存探针"
            let dest = NoteStore.shared.url(for: probeID)
            let tmp = dest.deletingLastPathComponent().appendingPathComponent(".probe.tmp")
            do {
                try "probe".write(to: tmp, atomically: false, encoding: .utf8)
                _ = try fm.replaceItemAt(dest, withItemAt: tmp)
                report += "裸写测试: 成功\n"
            } catch {
                report += "裸写测试: ★失败 → \(error)\n"
            }

            // 2. 走真正的保存链路
            let n = UUID().uuidString.prefix(6)
            let id = "保存探针\(n)"
            let ok = NoteStore.shared.appendText("探针内容 \(n)", to: id)
            let back = NoteStore.shared.load(id)
            report += "NoteStore 保存返回: \(ok)\n"
            report += "从磁盘读回: 「\(back.trimmingCharacters(in: .whitespacesAndNewlines))」\n"
            report += "文件真的在盘上: \(fm.fileExists(atPath: NoteStore.shared.url(for: id).path))\n"
            NoteStore.shared.delete(id)
            try? fm.removeItem(at: dest)

            try? report.write(to: URL(fileURLWithPath: out), atomically: true, encoding: .utf8)
            exit(0)
        }

        // --paste-probe：走完整的「粘贴图片 → 自动保存 → 读 md」链路
        if CommandLine.arguments.contains("--paste-probe") {
            runPasteProbe()
            return
        }

        // --new-note-probe <报告文件>：完整走一遍「新建笔记 → 编辑器就绪 →
        // 内容变化 → 落盘 → 读回」，回答「新建的笔记到底有没有写进磁盘」。
        // 注意 open() 是不建文件的，要等 onChange 才会写 —— 所以要验的是整条链路。
        if let i = CommandLine.arguments.firstIndex(of: "--new-note-probe") {
            let out = (i + 1 < CommandLine.arguments.count)
                ? CommandLine.arguments[i + 1] : "/tmp/floatnotes-newnote.txt"
            runNewNoteProbe(to: out)
            return
        }

        // --type-probe <报告文件>：用**真实键盘事件**打字，验证「打字 → 保存」。
        // 这个是必要的：--new-note-probe 走的是 exportNow()，程序化触发 emitChange，
        // 而真实打字靠的是 BlockNoteView 的 onChange 回调。两者不是一条路 ——
        // 用户报的正是「新建后打字，文件根本不出现」。
        if let i = CommandLine.arguments.firstIndex(of: "--type-probe") {
            let out = (i + 1 < CommandLine.arguments.count)
                ? CommandLine.arguments[i + 1] : "/tmp/floatnotes-type.txt"
            runTypeProbe(to: out)
            return
        }

        // --note-probe：诊断「滚动」与「图片进 md」两个问题
        if CommandLine.arguments.contains("--note-probe") {
            runNoteProbe()
            return
        }

        // --overlay-probe [秒]：延迟若干秒后拉一次截图遮罩，并报告它在不在当前 Space。
        // 用来排查「在别的桌面全屏时按截图，图跑到另一个桌面」这类问题。
        if let i = CommandLine.arguments.firstIndex(of: "--overlay-probe") {
            let delay = (i + 1 < CommandLine.arguments.count)
                ? (Double(CommandLine.arguments[i + 1]) ?? 6.0) : 6.0
            runOverlayProbe(after: delay)
            return
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

        // 放在 setupFloatingBall() 之前：要先还完账，球的显隐才会读对设置
        recoverInterruptedSelftest()

        NoteWindowManager.shared.onLog = { msg in Self.log(msg) }

        // 落盘失败一定要让用户看见。之前只写 NSLog，界面毫无反应，
        // 用户只会觉得「我打了半天字，文件却没保存」，也无从判断是权限还是路径问题。
        NoteStore.shared.onWriteError = { msg in
            Self.log("[store] ✗ \(msg)")
            let brief = msg.count > 46 ? String(msg.prefix(46)) + "…" : msg
            CaptureToast.shared.show(brief, accent: .systemRed)
        }
        if let pending = NoteStore.pendingWriteError {
            NoteStore.pendingWriteError = nil
            NoteStore.shared.onWriteError?(pending)
        }

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

        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev"
        Self.log("[app] 构建 \(build) · \(Bundle.main.bundlePath)")
        Self.log("[app] 屏幕录制权限 = \(ScreenCapture.hasPermission)（父进程 PID \(getppid())）")

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

        // --launch-note-probe <报告文件>：★ 这个探针**不提前 return**。
        // 要复现的正是「App 启动时自带的那个窗口」，所以必须让完整启动流程
        // （setupStatusItem / restoreSession / 会话恢复）真的跑完，
        // 再对那个窗口做打字落盘检查。提前 return 就不是那个场景了。
        var launchProbeOut: String?
        if let i = CommandLine.arguments.firstIndex(of: "--launch-note-probe") {
            launchProbeOut = (i + 1 < CommandLine.arguments.count)
                ? CommandLine.arguments[i + 1] : "/tmp/floatnotes-launch.txt"
        }

        // --cycle-probe <write|read> <报告文件>：两步实验，验「启动窗口写进去的东西
        // 下次启动还在不在」。用户报的就是「刚打开就有的那个窗口存不住」，
        // 而这必须跨一次真实的启动 / 退出才能看出来。
        var cycleProbe: (mode: String, out: String)?
        if let i = CommandLine.arguments.firstIndex(of: "--cycle-probe"),
           i + 2 < CommandLine.arguments.count {
            cycleProbe = (CommandLine.arguments[i + 1], CommandLine.arguments[i + 2])
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
            // 放在完整启动流程之后：这里才等价于「用户刚打开 App 看到的样子」
            if let out = launchProbeOut { runLaunchNoteProbe(to: out) }
            if let c = cycleProbe { runCycleProbe(mode: c.mode, to: c.out) }
        }
    }

    /// 跨一次启动/退出，验「启动自带窗口」里的内容能不能活下来。
    private func runCycleProbe(mode: String, to out: String) {
        var lines: [String] = []
        var done = false

        func finish() {
            guard !done else { return }
            done = true
            try? lines.joined(separator: "\n")
                .write(to: URL(fileURLWithPath: out), atomically: true, encoding: .utf8)
            for l in lines { Self.log("[cycle] \(l)") }
            exit(0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
            lines.append("★ 超时"); finish()
        }

        let ids = NoteWindowManager.shared.openIDs
        lines.append("模式 = \(mode)")
        lines.append("session.openNotes = \(NoteStore.shared.openNoteIDs)")
        lines.append("启动后打开的窗口 = \(ids)")
        guard let id = ids.first, let ed = NoteWindowManager.shared.editor(for: id) else {
            lines.append("★ 没有窗口或拿不到编辑器"); finish(); return
        }
        let url = NoteStore.shared.url(for: id)
        lines.append("启动窗口 id = 「\(id)」")
        lines.append("磁盘文件存在 = \(FileManager.default.fileExists(atPath: url.path))")
        lines.append("磁盘内容 = 「\(NoteStore.shared.load(id).trimmingCharacters(in: .whitespacesAndNewlines))」")

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if mode == "write" {
                ed.evaluate("""
                (() => { const el=document.querySelector('.bn-editor'); if(!el) return 'no-editor';
                  el.focus();
                  return document.execCommand('insertText', false, 'CYCLE写入标记ZZZ') ? 'ok':'failed'; })()
                """) { r in
                    lines.append("注入打字 = \(r)")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        lines.append("注入后磁盘内容 = 「\(NoteStore.shared.load(id))」")
                        // 走真实退出路径
                        NoteStore.shared.flush()
                        NoteStore.shared.rememberOpenNotes(NoteWindowManager.shared.openIDs)
                        lines.append("已按退出路径 flush + 记录会话 → \(NoteStore.shared.openNoteIDs)")
                        finish()
                    }
                }
            } else {
                ed.evaluate("document.querySelector('.bn-editor')?.innerText ?? ''") { t in
                    let shown = ((t as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    lines.append("重启后编辑器显示 = 「\(shown)」")
                    lines.append("磁盘里有标记 = \(NoteStore.shared.load(id).contains("CYCLE写入标记ZZZ"))")
                    lines.append("界面里看得见标记 = \(shown.contains("CYCLE写入标记ZZZ"))")
                    finish()
                }
            }
        }
    }

    /// 对「启动自带的那个窗口」做打字落盘检查。
    /// 用户报的正是这个窗口存不住，而新建的窗口可以。
    private func runLaunchNoteProbe(to out: String) {
        var lines: [String] = []
        var done = false
        let fm = FileManager.default

        func finish() {
            guard !done else { return }
            done = true
            try? lines.joined(separator: "\n")
                .write(to: URL(fileURLWithPath: out), atomically: true, encoding: .utf8)
            for l in lines { Self.log("[launch-probe] \(l)") }
            exit(0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            lines.append("★ 超时：30 秒没走完")
            finish()
        }

        let ids = NoteWindowManager.shared.openIDs
        lines.append("启动后打开的窗口 = \(ids)")
        guard let id = ids.first else {
            lines.append("★ 启动后一个窗口都没有")
            finish(); return
        }
        let url = NoteStore.shared.url(for: id)
        lines.append("启动窗口 id = 「\(id)」")
        lines.append("① 它的文件此刻在磁盘上 = \(fm.fileExists(atPath: url.path))")

        guard let ed = NoteWindowManager.shared.editor(for: id) else {
            lines.append("★ 拿不到该窗口的编辑器")
            finish(); return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            ed.evaluate("""
            (() => {
              const el = document.querySelector('.bn-editor');
              if (!el) return 'no-editor';
              el.focus();
              return document.execCommand('insertText', false, '启动窗口保存检查QWE') ? 'ok' : 'failed';
            })()
            """) { r in
                lines.append("② 注入打字 = \(r)")

                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    ed.evaluate("window.__fnChangeCount || 0") { n in
                        let changes = (n as? NSNumber)?.intValue ?? -1
                        let exists = fm.fileExists(atPath: url.path)
                        let onDisk = NoteStore.shared.load(id)
                        lines.append("③ onChange 触发次数 = \(changes)")
                        lines.append("④ 打字后文件存在 = \(exists)")
                        lines.append("⑤ 磁盘内容 = 「\(onDisk.trimmingCharacters(in: .whitespacesAndNewlines))」")
                        lines.append("⑥ 打字内容真的落盘 = \(onDisk.contains("启动窗口保存检查"))")
                        lines.append("⑦ 待写队列 = \(NoteStore.shared.pendingWriteCount)")
                        lines.append("⑧ 该笔记在 restorableNotes 里 = "
                                   + "\(NoteStore.shared.restorableNotes().contains(id))")

                        NoteStore.shared.flush()
                        NoteStore.shared.delete(id)
                        finish()
                    }
                }
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

        let pin = NSMenuItem(title: "📌  截图并固定…", action: #selector(startPinCapture), keyEquivalent: "a")
        pin.keyEquivalentModifierMask = [.option, .command]
        pin.target = self
        menu.addItem(pin)

        let pinnedCount = PinnedImageManager.shared.count
        if pinnedCount > 0 {
            let closePins = NSMenuItem(
                title: "关闭全部固定图片（\(pinnedCount) 张）",
                action: #selector(closeAllPins), keyEquivalent: "")
            closePins.target = self
            menu.addItem(closePins)
        }

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

        let permTitle = ScreenCapture.hasPermission
            ? "屏幕录制权限：已授权"
            : "⚠️  屏幕录制权限：未授权（点此处理）"
        let perm = NSMenuItem(title: permTitle,
                              action: #selector(showPermissionHelp), keyEquivalent: "")
        perm.target = self
        menu.addItem(perm)

        let restart = NSMenuItem(title: "重启悬浮笔记", action: #selector(restartApp), keyEquivalent: "")
        restart.target = self
        menu.addItem(restart)

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
            GlobalHotKey(keyCode: Key.a, modifiers: Key.cmdOption) { [weak self] in self?.startPinCapture() },
        ].compactMap { $0 }
        Self.log("[hotkey] 已注册 \(hotKeys.count)/10 个全局热键")
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

    // MARK: - 截图固定

    /// ⌥⌘A：框选一块屏幕区域并把它钉在屏幕上
    @objc private func startPinCapture() {
        guard !CaptureOverlay.shared.isActive else { return }

        guard ScreenCapture.hasPermission else {
            promptScreenRecording()
            return
        }

        CaptureOverlay.shared.begin { [weak self] cocoaRect in
            guard let self else { return }
            guard let cocoaRect else {
                Self.log("[pin] 用户取消")
                return
            }

            let cgRect = ScreenCapture.screenPointRect(fromCocoa: cocoaRect)
            Self.log(String(format: "[pin] 框选 %.0f×%.0f pt → 屏幕坐标 (%.0f, %.0f)",
                            cocoaRect.width, cocoaRect.height, cgRect.origin.x, cgRect.origin.y))

            // 遮罩刚关掉，等一帧再截，否则可能把遮罩自己拍进去
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                ScreenCapture.capture(rect: cgRect) { image in
                    guard let image else {
                        CaptureToast.shared.show("截取失败 · 请检查屏幕录制权限", accent: .systemRed)
                        Self.log("[pin] 截取失败")
                        return
                    }
                    // 位图是物理像素（Retina 上是 2 倍）。这里按「屏幕点」尺寸建 NSImage，
                    // 显示出来才是原本的视觉大小，而不是被放大一倍。
                    let nsImage = NSImage(cgImage: image, size: cocoaRect.size)
                    PinnedImageManager.shared.pin(nsImage, sourceRect: cocoaRect)
                    Self.log("[pin] 已固定 \(image.width)×\(image.height) 像素 "
                           + "（\(Int(cocoaRect.width))×\(Int(cocoaRect.height)) pt）")
                }
            }
        }
    }

    @objc private func closeAllPins() {
        PinnedImageManager.shared.closeAll()
        Self.log("[pin] 已关闭全部固定图片")
    }

    private func promptScreenRecording() {
        let alert = NSAlert()
        alert.messageText = "还差「屏幕录制」权限"
        alert.informativeText = """
        截图需要这项系统权限。

        如果你觉得「我明明已经开了」，通常是这两个原因：

        ① 授权之后没重启 App。这项权限只对新启动的进程生效。

        ② 系统设置里那条是旧版本的记录。每次重新构建，App 的签名都会变，
           系统会当成另一个程序 —— 那条记录显示「已开启」，
           但对现在这份二进制并不生效。

        建议先点「清除旧记录并重新授权」，它会清掉历史记录并重新发起申请。
        你在系统设置里勾选之后，再点「重启 App」。
        """
        alert.addButton(withTitle: "清除旧记录并重新授权")
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "重启 App")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let cleared = ScreenCapture.resetPermission()
            Self.log("[perm] 清除旧记录 = \(cleared ? "成功" : "失败")")
            ScreenCapture.requestPermission()
            ScreenCapture.openPrivacySettings()
            Self.log("[perm] 已重新申请；勾选后请点「重启 App」")
        case .alertSecondButtonReturn:
            ScreenCapture.requestPermission()
            ScreenCapture.openPrivacySettings()
        case .alertThirdButtonReturn:
            relaunchApp()
        default:
            break
        }
    }

    /// 重启自己：开一个新实例，再把当前这个退掉。
    /// 屏幕录制权限只对新进程生效，所以这是绕不开的一步。
    private func relaunchApp() {
        let url = Bundle.main.bundleURL
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, error in
            DispatchQueue.main.async {
                if let error {
                    Self.log("[perm] 重启失败: \(error.localizedDescription)")
                } else {
                    Self.log("[perm] 已启动新实例，退出当前这个")
                    NSApp.terminate(nil)
                }
            }
        }
    }

    @objc private func showPermissionHelp() { promptScreenRecording() }

    @objc private func restartApp() { relaunchApp() }

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

        // 背景（单篇覆盖）
        let bgItem = NSMenuItem(title: "背景", action: nil, keyEquivalent: "")
        let bgMenu = NSMenu()
        let curBG = Settings.shared.background(for: id)
        let followsGlobal = !Settings.shared.hasOwnBackground(id)

        let follow = NSMenuItem(
            title: (followsGlobal ? "✓ " : "") + "跟随全局（\(BackgroundCatalog.label(for: Settings.shared.noteBackground))）",
            action: #selector(setBackgroundAction(_:)), keyEquivalent: "")
        follow.target = self
        follow.representedObject = ["id": id, "value": NSNull()]
        bgMenu.addItem(follow)
        bgMenu.addItem(.separator())

        for opt in BackgroundCatalog.all {
            let mi = NSMenuItem(title: (!followsGlobal && curBG == opt.key ? "✓ " : "") + opt.label,
                                action: #selector(setBackgroundAction(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = ["id": id, "value": opt.key]
            bgMenu.addItem(mi)
        }
        bgItem.submenu = bgMenu
        sub.addItem(bgItem)

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

    @objc private func setBackgroundAction(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let id = info["id"] as? String else { return }
        if info["value"] is NSNull {
            Settings.shared.setBackground(nil, for: id)       // 跟随全局
            Self.log("[bg] \(id) 背景 → 跟随全局")
        } else if let key = info["value"] as? String {
            Settings.shared.setBackground(key, for: id)
            Self.log("[bg] \(id) 背景 → \(BackgroundCatalog.label(for: key))")
        }
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

    // MARK: - 笔记滚动 / 图片导出探针

    private func runNoteProbe() {
        let size = NSSize(width: 420, height: 340)   // 故意用小窗，制造溢出
        let panel = NotePanel(noteID: "探针", frame: NSRect(origin: .zero, size: size))
        let editor = WebEditorView(frame: NSRect(origin: .zero, size: size))
        panel.contentView = editor
        panel.orderFrontRegardless()

        var tall = "# 滚动测试\n\n"
        for i in 1...25 { tall += "第 \(i) 行内容，用来把窗口撑出滚动条。\n\n" }

        editor.onReady = {
            editor.load(markdown: tall)

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                Self.log("[note-probe] ── A. 结构度量 ──")
                editor.evaluate("window.FloatNotes._scrollInfo()") { r in
                    Self.log("[note-probe] \(r ?? "nil")")
                    self.probeRealScroll(panel: panel, editor: editor)
                }
            }
        }
    }

    /// 真实滚轮测试：把窗口挪到鼠标底下（不动用户光标），
    /// 发一个真的 scrollWheel 事件，看内容有没有滚。
    private func probeRealScroll(panel: NotePanel, editor: WebEditorView) {
        let mouse = NSEvent.mouseLocation
        panel.setFrameOrigin(NSPoint(x: mouse.x - panel.frame.width / 2,
                                     y: mouse.y - panel.frame.height / 2))
        panel.makeKey()
        panel.makeFirstResponder(editor.webView)
        editor.focusEditor()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            editor.evaluate("document.querySelector('.bn-container').scrollTop + '|' + document.documentElement.scrollTop") { before in
                let b = (before as? String) ?? "?"
                Self.log("[note-probe] ── B. 真实滚轮 ──")
                Self.log("[note-probe] 滚动前 container|html = \(b)")

                // 发一个真实的滚轮事件（向下滚）
                let src = CGEventSource(stateID: .combinedSessionState)
                if let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel,
                                   wheelCount: 1, wheel1: -120, wheel2: 0, wheel3: 0) {
                    e.post(tap: .cghidEventTap)
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    editor.evaluate("document.querySelector('.bn-container').scrollTop + '|' + document.documentElement.scrollTop") { after in
                        let a = (after as? String) ?? "?"
                        Self.log("[note-probe] 滚动后 container|html = \(a)")
                        Self.log("[note-probe] 结论 = " + (a == b ? "★ 真实滚轮无效（复现了问题）" : "有效"))
                        self.probeMarkdown(editor: editor)
                    }
                }
            }
        }
    }

    /// 图片能不能进 markdown
    private func probeMarkdown(editor: WebEditorView) {
        Self.log("[note-probe] ── C. 图片进 markdown ──")
        editor.evaluate("window.FloatNotes._insertImage('floatnotes://media/probe-test.png','探针图')") { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                editor.evaluate("window.FloatNotes._startMarkdownExport()") { _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        editor.evaluate("window.__fnMd ? window.__fnMd.value : 'null'") { md in
                            let text = (md as? String) ?? "null"
                            let hasImg = text.contains("probe-test.png")
                            Self.log("[note-probe] markdown 里含图片引用 = \(hasImg)")
                            Self.log("[note-probe] markdown 片段:\n----\n\(text.suffix(500))\n----")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 粘贴 → 存盘 探针

    private func runNewNoteProbe(to out: String) {
        var lines: [String] = []
        let fm = FileManager.default
        var done = false

        func finish() {
            guard !done else { return }
            done = true
            try? lines.joined(separator: "\n")
                .write(to: URL(fileURLWithPath: out), atomically: true, encoding: .utf8)
            for l in lines { Self.log("[new-note-probe] \(l)") }
            exit(0)
        }
        // 探针必须有兜底，卡住就永远拿不到报告
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
            lines.append("★ 超时：25 秒内没走完链路")
            finish()
        }

        let before = NoteStore.shared.recent(limit: 200)
        lines.append("新建前磁盘上共 \(before.count) 篇笔记")
        let openBefore = Set(NoteWindowManager.shared.openIDs)

        // 走真实的 ⌥⌘N 路径（不是自己拼 open(id)），否则测不到 newNote() 里的建文件逻辑
        NoteWindowManager.shared.newNote()
        let fresh = NoteWindowManager.shared.openIDs.filter { !openBefore.contains($0) }
        guard let id = fresh.first else {
            lines.append("★ newNote() 之后没多出窗口")
            finish(); return
        }
        lines.append("新笔记 id = \(id)")

        let url = NoteStore.shared.url(for: id)
        lines.append("目标路径 = \(url.path)")
        lines.append("① 刚新建完文件就存在 = \(fm.fileExists(atPath: url.path))（应为 true：新建即建文件）")

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            guard let ed = NoteWindowManager.shared.editor(for: id) else {
                lines.append("★ 拿不到编辑器，链路断在这里")
                finish(); return
            }
            lines.append("② 编辑器已就绪")

            let body = "# 保存链路测试\n\n这是一段用来验证保存的文字。\n\n![x](floatnotes://media/fake.png)\n"
            ed.load(markdown: body)

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                // exportNow 就是 BlockNoteView onChange 走的那条路
                ed.evaluate("window.FloatNotes.exportNow()") { _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        let exists = fm.fileExists(atPath: url.path)
                        lines.append("③ 触发内容变化后文件存在 = \(exists)")
                        // 写失败的内容必须还留在待写队列里，否则用户刚打的字就永久没了
                        lines.append("   待写队列剩余 = \(NoteStore.shared.pendingWriteCount)（成功时应为 0）")
                        lines.append("   用户看到的提示 = 「\(NoteStore.pendingWriteError ?? "（无）")」")
                        if exists {
                            let onDisk = NoteStore.shared.load(id)
                            lines.append("   磁盘内容 = 「\(onDisk.trimmingCharacters(in: .whitespacesAndNewlines))」")
                            lines.append("   图片已转相对路径 = \(onDisk.contains("attachments/"))")
                            lines.append("   残留自定义 scheme = \(onDisk.contains("floatnotes://media/"))")
                        } else {
                            lines.append("★ 没写进去 —— 保存链路有问题")
                            lines.append("   目录内容 = \((try? fm.contentsOfDirectory(atPath: NoteStore.shared.root.path))?.joined(separator: ", ") ?? "列不出")")
                        }
                        lines.append("④ recent() 能列到它 = \(NoteStore.shared.recent(limit: 200).contains(id))")

                        NoteStore.shared.flush()
                        NoteWindowManager.shared.close(id)
                        NoteStore.shared.delete(id)
                        lines.append("⑤ 已清理探针笔记")
                        finish()
                    }
                }
            }
        }
    }

    private func runTypeProbe(to out: String) {
        var lines: [String] = []
        var done = false
        let previousApp = NSWorkspace.shared.frontmostApplication

        func finish() {
            guard !done else { return }
            done = true
            // 用完把前台还给原来的 App，别把用户的焦点抢走不放
            previousApp?.activate()
            try? lines.joined(separator: "\n")
                .write(to: URL(fileURLWithPath: out), atomically: true, encoding: .utf8)
            for l in lines { Self.log("[type-probe] \(l)") }
            exit(0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            lines.append("★ 超时：30 秒没走完")
            finish()
        }

        let openBefore = Set(NoteWindowManager.shared.openIDs)
        NoteWindowManager.shared.newNote()
        guard let id = NoteWindowManager.shared.openIDs.first(where: { !openBefore.contains($0) }) else {
            lines.append("★ newNote() 没产生窗口"); finish(); return
        }
        let url = NoteStore.shared.url(for: id)
        lines.append("新笔记 id = \(id)")
        lines.append("目标路径 = \(url.path)")

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            guard let panel = NoteWindowManager.shared.panel(for: id),
                  let ed = NoteWindowManager.shared.editor(for: id) else {
                lines.append("★ 拿不到窗口/编辑器"); finish(); return
            }

            // 键盘事件是按「焦点」投递的，不像滚轮按指针位置，
            // 所以必须先把本 App 激活，否则这些字会打进用户当前那个 App 里。
            // ★ 注意 Info.plist 里 LSUIElement=true，默认是 .accessory 策略，
            //   那种状态下 activate 是无效的 —— 必须先切到 .regular，
            //   否则按键会打到别的 App，测出来「字没进编辑器」是假象。
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(ed.webView)
            ed.focusEditor()

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
                lines.append("激活状态：本 App isActive=\(NSApp.isActive) 前台 App=\(front)")
                if !NSApp.isActive {
                    lines.append("★ 没能拿到前台，按键会打到别处，这次结果不算数")
                }
                let src = CGEventSource(stateID: .combinedSessionState)
                let text = "打字保存测试ABC"
                for ch in Array(text.utf16) {
                    var u = ch
                    if let d = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) {
                        d.keyboardSetUnicodeString(stringLength: 1, unicodeString: &u)
                        d.post(tap: .cghidEventTap)
                    }
                    if let u2 = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
                        var c2 = ch
                        u2.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c2)
                        u2.post(tap: .cghidEventTap)
                    }
                    usleep(60_000)
                }
                lines.append("已投递 \(text.count) 个真实按键")

                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    // 先看字进没进编辑器 —— 没进去说明问题在输入，不在保存
                    ed.evaluate("""
                    JSON.stringify({
                      text: document.querySelector('.bn-editor')?.innerText ?? '',
                      changes: window.__fnChangeCount || 0
                    })
                    """) { inner in
                        var shown = ""
                        var changes = -1
                        if let s = inner as? String, let d = s.data(using: .utf8),
                           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                            shown = ((o["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                            changes = (o["changes"] as? NSNumber)?.intValue ?? -1
                        }
                        lines.append("编辑器里的内容 = 「\(shown)」")
                        lines.append("onChange 触发次数 = \(changes)")
                        if shown.isEmpty {
                            lines.append("★ 字根本没进编辑器 → 问题在输入链路，不是保存")
                        } else if changes <= 0 {
                            lines.append("★ 字进去了但 onChange 没触发 → BlockNoteView 回调没接上")
                        }

                        let exists = FileManager.default.fileExists(atPath: url.path)
                        lines.append("文件存在 = \(exists)")
                        if exists {
                            let onDisk = NoteStore.shared.load(id)
                            lines.append("磁盘内容 = 「\(onDisk.trimmingCharacters(in: .whitespacesAndNewlines))」")
                            lines.append("打字内容进了磁盘 = \(onDisk.contains("打字保存测试"))")
                        } else {
                            lines.append("★ 打字之后文件仍不存在 → 真实打字的 onChange 没有触发保存")
                            lines.append("   待写队列 = \(NoteStore.shared.pendingWriteCount)")
                        }

                        NoteStore.shared.flush()
                        NoteWindowManager.shared.close(id)
                        NoteStore.shared.delete(id)
                        lines.append("已清理")
                        finish()
                    }
                }
            }
        }
    }

    private func runPasteProbe() {
        let id = "探针粘贴"
        NoteStore.shared.delete(id)
        NoteWindowManager.shared.open(id)

        // 等窗口和编辑器就绪
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            guard let panel = NoteWindowManager.shared.panel(for: id),
                  let editor = NoteWindowManager.shared.editor(for: id) else {
                Self.log("[paste-probe] ✗ 拿不到窗口"); exit(1)
            }
            Self.log("[paste-probe] 窗口就绪")

            // 造一张小图放剪贴板（和用户复制截图等价）
            let img = NSImage(size: NSSize(width: 60, height: 40))
            img.lockFocus()
            NSColor.systemTeal.setFill()
            NSRect(x: 0, y: 0, width: 60, height: 40).fill()
            img.unlockFocus()
            ScreenCapture.copyToPasteboard(img)

            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(editor.webView)
            editor.focusEditor()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                Self.log("[paste-probe] 发送 ⌘V")
                NSApp.sendAction(Selector(("paste:")), to: nil, from: nil)

                // 防抖 0.4s，多等一会儿
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    NoteStore.shared.flush()
                    let md = NoteStore.shared.load(id)
                    let hasRel = md.contains("](attachments/")
                    let hasScheme = md.contains("floatnotes://media/")
                    Self.log("[paste-probe] ── 结果 ──")
                    Self.log("[paste-probe] 落盘 \(md.count) 字符")
                    Self.log("[paste-probe] 用相对路径 attachments/ = \(hasRel)；"
                           + "残留自定义 scheme = \(hasScheme)（应为 false）")
                    Self.log("[paste-probe] md 原文:\n····\n\(md)\n····")
                    Self.log("[paste-probe] 附件目录: "
                           + "\(NoteStore.shared.attachmentNames().sorted().joined(separator: ", "))")
                    NoteWindowManager.shared.close(id)
                    NoteStore.shared.delete(id)
                    for n in NoteStore.shared.attachmentNames() {
                        NoteStore.shared.deleteAttachment(n)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
                }
            }
        }
    }

    // MARK: - 遮罩 Space 探针

    private func runOverlayProbe(after delay: Double) {
        Self.log("[probe] \(Int(delay)) 秒后拉遮罩；当前前台 App = "
               + "\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let before = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            Self.log("[probe] 拉遮罩前：前台=\(before) 本App活跃=\(NSApp.isActive)")

            var afterOverlay = ""
            var pinnedPanel: PinnedImagePanel?
            var escCancelled = false

            // ── 阶段1：验证「不激活 App」之后键盘还收不收得到 ──
            // 这是改成 nonactivating 面板后最大的风险点：如果收不到键盘，
            // esc / 回车就失灵了，用户只能靠点按钮。
            var phase1Done = false
            CaptureOverlay.shared.begin { rect in
                if !phase1Done {
                    phase1Done = true
                    escCancelled = (rect == nil)
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                Self.log("[probe] 阶段1 post 一个真实 esc…")
                let src = CGEventSource(stateID: .combinedSessionState)
                CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: true)?
                    .post(tap: .cghidEventTap)
                CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: false)?
                    .post(tap: .cghidEventTap)

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    let closed = !CaptureOverlay.shared.isActive
                    Self.log("[probe] 阶段1 结果：遮罩已关=\(closed) 收到取消回调=\(escCancelled) → "
                           + (closed && escCancelled ? "键盘有效 ✅" : "键盘可能失灵 ⚠️"))

                    Self.log("[probe] 阶段2：完整流程")
                    startPhase2(&escCancelled)
                }
            }

            func startPhase2(_ unused: inout Bool) {
            CaptureOverlay.shared.begin { rect in
                guard let rect else {
                    Self.log("[probe] 遮罩被取消")
                    return
                }
                Self.log("[probe] 确认选区 \(NSStringFromRect(rect))，开始截图")
                let cg = ScreenCapture.screenPointRect(fromCocoa: rect)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                    ScreenCapture.capture(rect: cg) { image in
                        guard let image else {
                            Self.log("[probe] 截取失败")
                            return
                        }
                        let ns = NSImage(cgImage: image, size: rect.size)
                        pinnedPanel = PinnedImageManager.shared.pin(ns, sourceRect: rect)
                        Self.log("[probe] 已出图 \(image.width)×\(image.height) 像素")
                    }
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                afterOverlay = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
                let onScreen = Self.overlayWindowNumbersOnScreen()
                let total = Self.overlayWindowNumbers()
                Self.log("[probe] 遮罩：窗口号=\(total) 当前Space可见=\(onScreen) → "
                       + (onScreen.isEmpty ? "不在当前 Space ⚠️" : "就在当前 Space ✅"))
                Self.log("[probe] 拉遮罩后前台=\(afterOverlay)（拉之前是 \(before)）")

                // 模拟一次框选并确认，走完整流程
                CaptureOverlay.shared.simulateSelection(NSRect(x: 300, y: 300, width: 320, height: 220))
                CaptureOverlay.shared.simulateConfirm()
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                let final = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
                let pinnedOnScreen = Self.overlayWindowNumbersOnScreen()
                let overlayGone = !CaptureOverlay.shared.isActive
                Self.log("[probe] 出图后：前台=\(final) 遮罩已关闭=\(overlayGone) "
                       + "固定图数量=\(PinnedImageManager.shared.count)")
                Self.log("[probe] 当前 Space 可见的自家窗口号=\(pinnedOnScreen)")
                Self.log("[probe] ★ 前台是否被抢 = " + (final == before ? "否 ✅" : "是（\(before) → \(final)）⚠️"))

                PinnedImageManager.shared.closeAll()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exit(0) }
            }
            }   // startPhase2
        }
    }

    /// 我们所有的窗口号
    private static func overlayWindowNumbers() -> [Int] {
        NSApp.windows.filter { $0.isVisible }.map { $0.windowNumber }
    }

    /// 这些窗口号里，有哪些出现在「当前 Space 的屏幕上」
    private static func overlayWindowNumbersOnScreen() -> [Int] {
        let mine = Set(overlayWindowNumbers())
        let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] ?? []
        return list.compactMap { w -> Int? in
            guard let n = w[kCGWindowNumber as String] as? Int, mine.contains(n) else { return nil }
            return n
        }
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
            // ★ 必须在 onReady 之后调 —— 编辑器就绪前 window.FloatNotes 还不存在，
            //   提前调用会静默失效（踩过）
            let bgKey = Settings.shared.noteBackground
            editor.setBackground(bgKey, isDark: BackgroundCatalog.isDark(bgKey))
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
        backupUserNotes()
        PasteboardSnapshot.logger = { Self.log("[pboard] \($0)") }

        // ★ 先把前台拿稳，再开始测。
        //
        // 阶段18（⌘C / ⌘V）和阶段19/21（真实滚轮、真实截图）用的都是**真实的系统事件**，
        // 而系统事件只送给前台 App。以前自检从没保证过这一点，全靠环境凑巧 ——
        // 结果就是这几个检查时灵时不灵：偶尔全过，偶尔一起报错。
        // 这种假失败比没有测试更糟，因为真正的回归会被当成噪声忽略掉。
        //
        // 注意 Info.plist 里 LSUIElement=true，默认是 .accessory 策略，
        // 那种状态下 activate 是无效的，必须先切到 .regular。
        ensureFrontmost()

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

    /// 确保本 App 拿到前台，并**等它真的生效**再回调。
    ///
    /// activate 是异步的：调用完立刻读 isActive 还是 false，
    /// 于是后面依赖真实系统事件的检查照样会失败 —— 之前就是这么白改了一轮。
    /// 所以这里轮询等，等不到也继续（但留一条明确的话，免得又被当成产品回归）。
    private func ensureFrontmost(timeout: TimeInterval = 5.0, then: (() -> Void)? = nil) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            if NSApp.isActive {
                Self.log("[selftest] 前台已就绪 isActive=true"
                       + (then == nil ? "" : "，开始依赖真实系统事件的检查"))
                then?()
                return
            }
            if Date() > deadline {
                Self.log("[selftest] ⚠️ 等了 \(Int(timeout)) 秒仍没拿到前台 isActive=false；"
                       + "需要真实系统事件的检查（⌘C/⌘V、滚轮、截图）可能报假失败")
                then?()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: poll)
        }
        poll()
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

    /// 临时：追踪剪贴板在各阶段之间的变化
    private func traceClipboard(_ tag: String) {
        let pb = NSPasteboard.general
        let s = pb.string(forType: .string)
        Self.log("[pboard] \(tag) → \(s.map { "「\($0.prefix(20))」(\($0.count)字)" } ?? "无文本") "
               + "types=\(pb.types?.map { $0.rawValue }.prefix(3).joined(separator: ",") ?? "-")")
    }

    private func backupSettings() {
        settingsBackup = [
            "showFloatingBall": Settings.shared.showFloatingBall,
            "coverMenuBar": Settings.shared.coverMenuBar,
            "noteFontFamily": Settings.shared.noteFontFamily,
            "noteFontSize": Settings.shared.noteFontSize,
            "noteBackground": Settings.shared.noteBackground,
        ]
        ballFrameBackup = UserDefaults.standard.string(forKey: "ballFrame")

        // 光放在内存里不够：自检要是被强杀（崩溃、Ctrl+C、超时 kill），
        // finish() 就跑不到，用户的设置会被永久改掉 —— 之前就真出过这事。
        // 所以落一份盘，并留个「还没还原」的标记，下次启动先把欠的账还上。
        let d = UserDefaults.standard
        d.set(settingsBackup, forKey: Self.backupKey)
        d.set(ballFrameBackup, forKey: Self.backupBallFrameKey)
        d.set(true, forKey: Self.backupPendingKey)
        d.synchronize()
    }

    private func restoreSettings() {
        if let v = settingsBackup["showFloatingBall"] as? Bool { Settings.shared.showFloatingBall = v }
        if let v = settingsBackup["coverMenuBar"] as? Bool { Settings.shared.coverMenuBar = v }
        if let v = settingsBackup["noteFontFamily"] as? String { Settings.shared.noteFontFamily = v }
        if let v = settingsBackup["noteFontSize"] as? Double { Settings.shared.noteFontSize = v }
        if let v = settingsBackup["noteBackground"] as? String { Settings.shared.noteBackground = v }
        if let f = ballFrameBackup {
            UserDefaults.standard.set(f, forKey: "ballFrame")
        }
        if let f = ballFrameBackup {
            let r = NSRectFromString(f)
            if r.width > 10 { ballPanel?.setFrame(r, display: false) }
        }
        clearSettingsBackup()
    }

    private static let backupKey = "selftest.settingsBackup"
    private static let backupBallFrameKey = "selftest.ballFrameBackup"
    private static let backupPendingKey = "selftest.backupPending"

    private func clearSettingsBackup() {
        let d = UserDefaults.standard
        d.removeObject(forKey: Self.backupKey)
        d.removeObject(forKey: Self.backupBallFrameKey)
        d.removeObject(forKey: Self.backupPendingKey)
        d.synchronize()
    }

    /// 上次自检没走到还原就退出了？启动时先把设置还回去。
    /// 正常启动时这个标记不存在，等于什么都不做。
    private func recoverInterruptedSelftest() {
        let d = UserDefaults.standard
        guard d.bool(forKey: Self.backupPendingKey) else { return }
        guard let saved = d.dictionary(forKey: Self.backupKey) else {
            clearSettingsBackup()
            return
        }
        Self.log("[selftest] 检测到上次自检异常中断，先把被改动的设置还原回来")
        settingsBackup = saved
        ballFrameBackup = d.string(forKey: Self.backupBallFrameKey)
        restoreSettings()
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
    ///
    /// ★ 注意这里**不能**把 DailyNote.todayID() 直接删掉。
    ///   今日笔记是真·用户数据，不是测试产物。之前的版本把它和测试笔记一起删，
    ///   于是每跑一次自检，用户当天的摘录就被清空一次 —— 这正是「笔记凭空消失」的元凶。
    ///   现在改成自检开始前备份、结束后还原，见 backupUserNotes() / restoreUserNotes()。
    private func cleanupAllTestNotes() {
        let ids = ["自检主题笔记", Self.selftestID, "外部同步测试"]
        for id in ids {
            NoteWindowManager.shared.close(id)
            NoteStore.shared.delete(id)
            try? FileManager.default.removeItem(at: NoteStore.shared.url(for: id))
        }
    }

    // MARK: - 今日笔记的备份 / 还原

    private var dailyNoteBackup: String?
    private var dailyNoteExisted = false

    /// 自检会往今日笔记里灌测试内容，跑之前先原样存下来
    private func backupUserNotes() {
        let id = DailyNote.todayID()
        let url = NoteStore.shared.url(for: id)
        dailyNoteExisted = FileManager.default.fileExists(atPath: url.path)
        dailyNoteBackup = dailyNoteExisted ? NoteStore.shared.load(id) : nil
        if dailyNoteExisted {
            Self.log("[selftest] 今日笔记已备份（\(dailyNoteBackup?.count ?? 0) 字），跑完原样还回去")
        }
    }

    /// 把今日笔记恢复成自检之前的样子。
    /// 原来没有这个文件就删掉测试留下的那份，原来有就连内容一起还原。
    private func restoreUserNotes() {
        let id = DailyNote.todayID()
        NoteWindowManager.shared.close(id)
        if dailyNoteExisted, let saved = dailyNoteBackup {
            NoteStore.shared.replaceAll(id, with: saved)
            Self.log("[selftest] 今日笔记已还原（\(saved.count) 字）")
        } else {
            NoteStore.shared.delete(id)
            try? FileManager.default.removeItem(at: NoteStore.shared.url(for: id))
        }
        dailyNoteBackup = nil
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

        stage18()
    }

    // MARK: 复制粘贴检查

    private func stage18() {
        traceClipboard("阶段18 开始")
        guard !finished else { return }
        Self.log("[selftest] 阶段18 · 复制粘贴")

        // A. 主菜单里必须有「编辑」菜单 —— 这是剪贴板快捷键的唯一入口
        guard let main = NSApp.mainMenu else {
            problems.append("没有主菜单，⌘C/⌘V 没有入口")
            finish(ok: false, reason: problems.joined(separator: "; ")); return
        }
        let subItems = main.items.compactMap { $0.submenu?.items }.flatMap { $0 }
        let pasteItem = subItems.first { $0.action == Selector(("paste:")) }
        let copyItem = subItems.first { $0.action == Selector(("copy:")) }
        Self.log("[selftest] 主菜单 \(main.items.count) 个顶级菜单；"
               + "复制=⌘\(copyItem?.keyEquivalent.uppercased() ?? "无") "
               + "粘贴=⌘\(pasteItem?.keyEquivalent.uppercased() ?? "无")")
        if copyItem == nil { problems.append("主菜单里没有「复制」项") }
        if pasteItem == nil { problems.append("主菜单里没有「粘贴」项，⌘V 没有入口") }

        // B. 功能测试：真往编辑器里粘一段
        guard let panel = NoteWindowManager.shared.panel(for: Self.selftestID),
              let editor = NoteWindowManager.shared.editor(for: Self.selftestID) else {
            problems.append("拿不到笔记窗口")
            finish(ok: false, reason: problems.joined(separator: "; ")); return
        }

        let pb = NSPasteboard.general
        // 备份必须连图片 / 文件一起存。只存字符串的话，
        // 用户剪贴板里是图片时 savedClip 为 nil，还原就成了「清空」。
        let savedClipboard = PasteboardSnapshot.capture()
        Self.log("[pboard] 阶段18 备份剪贴板 = \(savedClipboard.count) 项 "
               + "\(savedClipboard.first?.keys.map(\.rawValue).joined(separator: ",") ?? "-")")
        let token = "粘贴自检\(Int(Date().timeIntervalSince1970))"
        pb.clearContents()
        pb.setString(token, forType: .string)

        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(editor.webView)
        // 光把 WKWebView 设成 firstResponder 还不够 ——
        // 网页里的可编辑区也得真的拿到焦点，paste: 才有落点。
        // 真实使用时用户是「点进编辑区」完成的这一步，测试里得手动触发。
        editor.focusEditor()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }

            // 响应链上到底有没有人能处理 paste:（没有的话菜单项会是灰的）
            let target = NSApp.target(forAction: Selector(("paste:")), to: nil, from: nil)
            Self.log("[selftest] paste: 的响应者 = "
                   + (target.map { String(describing: type(of: $0)) } ?? "无")
                   + "；本 App 是否前台=\(NSApp.isActive) 窗口是否 key=\(panel.isKeyWindow)")

            let focused = editor.evaluate("document.activeElement ? document.activeElement.className || document.activeElement.tagName : 'none'")
            _ = focused

            if target == nil { self.problems.append("响应链上没有对象能处理 paste:") }

            NSApp.sendAction(Selector(("paste:")), to: nil, from: nil)

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                editor.evaluate("document.querySelector('.tiptap, .bn-editor, .ProseMirror')?.innerText || ''") { text in
                    let body = (text as? String) ?? ""
                    let ok = body.contains(token)
                    Self.log("[selftest] 粘贴结果：编辑器\(ok ? "已收到" : "没收到")「\(token)」")
                    if !ok { self.problems.append("⌘V 粘贴没有进入编辑器") }

                    // C. 复制回环：全选 → 复制 → 剪贴板里应该出现刚才粘进去的内容
                    NSApp.sendAction(Selector(("selectAll:")), to: nil, from: nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        // 先清空，确认剪贴板里真的是这次复制写进去的
                        pb.clearContents()
                        NSApp.sendAction(Selector(("copy:")), to: nil, from: nil)

                        // ★ 轮询而不是死等。
                        //   WebKit 的复制是**异步**的：copy: 返回时剪贴板往往还是空的，
                        //   内容要等 web 进程写完才出现。原来固定等 0.8 秒，
                        //   机器一忙就偶尔读到空剪贴板 —— 表现为随机报「⌘C 没写进剪贴板」，
                        //   实测大概五次里错一次。等够 3 秒、每 0.15 秒看一次就稳了。
                        let deadline = Date().addingTimeInterval(3.0)
                        func pollCopy() {
                            let copied = pb.string(forType: .string) ?? ""
                            if copied.contains(token) || Date() > deadline {
                                let copiedOK = copied.contains(token)
                                Self.log("[selftest] 复制回环：剪贴板\(copiedOK ? "已拿到" : "没拿到")"
                                       + "编辑器内容（\(copied.count) 字符）")
                                if !copiedOK { self.problems.append("⌘C 复制没有写进剪贴板") }

                                // 原样还回去（含图片、文件等非文本类型）
                                PasteboardSnapshot.restore(savedClipboard)
                                Self.log("[pboard] 已还原剪贴板 \(savedClipboard.count) 项")

                                self.stage19()
                                return
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: pollCopy)
                        }
                        pollCopy()
                    }
                }
            }
        }
    }

    // MARK: 截图固定检查

    /// 统计图片里「蓝紫渐变」像素的占比 —— 用来确认截到的确实是悬浮球
    private func bluePurpleRatio(_ image: CGImage) -> Double {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return 0 }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var hit = 0, total = 0
        for i in stride(from: 0, to: buf.count, by: 4) {
            total += 1
            let r = Double(buf[i]), g = Double(buf[i + 1]), b = Double(buf[i + 2])
            if b > 180 && b > g + 40 && r < b { hit += 1 }
        }
        return total > 0 ? Double(hit) / Double(total) * 100 : 0
    }

    private func stage19() {
        guard !finished else { return }
        Self.log("[selftest] 阶段19 · 截图固定")

        // A. 权限
        let permitted = ScreenCapture.hasPermission
        Self.log("[selftest] 屏幕录制权限 = \(permitted)")
        if !permitted {
            Self.log("[selftest] 没有权限，跳过实际截取（这不算失败，但功能不可用）")
            finish(ok: problems.isEmpty, reason: problems.joined(separator: "; ")); return
        }

        // B. 框选遮罩：验证「拖出选区 → 还能移动/改大小 → 确认才截」这套交互
        CaptureOverlay.shared.begin { [weak self] rect in
            // 取消时 rect 为 nil；这里只记录，具体断言在 stage19Overlay 里做
            self?.confirmedRect = rect
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.stage19Overlay()
        }
    }

    private var confirmedRect: NSRect?

    private func stage19Overlay() {
        guard !finished else { return }
        let active = CaptureOverlay.shared.isActive
        Self.log("[selftest] 框选遮罩可见 = \(active)")
        if !active { problems.append("框选遮罩没有显示出来") }

        // 模拟：从 (200,300) 拖到 (500,500)，得到 300×200 的选区
        let from = NSPoint(x: 200, y: 300)
        let to = NSPoint(x: 500, y: 500)
        CaptureOverlay.shared.simulateMouse(.leftMouseDown, at: from)
        CaptureOverlay.shared.simulateMouse(.leftMouseDragged, at: to)
        CaptureOverlay.shared.simulateMouse(.leftMouseUp, at: to)

        guard let created = CaptureOverlay.shared.currentSelection else {
            problems.append("拖拽没有产生选区")
            finish(ok: false, reason: problems.joined(separator: "; ")); return
        }
        Self.log("[selftest] 拖出的选区 = \(NSStringFromRect(created))")

        // ★ 关键：松手之后不能立刻截图，得把选区留着让用户继续调
        if !CaptureOverlay.shared.isActive {
            problems.append("松手就立刻截图了，没给调整的机会")
        } else {
            Self.log("[selftest] 松手后遮罩仍在，可以继续调整 ✓")
        }

        // 拖动选区整体：从选区内部 (350,400) 拖到 (390,430)，应整体位移 (40,30)
        let grab = NSPoint(x: 350, y: 400)
        let drop = NSPoint(x: 390, y: 430)
        CaptureOverlay.shared.simulateMouse(.leftMouseDown, at: grab)
        CaptureOverlay.shared.simulateMouse(.leftMouseDragged, at: drop)
        CaptureOverlay.shared.simulateMouse(.leftMouseUp, at: drop)

        guard let moved = CaptureOverlay.shared.currentSelection else {
            problems.append("移动后选区丢了")
            finish(ok: false, reason: problems.joined(separator: "; ")); return
        }
        let dx = moved.origin.x - created.origin.x
        let dy = moved.origin.y - created.origin.y
        Self.log(String(format: "[selftest] 整体拖动位移 = (%.0f, %.0f)，期望 (40, 30)", dx, dy))
        if abs(dx - 40) > 1 || abs(dy - 30) > 1 {
            problems.append(String(format: "选区拖动不对（%.0f, %.0f）", dx, dy))
        }
        if abs(moved.width - created.width) > 1 || abs(moved.height - created.height) > 1 {
            problems.append("拖动时选区尺寸不该变")
        }

        // 拉右下角把手。注意 y 轴向上：想让选区「变大」要往右下拖，
        // 也就是 y 变小 —— 反了的话底边会越过顶边，被最小边长挡住。
        let corner = NSPoint(x: moved.maxX, y: moved.minY)
        let target = NSPoint(x: moved.maxX + 60, y: moved.minY - 70)
        CaptureOverlay.shared.simulateMouse(.leftMouseDown, at: corner)
        CaptureOverlay.shared.simulateMouse(.leftMouseDragged, at: target)
        CaptureOverlay.shared.simulateMouse(.leftMouseUp, at: target)

        guard let resized = CaptureOverlay.shared.currentSelection else {
            problems.append("拉把手后选区丢了")
            finish(ok: false, reason: problems.joined(separator: "; ")); return
        }
        let grewW = resized.width - moved.width
        let grewH = resized.height - moved.height
        Self.log(String(format: "[selftest] 拉右下角后尺寸 %.0f×%.0f（原 %.0f×%.0f，增加 %.0f×%.0f）",
                        resized.width, resized.height, moved.width, moved.height, grewW, grewH))
        if grewW <= 1 || grewH <= 1 { problems.append("拉把手没有改变选区大小") }
        // 拉右下角时，该动的是底边和右边；左上角（minX / maxY）必须钉住
        if abs(resized.minX - moved.minX) > 1 || abs(resized.maxY - moved.maxY) > 1 {
            problems.append(String(format: "拉右下角把手把左上角也带跑了（%.0f,%.0f → %.0f,%.0f）",
                                   moved.minX, moved.maxY, resized.minX, resized.maxY))
        }

        // 确认之后才真的出图
        let expected = resized
        CaptureOverlay.shared.simulateConfirm()
        if CaptureOverlay.shared.isActive {
            problems.append("确认之后遮罩没有关闭")
        }

        // 把「确认时的选区」记下来，下一步用它去截
        confirmedRect = expected
        Self.log("[selftest] 确认的最终选区 = \(NSStringFromRect(expected))")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.stage19Capture()
        }
    }

    /// C. 截取 —— 拿悬浮球当参照物：它位置已知、颜色又很好认，
    ///    正好用来验证「Cocoa 坐标 → 屏幕点坐标」这步换算对不对。
    private func stage19Capture(rescued: Bool = false) {
        guard !finished else { return }

        // 悬浮球在这里只是「参照物」：位置已知、颜色好认，用来验证坐标换算。
        // 但用户完全可能把它隐藏了（⌥⌘B），那是合法状态，不该让自检误报失败。
        // 所以先临时把它亮出来，跑完由 finish() 连设置一起还原。
        if ballPanel?.isVisible != true {
            guard !rescued else {
                problems.append("悬浮球显示不出来，无法验证截取坐标系")
                finish(ok: false, reason: problems.joined(separator: "; ")); return
            }
            Self.log("[selftest] 悬浮球当前是隐藏的，临时显示一下作为坐标参照（你的设置稍后会还原）")
            Settings.shared.showFloatingBall = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.stage19Capture(rescued: true)
            }
            return
        }

        guard let ball = ballPanel else {
            problems.append("悬浮球面板不存在，无法验证截取坐标系")
            finish(ok: false, reason: problems.joined(separator: "; ")); return
        }

        let cocoa = ball.frame
        let cgRect = ScreenCapture.screenPointRect(fromCocoa: cocoa)
        Self.log(String(format: "[selftest] 悬浮球 Cocoa(%.0f,%.0f %.0f×%.0f) → 屏幕坐标(%.0f,%.0f)",
                        cocoa.origin.x, cocoa.origin.y, cocoa.width, cocoa.height,
                        cgRect.origin.x, cgRect.origin.y))

        ScreenCapture.capture(rect: cgRect) { [weak self] image in
            guard let self else { return }
            guard let image else {
                self.problems.append("截取返回空图（权限可能没真正生效）")
                self.finish(ok: false, reason: self.problems.joined(separator: "; ")); return
            }

            let scale = NSScreen.main?.backingScaleFactor ?? 2
            let expectW = Int(cocoa.width * scale), expectH = Int(cocoa.height * scale)
            Self.log("[selftest] 截取尺寸 = \(image.width)×\(image.height)，期望 \(expectW)×\(expectH)")
            if abs(image.width - expectW) > 2 || abs(image.height - expectH) > 2 {
                self.problems.append("截取尺寸不符（\(image.width)×\(image.height)）")
            }

            let ratio = self.bluePurpleRatio(image)
            Self.log(String(format: "[selftest] 蓝紫像素占比 = %.1f%%（悬浮球应该很高）", ratio))
            if ratio < 15 {
                self.problems.append(String(format: "截到的不是悬浮球（蓝紫仅 %.1f%%），坐标系可能不对", ratio))
            }

            self.stage19b(image: image, cocoaRect: cocoa)
        }
    }

    /// D. 固定成窗口
    private func stage19b(image: CGImage, cocoaRect: NSRect) {
        let nsImage = NSImage(cgImage: image, size: cocoaRect.size)
        let panel = PinnedImageManager.shared.pin(nsImage, sourceRect: cocoaRect)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.stage19c(panel: panel, nsImage: nsImage)
        }
    }

    private func stage19c(panel: PinnedImagePanel, nsImage: NSImage) {
        guard !finished else { return }

        let cb = panel.collectionBehavior
        let onTop = panel.level.rawValue == NSWindow.Level.floating.rawValue
        let ok = panel.isVisible && onTop
            && cb.contains(.canJoinAllSpaces)
            && cb.contains(.fullScreenAuxiliary)
        Self.log("[selftest] 固定窗口：可见=\(panel.isVisible) level=\(panel.level.rawValue) "
               + "跨Space=\(cb.contains(.canJoinAllSpaces)) "
               + "可浮全屏=\(cb.contains(.fullScreenAuxiliary))")
        if !ok { problems.append("固定窗口的置顶/跨屏属性不对") }

        // 再钉一张，确认能同时存在多张
        _ = PinnedImageManager.shared.pin(nsImage, sourceRect: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.stage19d(nsImage: nsImage)
        }
    }

    /// E. 多张共存 + 复制到剪贴板
    private func stage19d(nsImage: NSImage) {
        guard !finished else { return }

        let n = PinnedImageManager.shared.count
        Self.log("[selftest] 多张固定：现在共 \(n) 张")
        if n < 2 { problems.append("无法同时固定多张截图") }

        let saved = PasteboardSnapshot.capture()
        ScreenCapture.copyToPasteboard(nsImage)
        let pb = NSPasteboard.general
        let types = pb.types ?? []
        let hasImage = types.contains(.tiff) || types.contains(.png)
        Self.log("[selftest] 复制到剪贴板：含图片类型=\(hasImage) "
               + "类型=\(types.prefix(4).map(\.rawValue).joined(separator: ","))")
        if !hasImage { problems.append("截图没有正确写进剪贴板") }
        PasteboardSnapshot.restore(saved)

        PinnedImageManager.shared.closeAll()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            let left = PinnedImageManager.shared.count
            Self.log("[selftest] 全部关闭后剩 \(left) 张")
            if left != 0 { self.problems.append("关闭全部固定图片没清干净") }
            self.stage19e(nsImage: nsImage)
        }
    }

    /// F. 把截图粘进笔记 —— 这是这个功能最终要落地的效果
    private func stage19e(nsImage: NSImage) {
        guard !finished else { return }

        guard let panel = NoteWindowManager.shared.panel(for: Self.selftestID),
              let editor = NoteWindowManager.shared.editor(for: Self.selftestID) else {
            problems.append("拿不到笔记窗口，无法验证粘贴")
            finish(ok: false, reason: problems.joined(separator: "; ")); return
        }

        // 备份剪贴板 —— 这一步会把截图盖上去，跑完必须还回去
        let savedClipboard = PasteboardSnapshot.capture()
        // 记下现有附件，跑完只删自己新造的，不碰用户已有的东西
        let attachmentsBefore = NoteStore.shared.attachmentNames()

        ScreenCapture.copyToPasteboard(nsImage)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(editor.webView)
        editor.focusEditor()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self else { return }
            // ⌘V 走的是「key window 的响应链」，所以粘不进编辑器时，
            // 第一个要看的不是剪贴板而是**当前到底哪个窗口是 key**。
            Self.log("[selftest] 粘贴前状态：isActive=\(NSApp.isActive) "
                   + "keyWindow=「\(NSApp.keyWindow?.title ?? "无")」 "
                   + "本窗口是 key=\(panel.isKeyWindow) 可见=\(panel.isVisible)")
            NSApp.sendAction(Selector(("paste:")), to: nil, from: nil)

            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                // 先把实际生成了哪些块打出来，再判断 —— 免得选择器写错就误判功能坏了
                let js = #"""
                (() => {
                  const types = [...document.querySelectorAll('[data-content-type]')]
                    .map(e => e.getAttribute('data-content-type'));
                  const imgs = document.querySelectorAll('img').length;
                  return JSON.stringify({ types, imgs });
                })()
                """#
                editor.evaluate(js) { result in
                    let raw = (result as? String) ?? "null"
                    Self.log("[selftest] 粘贴后文档里的块：\(raw)")
                    let after = NoteStore.shared.attachmentNames()

                    var imageBlocks = 0
                    if let d = raw.data(using: .utf8),
                       let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                        let types = (o["types"] as? [String]) ?? []
                        imageBlocks = types.filter { $0 == "image" }.count
                    }
                    Self.log("[selftest] 粘进笔记：图片块 \(imageBlocks) 个，"
                           + "新增附件 \(after.subtracting(attachmentsBefore).count) 个")

                    if imageBlocks < 1 { self.problems.append("截图没有作为图片块粘进笔记") }
                    if after.subtracting(attachmentsBefore).isEmpty {
                        self.problems.append("粘贴的图片没有落盘到附件目录")
                    }

                    // 只清理本次新产生的附件，用户原有的一个都不动
                    for name in after.subtracting(attachmentsBefore) {
                        NoteStore.shared.deleteAttachment(name)
                    }
                    PasteboardSnapshot.restore(savedClipboard)
                    self.stage20()
                }
            }
        }
    }

    // MARK: 笔记背景检查

    private func stage20() {
        guard !finished else { return }
        Self.log("[selftest] 阶段20 · 笔记背景")

        // A. 清单与缩略图
        let opts = BackgroundCatalog.all
        let pics = opts.filter { $0.key != "none" }
        let missing = pics.filter { BackgroundCatalog.thumbnail(for: $0.key) == nil }
        Self.log("[selftest] 背景选项 \(opts.count) 个（\(pics.count) 张图 + 无背景）；"
               + "缺缩略图 \(missing.count) 个")
        if pics.count < 18 { problems.append("背景图数量不足（\(pics.count)）") }
        if !missing.isEmpty {
            problems.append("缩略图缺失：\(missing.prefix(3).map(\.key).joined(separator: ","))")
        }

        guard let ed = NoteWindowManager.shared.editor(for: Self.selftestID) else {
            problems.append("拿不到编辑器，无法验证背景链路")
            finish(ok: false, reason: problems.joined(separator: "; ")); return
        }

        // B. 背景图能不能经 floatnotes://bg/ 取到
        let probeKey = pics.first?.key ?? "01-grid-apple"
        ed.evaluate("window.FloatNotes._startBgProbe('\(probeKey)');") { [weak self] _ in
            self?.pollBackground(ed: ed, key: probeKey, attempt: 0)
        }
    }

    private func pollBackground(ed: WebEditorView, key: String, attempt: Int) {
        guard !finished else { return }
        if attempt > 25 {
            problems.append("背景图加载超时")
            stage20c(ed: ed); return
        }
        ed.evaluate("window.__fnBg ? JSON.stringify(window.__fnBg) : 'null'") { [weak self] raw in
            guard let self else { return }
            guard let s = raw as? String, s != "null",
                  let d = s.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  (o["done"] as? Bool) == true else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.pollBackground(ed: ed, key: key, attempt: attempt + 1)
                }
                return
            }
            let ok = o["ok"] as? Bool ?? false
            let w = (o["w"] as? NSNumber)?.intValue ?? 0
            let h = (o["h"] as? NSNumber)?.intValue ?? 0
            Self.log("[selftest] 背景图经 scheme 取回：\(ok) \(w)×\(h)（\(key)）")
            if !ok || w == 0 { self.problems.append("背景图没能经 floatnotes://bg/ 取到") }
            self.stage20c(ed: ed)
        }
    }

    /// C. 应用背景后 CSS 与主题是否跟着变
    private func stage20c(ed: WebEditorView) {
        // 浅色背景
        ed.setBackground("09-blossom-grid", isDark: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            ed.evaluate("window.FloatNotes._bgState()") { raw in
                let lightState = (raw as? String) ?? "null"
                Self.log("[selftest] 浅色背景状态: \(lightState)")

                // 深色背景
                ed.setBackground("12-night-stars", isDark: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    ed.evaluate("window.FloatNotes._bgState()") { raw2 in
                        let darkState = (raw2 as? String) ?? "null"
                        Self.log("[selftest] 深色背景状态: \(darkState)")

                        func parse(_ s: String) -> [String: Any] {
                            guard let d = s.data(using: .utf8),
                                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
                            else { return [:] }
                            return o
                        }
                        let light = parse(lightState), dark = parse(darkState)
                        if (light["hasClass"] as? Bool) != true {
                            self.problems.append("浅色背景没有生效（class 没加上）")
                        }
                        if !((light["bg"] as? String) ?? "").contains("floatnotes://bg/") {
                            self.problems.append("浅色背景的 background-image 没设上")
                        }
                        if (dark["isDark"] as? Bool) != true {
                            self.problems.append("深色背景没标记为 dark")
                        }

                        // 恢复成用户原本的设置
                        let original = Settings.shared.noteBackground
                        ed.setBackground(original, isDark: BackgroundCatalog.isDark(original))
                        self.stage21()
                    }
                }
            }
        }
    }

    // MARK: 滚动 + 图片往返检查
    //
    // 这两个都是「自测全绿但实际用不了」的典型：
    //   · 滚动：程序化 scrollTop 能滚，真实滚轮滚不动（溢出逃到了 html）
    //   · 图片：本 App 里显示正常，但 md 里写的是自定义 scheme，别处打不开
    // 所以这里都按「真实行为」验，不按结构验。

    private func stage21() {
        guard !finished else { return }
        Self.log("[selftest] 阶段21 · 滚动与图片往返")

        // A. 路径转换（纯函数，先验这个便宜的）
        let sample = "![a](floatnotes://media/a.png) 和 ![](attachments/b.png)"
        let disk = NoteStore.toDiskForm(sample)
        let back = NoteStore.toEditorForm(disk)
        Self.log("[selftest] 落盘形态: \(disk)")
        if disk.contains("floatnotes://media/") {
            problems.append("落盘后仍残留自定义 scheme，别的编辑器打不开")
        }
        if !disk.contains("attachments/a.png") { problems.append("没转成相对路径") }
        if !back.contains("floatnotes://media/a.png") { problems.append("载入时没换回 scheme") }

        // B. 滚动：先塞长文，等排版稳定，再上真实滚轮。
        //    顺序很关键 —— 之前是先测结构再加载长文，测到的是旧内容（scrollH == clientH），
        //    于是「滚不动」既可能是真回归、也可能只是没内容可滚，报错信息根本没法定位。
        guard let panel = NoteWindowManager.shared.panel(for: Self.selftestID),
              let ed = NoteWindowManager.shared.editor(for: Self.selftestID) else {
            problems.append("拿不到笔记窗口，无法验证滚动")
            finish(ok: false, reason: problems.joined(separator: "; ")); return
        }

        var tall = "# 滚动自检\n\n"
        for i in 1...60 { tall += "第 \(i) 行，用来把窗口撑出滚动范围。\n\n" }
        ed.load(markdown: tall)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            ed.evaluate("window.FloatNotes._scrollInfo()") { r in
                let info = (r as? String) ?? "null"
                Self.log("[selftest] 滚动结构（长文加载后）: \(info)")

                var containerScrolls = false
                var canScroll = false
                if let d = info.data(using: .utf8),
                   let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                   let c = o["container"] as? [String: Any] {
                    containerScrolls = (c["overflowY"] as? String) == "auto"
                    canScroll = (c["canScroll"] as? Bool) ?? false
                }
                if !containerScrolls {
                    self.problems.append("滚动容器不是 .bn-container（溢出会逃到 html，滚轮会失灵）")
                }
                // 长文都撑不出一像素的可滚高度，说明容器的 height 没被真正约束住，
                // 内容会被 html{overflow:hidden} 裁掉看不见 —— 这是产品 bug，不是环境问题。
                if !canScroll {
                    self.problems.append("内容已超出窗口，容器却无可滚高度（高度没约束住，内容会被裁掉）")
                }
                self.stage21Wheel(panel: panel, ed: ed)
            }
        }
    }

    private func stage21Wheel(panel: NotePanel, ed: WebEditorView) {
        guard !finished else { return }

        // 把**光标**挪到窗口正中，而不是把窗口挪到光标底下。
        // 后者在光标贴近屏幕边缘时会被 constrainFrameRect 夹回来，
        // 窗口就不在光标下面了，滚轮事件自然打不到 —— 表现为偶发「滚不动」假失败。
        let savedCursor = CGEvent(source: nil)?.location
        let cgRect = ScreenCapture.screenPointRect(fromCocoa: panel.frame)
        CGWarpMouseCursorPosition(CGPoint(x: cgRect.midX, y: cgRect.midY))
        // 滚轮事件送给「光标底下那个窗口」，所以光标到底有没有落在窗口里必须打出来 ——
        // 不然「滚不动」既可能是真回归，也可能只是光标没到位。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let cur = CGEvent(source: nil)?.location ?? .zero
            Self.log(String(format: "[selftest] 滚轮前：光标(%.0f,%.0f) 窗口(%.0f,%.0f %.0f×%.0f) 落在窗口内=%@ isActive=%@",
                            cur.x, cur.y, cgRect.minX, cgRect.minY, cgRect.width, cgRect.height,
                            cgRect.contains(cur) ? "是" : "否", NSApp.isActive ? "是" : "否"))
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            panel.makeKey()
            panel.makeFirstResponder(ed.webView)
            ed.focusEditor()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                ed.evaluate("""
                (() => {
                  const c = document.querySelector('.bn-container');
                  return JSON.stringify({ top: c.scrollTop, max: c.scrollHeight - c.clientHeight });
                })()
                """) { before in
                    var b = -1.0, maxScroll = -1.0
                    if let s = before as? String, let d = s.data(using: .utf8),
                       let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                        b = (o["top"] as? NSNumber)?.doubleValue ?? -1
                        maxScroll = (o["max"] as? NSNumber)?.doubleValue ?? -1
                    }

                    let src = CGEventSource(stateID: .combinedSessionState)
                    CGEvent(scrollWheelEvent2Source: src, units: .pixel,
                            wheelCount: 1, wheel1: -120, wheel2: 0, wheel3: 0)?
                        .post(tap: .cghidEventTap)

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        ed.evaluate("document.querySelector('.bn-container').scrollTop") { after in
                            let a = (after as? NSNumber)?.doubleValue ?? -1
                            Self.log(String(format: "[selftest] 真实滚轮: scrollTop %.0f → %.0f（可滚上限 %.0f）",
                                            b, a, maxScroll))
                            if a <= b {
                                // 区分两种完全不同的故障：没东西可滚，还是滚轮没送达。
                                // 混在一起报会把人引向错误的方向。
                                if maxScroll <= 0 {
                                    self.problems.append("滚轮没移动，但本来也没有可滚内容（测试前提不成立）")
                                } else {
                                    self.problems.append("有 \(Int(maxScroll))px 可滚内容，真实滚轮却没送达（这正是不该漏掉的回归）")
                                }
                            }
                            // 光标还回去，别把用户的鼠标留在我们窗口里
                            if let c = savedCursor { CGWarpMouseCursorPosition(c) }
                            self.stage21Image(panel: panel, ed: ed)
                        }
                    }
                }
            }
        }
    }

    /// D. 真实打字能不能落盘
    ///
    /// 用户报的就是这条：新建笔记、打字，文件在 Finder 里根本不出现。
    /// 自检原来只验了 exportNow()（程序化触发 emitChange），那和真实打字**不是一条路** ——
    /// 真实打字走 BlockNoteView 的 onChange 回调，所以这个缺口一直没被发现。
    private func stage22() {
        guard !finished else { return }
        Self.log("[selftest] 阶段22 · 真实打字落盘")

        // A. 任何一条打开笔记的路径都必须留下文件。
        //    用户报的「只有刚打开那个窗口存不住」，根子就是启动自带的窗口
        //    走了一条不建文件的路，和新建窗口不一致。这里把 open() 本身钉住。
        let probeID = "open自检\(Int(Date().timeIntervalSince1970) % 100000)"
        NoteStore.shared.delete(probeID)
        let probeURL = NoteStore.shared.url(for: probeID)
        if FileManager.default.fileExists(atPath: probeURL.path) {
            problems.append("测试前置失败：临时笔记已存在")
        }
        _ = NoteWindowManager.shared.open(probeID, focus: false)
        let probeCreated = FileManager.default.fileExists(atPath: probeURL.path)
        Self.log("[selftest] open() 之后文件已存在 = \(probeCreated)"
               + "（启动自带的窗口走的就是这条路径）")
        if !probeCreated { problems.append("open() 打开的笔记没有落盘文件（启动那个窗口就是这样存的）") }
        NoteWindowManager.shared.close(probeID)
        NoteStore.shared.delete(probeID)

        let openBefore = Set(NoteWindowManager.shared.openIDs)
        NoteWindowManager.shared.newNote()
        guard let id = NoteWindowManager.shared.openIDs.first(where: { !openBefore.contains($0) }) else {
            problems.append("newNote() 没开出新窗口")
            finish(ok: false, reason: problems.joined(separator: "; ")); return
        }
        let url = NoteStore.shared.url(for: id)
        let created = FileManager.default.fileExists(atPath: url.path)
        Self.log("[selftest] 新建即产生文件 = \(created)（否则 Finder 里看不出新建过）")
        if !created { problems.append("新建笔记后磁盘上没有文件") }

        guard let panel = NoteWindowManager.shared.panel(for: id),
              let ed = NoteWindowManager.shared.editor(for: id) else {
            problems.append("拿不到新笔记的窗口/编辑器")
            finish(ok: false, reason: problems.joined(separator: "; ")); return
        }

        let previousApp = NSWorkspace.shared.frontmostApplication
        // Info.plist 里 LSUIElement=true，默认 .accessory 策略下 activate 无效，
        // 必须先切 .regular，否则按键会打进别的 App
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(ed.webView)
        ed.focusEditor()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }

            // ★ 这里**不用**全局键盘事件。
            //   试过用 CGEvent 真打字，结果整个自检变成看天吃饭：
            //   有没有拿到前台、光标在哪、别的 App 有没有抢焦点，都会左右结果，
            //   而且一旦没拿到焦点，那些字会直接打进用户当前那个 App 里。
            //   execCommand('insertText') 走的是和真人打字同一条 DOM 路径
            //   （beforeinput → ProseMirror 事务 → BlockNoteView onChange），
            //   少了「系统投递按键」这一段，但那一段已经由 --type-probe 单独验过了。
            ed.evaluate("""
            (() => {
              const el = document.querySelector('.bn-editor');
              if (!el) return 'no-editor';
              el.focus();
              const ok = document.execCommand('insertText', false, '打字落盘检查XYZ');
              return ok ? 'ok' : 'execCommand-failed';
            })()
            """) { r in
                let res = (r as? String) ?? "?"
                Self.log("[selftest] 注入打字结果 = \(res)")

                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    ed.evaluate("window.__fnChangeCount || 0") { n in
                        let changes = (n as? NSNumber)?.intValue ?? -1
                        let onDisk = NoteStore.shared.load(id)
                        Self.log("[selftest] 打字后 onChange 触发 \(changes) 次，磁盘内容 "
                               + "= 「\(onDisk.trimmingCharacters(in: .whitespacesAndNewlines))」")
                        if changes <= 0 {
                            self.problems.append("打字没有触发 onChange（编辑器回调断了）")
                        }
                        if !onDisk.contains("打字落盘检查") {
                            self.problems.append("打字内容没有落盘（用户报的就是这个）")
                        }

                        previousApp?.activate()
                        NoteWindowManager.shared.close(id)
                        NoteStore.shared.delete(id)
                        self.finish(ok: self.problems.isEmpty,
                                    reason: self.problems.joined(separator: "; "))
                    }
                }
            }
        }
    }

    /// C. 图片在编辑器 ↔ md 之间的往返
    private func stage21Image(panel: NotePanel, ed: WebEditorView) {
        guard !finished else { return }

        ed.load(markdown: "# 图片往返\n\n")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            ed.evaluate("window.FloatNotes._insertImage('floatnotes://media/roundtrip.png','往返测试')") { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    ed.evaluate("window.FloatNotes._startMarkdownExport()") { _ in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            ed.evaluate("window.__fnMd ? window.__fnMd.value : 'null'") { md in
                                let text = (md as? String) ?? "null"
                                let diskForm = NoteStore.toDiskForm(text)
                                let backForm = NoteStore.toEditorForm(diskForm)

                                Self.log("[selftest] 编辑器导出: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
                                Self.log("[selftest] 变成落盘形态: \(diskForm.trimmingCharacters(in: .whitespacesAndNewlines))")

                                if !text.contains("floatnotes://media/roundtrip.png") {
                                    self.problems.append("编辑器导出的 md 里没有图片引用")
                                }
                                if !diskForm.contains("attachments/roundtrip.png") {
                                    self.problems.append("落盘形态没有相对路径")
                                }
                                if !backForm.contains("floatnotes://media/roundtrip.png") {
                                    self.problems.append("载入形态没换回自定义 scheme")
                                }

                                // 真跑一遍：写进文件再读回来，确认往返一致
                                let id = "往返自检"
                                NoteStore.shared.replaceAll(id, with: diskForm)
                                let reloaded = NoteStore.shared.load(id)
                                let forEditor = NoteStore.toEditorForm(reloaded)
                                Self.log("[selftest] 落盘后读回并转换: "
                                       + "\(forEditor.contains("floatnotes://media/roundtrip.png") ? "图片引用完好 ✅" : "丢了 ⚠️")")
                                if !forEditor.contains("floatnotes://media/roundtrip.png") {
                                    self.problems.append("存盘再读回后图片引用丢了")
                                }
                                NoteStore.shared.delete(id)

                                self.stage22()
                            }
                        }
                    }
                }
            }
        }
    }

    private func finish(ok: Bool, reason: String) {
        guard !finished else { return }
        finished = true

        // 无论走哪条路（成功 / 断言失败 / 超时）都要把用户设置还原、把测试笔记删掉
        restoreSettings()
        restoreUserNotes()
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
