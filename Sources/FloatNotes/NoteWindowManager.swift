import AppKit

/// 多笔记窗口管理：新建 / 打开 / 关闭 / 位置记忆 / 层级 / 全部收起 / 会话恢复。
final class NoteWindowManager: NSObject, NSWindowDelegate {

    static let shared = NoteWindowManager()

    private var panels: [String: NotePanel] = [:]
    private var cascadeIndex = 0
    private var collapsed = false
    private(set) var hiddenAll = false

    var onLog: ((String) -> Void)?

    var openCount: Int { panels.count }
    var openIDs: [String] { Array(panels.keys) }

    override private init() {
        super.init()
        // 设置变化时实时生效
        NotificationCenter.default.addObserver(
            forName: Settings.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.applySettings()
        }
    }

    /// 当前置顶层级（由设置决定）
    var currentLevel: PanelLevel { Settings.shared.panelLevel }

    /// 当前获得键盘焦点的笔记（菜单里的「当前笔记」操作指向它）
    private(set) var keyNoteID: String?

    /// 有焦点就用焦点笔记，否则用最近打开的那个
    var activeNoteID: String? {
        if let k = keyNoteID, panels[k] != nil { return k }
        return panels.keys.sorted().last
    }

    // MARK: - 打开

    @discardableResult
    func open(_ id: String, focus: Bool = true, prefill: String? = nil) -> NotePanel {
        if let existing = panels[id] {
            if hiddenAll || collapsed { restoreVisibility() }
            existing.orderFrontRegardless()
            if focus { existing.makeKey() }
            return existing
        }

        let frame = NoteStore.shared.loadFrame(for: id) ?? defaultFrame()
        let panel = NotePanel(noteID: id, frame: frame, level: currentLevel)
        panel.delegate = self
        panel.title = id

        let editor = WebEditorView(frame: panel.contentView?.bounds ?? .zero)
        editor.autoresizingMask = [.width, .height]
        editor.setFontSize(Settings.shared.noteFontSize)
        editor.setFontFamily(FontCatalog.css(for: Settings.shared.noteFontFamily))
        editor.onLog = { [weak self] msg in self?.onLog?(msg) }
        editor.onReady = { [weak editor, weak panel] in
            if let prefill {
                // 划词新建：直接灌入预填内容并立刻落盘
                editor?.load(markdown: prefill)
                NoteStore.shared.scheduleSave(id, markdown: prefill)
            } else {
                editor?.load(markdown: NoteStore.shared.load(id))
            }
            editor?.setFontSize(Settings.shared.noteFontSize)
            editor?.setFontFamily(FontCatalog.css(for: Settings.shared.noteFontFamily))
            editor?.setTheme(Settings.shared.theme(for: id))
            panel?.applyAppearance(opacity: Settings.shared.opacity(for: id))
            NotificationCenter.default.post(name: .floatNotesEditorReady, object: nil)
        }
        editor.onChange = { markdown in
            NoteStore.shared.scheduleSave(id, markdown: markdown)
        }
        panel.contentView = editor
        panel.applyAppearance(opacity: Settings.shared.opacity(for: id))

        panels[id] = panel
        panel.orderFrontRegardless()
        if focus { panel.makeKey() }

        rememberSession()
        onLog?("[window] 新建窗口 \(id) | level=\(currentLevel.rawValue) "
             + "| 当前共 \(panels.count) 个")
        return panel
    }

    func newNote() {
        open(NoteStore.shared.newNoteID())
    }

    /// 启动时恢复上次会话
    func restoreSession() {
        let ids = NoteStore.shared.restorableNotes()
        guard !ids.isEmpty else {
            open("欢迎")
            return
        }
        onLog?("[session] 恢复上次打开的 \(ids.count) 个笔记")
        for id in ids { open(id, focus: false) }
        if Settings.shared.collapseOnLaunch {
            collapseAll(force: true)
        }
    }

    private func defaultFrame() -> NSRect {
        guard let screen = NSScreen.main else {
            return NSRect(x: 200, y: 200, width: 420, height: 340)
        }
        let v = screen.visibleFrame
        let step: CGFloat = 28
        let n = CGFloat(cascadeIndex % 8)
        cascadeIndex += 1
        let w: CGFloat = 420, h: CGFloat = 340
        let x = v.maxX - w - 24 - n * step
        let y = v.maxY - h - 24 - n * step
        return NSRect(x: max(v.minX + 12, x), y: max(v.minY + 12, y), width: w, height: h)
    }

    // MARK: - 关闭 / 删除

    func close(_ id: String) {
        guard let p = panels[id] else { return }
        NoteStore.shared.flush()
        panels.removeValue(forKey: id)
        p.delegate = nil
        p.close()
        rememberSession()
    }

    func closeAll() {
        NoteStore.shared.flush()
        for (_, p) in panels {
            p.delegate = nil
            p.close()
        }
        panels.removeAll()
        rememberSession()
    }

    /// 删除笔记（文件一起删）
    func deleteNote(_ id: String) {
        close(id)
        NoteStore.shared.delete(id)
        onLog?("[window] 已删除笔记 \(id)")
    }

    // MARK: - 显隐 / 收起

    private func restoreVisibility() {
        guard hiddenAll else { return }
        hiddenAll = false
        for (_, p) in panels { p.orderFrontRegardless() }
    }

    func toggleAll() {
        hiddenAll.toggle()
        for (_, p) in panels {
            if hiddenAll { p.orderOut(nil) } else { p.orderFrontRegardless() }
        }
        onLog?("[window] \(hiddenAll ? "隐藏" : "显示")全部笔记（共 \(panels.count) 个）")
    }

    /// 全部收起 / 展开。传 force 可指定目标状态而非切换。
    func collapseAll(force: Bool? = nil) {
        let target = force ?? !collapsed
        guard target != collapsed else { return }
        for (_, p) in panels { p.setCollapsed(target) }
        collapsed = target
        onLog?("[window] 全部\(target ? "收起" : "展开")（\(panels.count) 个窗口）")
    }

    var isCollapsed: Bool { collapsed }

    // MARK: - 设置

    /// 层级与字号（设置变化时调用）
    func applySettings() {
        let lvl = currentLevel
        let fs = Settings.shared.noteFontSize
        for (id, p) in panels {
            p.applyFloating(level: lvl)
            (p.contentView as? WebEditorView)?.setFontSize(fs)
            (p.contentView as? WebEditorView)?.setFontFamily(
                FontCatalog.css(for: Settings.shared.noteFontFamily))
            (p.contentView as? WebEditorView)?.setTheme(Settings.shared.theme(for: id))
            p.applyAppearance(opacity: Settings.shared.opacity(for: id))
        }
        onLog?("[settings] 已应用：层级=\(lvl.rawValue) 字号=\(Int(fs))pt "
               + "字体=\(FontCatalog.label(for: Settings.shared.noteFontFamily))")
    }

    /// ⌥⌘L：在「普通置顶」和「盖住菜单栏」之间切换
    func toggleMenuBarCover() -> PanelLevel {
        Settings.shared.coverMenuBar.toggle()
        return currentLevel
    }

    // MARK: - 外部改动同步

    /// 磁盘上的笔记被外部改了（Obsidian / VS Code），把打开的窗口刷新过来。
    /// 只有当磁盘内容与本 App 最后一次写入的内容不同时才刷新，
    /// 避免把自己刚写的又读回来打断正在输入的用户。
    func reloadFromDisk(_ ids: Set<String>, force: Bool = false) {
        var reloaded: [String] = []
        var skipped: [String] = []
        for id in ids {
            guard let panel = panels[id],
                  let editor = panel.contentView as? WebEditorView else { continue }

            // 本地还有没落盘的输入 → 跳过，绝不覆盖用户正在打的内容。
            // force = true 用于归档这类「文件已被本程序正式改写」的场景。
            if !force, NoteStore.shared.hasPendingWrite(id) {
                skipped.append(id)
                continue
            }

            let disk = NoteStore.shared.load(id)
            if NoteStore.shared.lastWrittenContent(id) == disk { continue }

            editor.load(markdown: disk)
            reloaded.append(id)
        }
        if !skipped.isEmpty {
            onLog?("[sync] 跳过（有未保存输入）：\(skipped.joined(separator: ", "))")
        }
        if !reloaded.isEmpty {
            onLog?("[sync] 外部改动已同步：\(reloaded.joined(separator: ", "))")
        }
    }

    // MARK: - 导出

    /// 取某个笔记的 HTML（用于导出 RTF / 复制富文本）
    func requestHTML(for id: String, completion: @escaping (String?) -> Void) {
        guard let editor = editor(for: id) else { completion(nil); return }
        editor.evaluate("window.FloatNotes._startHTMLExport();") { _ in
            self.pollHTML(editor: editor, attempt: 0, completion: completion)
        }
    }

    private func pollHTML(editor: WebEditorView, attempt: Int,
                          completion: @escaping (String?) -> Void) {
        if attempt > 25 { completion(nil); return }
        editor.evaluate("window.__fnHtml ? JSON.stringify(window.__fnHtml) : 'null'") { raw in
            guard let s = raw as? String, s != "null",
                  let d = s.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  (o["done"] as? Bool) == true else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.pollHTML(editor: editor, attempt: attempt + 1, completion: completion)
                }
                return
            }
            completion(o["value"] as? String)
        }
    }

    // MARK: - 会话

    private func rememberSession() {
        NoteStore.shared.rememberOpenNotes(Array(panels.keys).sorted())
    }

    // MARK: - 诊断 / 自检

    func editor(for id: String) -> WebEditorView? {
        panels[id]?.contentView as? WebEditorView
    }

    func panel(for id: String) -> NotePanel? { panels[id] }

    func diagnostics() -> String {
        guard !panels.isEmpty else { return "（没有打开的笔记窗口）" }
        return panels.map { id, p in
            let cb = p.collectionBehavior
            var flags: [String] = []
            if cb.contains(.canJoinAllSpaces) { flags.append("canJoinAllSpaces") }
            if cb.contains(.fullScreenAuxiliary) { flags.append("fullScreenAuxiliary") }
            if cb.contains(.stationary) { flags.append("stationary") }
            return """
              · \(id)
                  level=\(p.level.rawValue)  isFloatingPanel=\(p.isFloatingPanel)  \
                hidesOnDeactivate=\(p.hidesOnDeactivate)  visible=\(p.isVisible)
                  behavior=[\(flags.joined(separator: ", "))]
                  frame=\(NSStringFromRect(p.frame))
            """
        }.joined(separator: "\n")
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NotePanel else { return }
        NoteStore.shared.flush()
        NoteStore.shared.saveFrame(w.frame, for: w.noteID)
        panels.removeValue(forKey: w.noteID)
        rememberSession()
        onLog?("[window] 关闭 \(w.noteID)，位置已记住")
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let w = notification.object as? NotePanel else { return }
        keyNoteID = w.noteID
    }

    func windowDidMove(_ notification: Notification) {
        guard let w = notification.object as? NotePanel else { return }
        NoteStore.shared.saveFrame(w.frame, for: w.noteID)
    }

    func windowDidResize(_ notification: Notification) {
        guard let w = notification.object as? NotePanel else { return }
        NoteStore.shared.saveFrame(w.frame, for: w.noteID)
    }
}

extension Notification.Name {
    static let floatNotesEditorReady = Notification.Name("floatNotesEditorReady")
}
