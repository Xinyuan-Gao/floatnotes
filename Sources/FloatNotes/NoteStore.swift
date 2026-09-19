import AppKit

/// 极简笔记存储：以 Markdown 为唯一真源，落盘到 ~/Documents/悬浮笔记/。
/// 写盘采用「临时文件 + 原子替换」，避免崩溃写坏文件。
final class NoteStore {

    static let shared = NoteStore()

    let root: URL
    let attachmentsDir: URL
    private var dirty: [String: String] = [:]
    private var flushTimer: Timer?
    private let debounce: TimeInterval = 0.4

    /// 落盘失败时回调（App 层接上提示条）。界面还没准备好就先攒着。
    var onWriteError: ((String) -> Void)?
    static var pendingWriteError: String?

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        root = docs.appendingPathComponent("悬浮笔记", isDirectory: true)
        attachmentsDir = root.appendingPathComponent("attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: attachmentsDir, withIntermediateDirectories: true)
    }

    // MARK: - 附件（粘贴的图片）

    /// 写入一张附件图片，返回文件名（供编辑器拼成 floatnotes://media/<名>）
    func saveAttachment(data: Data, preferredName: String?, mime: String?) -> String? {
        let ext = Self.extForMime(mime) ?? Self.extForName(preferredName) ?? "png"
        let name = "\(UUID().uuidString).\(ext)"
        let dest = attachmentsDir.appendingPathComponent(name)
        do {
            try data.write(to: dest, options: .atomic)
            return name
        } catch {
            NSLog("[NoteStore] 附件写入失败: \(error)")
            return nil
        }
    }

    /// 附件目录里现有的文件名集合（自检用来精确清理自己产生的那几个）
    func attachmentNames() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(
            at: attachmentsDir, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]))?.map(\.lastPathComponent) ?? []
        return Set(names)
    }

    /// 附件目录里现有多少个文件（自检用）
    func attachmentCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(
            at: attachmentsDir, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]))?.count ?? 0
    }

    /// 删除一个附件文件（自检清理用）
    func deleteAttachment(_ filename: String) {
        let target = attachmentsDir.appendingPathComponent(filename).standardizedFileURL
        guard target.path.hasPrefix(attachmentsDir.standardizedFileURL.path) else { return }
        try? FileManager.default.removeItem(at: target)
    }

    private static func extForMime(_ mime: String?) -> String? {
        guard let mime else { return nil }
        switch mime.lowercased() {
        case "image/png": return "png"
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/heic": return "heic"
        case "image/tiff": return "tiff"
        default: return nil
        }
    }

    private static func extForName(_ name: String?) -> String? {
        guard let name, !name.isEmpty else { return nil }
        let e = (name as NSString).pathExtension
        return e.isEmpty ? nil : e.lowercased()
    }

    // MARK: - 会话恢复
    //
    // 记住"退出时开着哪些笔记"，下次启动原样恢复。

    private let sessionKey = "session.openNotes"

    var openNoteIDs: [String] {
        get { UserDefaults.standard.stringArray(forKey: sessionKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: sessionKey) }
    }

    func rememberOpenNotes(_ ids: [String]) {
        openNoteIDs = ids
    }

    /// 上次会话里还存在的笔记（文件被手动删掉的自动跳过）
    func restorableNotes() -> [String] {
        openNoteIDs.filter { FileManager.default.fileExists(atPath: url(for: $0).path) }
    }

    // MARK: - 今日笔记用：确保存在 / 追加

    /// 若笔记文件不存在则创建（带一级标题），返回是否新建
    @discardableResult
    func ensureNote(_ id: String) -> Bool {
        let url = url(for: id)
        if FileManager.default.fileExists(atPath: url.path) { return false }
        writeNow(id, "# \(id)\n\n")
        return true
    }

    /// 建一个**空**笔记文件（新建笔记用），返回是否新建。
    ///
    /// 和 ensureNote 的区别很关键：ensureNote 会写一行 `# 标题`，
    /// 编辑器载入后光标停在那行标题里，用户一开口打字就接在标题后面，
    /// 标题被写成「笔记-20260919-101722今天开会讨论…」。空文件则是干净的一段。
    @discardableResult
    func touchNote(_ id: String) -> Bool {
        let url = url(for: id)
        if FileManager.default.fileExists(atPath: url.path) { return false }
        return writeNow(id, "")
    }

    /// 追加内容到笔记末尾。用于「静默存入今日笔记」与归档。
    /// 以「未落盘的输入（如果有）优先，否则磁盘内容」为基础，避免丢字。
    @discardableResult
    func appendText(_ text: String, to id: String) -> Bool {
        var base = dirty[id] ?? load(id)

        if base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            base = "# \(id)\n\n"
        }
        if !base.hasSuffix("\n") { base += "\n" }

        let merged = base + "\n" + text
        dirty.removeValue(forKey: id)
        flushTimer?.invalidate()
        return writeNow(id, merged)
    }

    // MARK: - 删除

    func delete(_ id: String) {
        try? FileManager.default.removeItem(at: url(for: id))
        dirty.removeValue(forKey: id)
    }

    // MARK: - 图片路径的两种形态
    //
    // 编辑器里图片用的是自定义 scheme：floatnotes://media/<文件名>
    //   —— 只有本 App 在跑的时候才解析得了。
    // 但写进 .md 的必须是**相对路径** attachments/<文件名>，
    //   —— 这样 Obsidian / VS Code / 任何 Markdown 编辑器都能显示，
    //      笔记换台机器、发给别人也不会丢图。
    //
    // 之前直接把 floatnotes:// 写进了 md：在本 App 里自测一切正常，
    // 但用别的编辑器打开就是死链，看着像「图片没保存」。

    static func toDiskForm(_ markdown: String) -> String {
        markdown.replacingOccurrences(of: "floatnotes://media/", with: "attachments/")
    }

    static func toEditorForm(_ markdown: String) -> String {
        markdown.replacingOccurrences(of: "attachments/", with: "floatnotes://media/")
    }

    // MARK: - 读

    func load(_ id: String) -> String {
        let url = root.appendingPathComponent(id).appendingPathExtension("md")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func url(for id: String) -> URL {
        root.appendingPathComponent(id).appendingPathExtension("md")
    }

    /// 最近修改的若干条笔记（按 mtime 倒序）
    func recent(limit: Int = 8) -> [String] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }

        return items
            .filter { $0.pathExtension == "md" }
            .compactMap { u -> (String, Date)? in
                guard let v = try? u.resourceValues(forKeys: Set(keys)),
                      v.isRegularFile == true else { return nil }
                return (u.deletingPathExtension().lastPathComponent,
                        v.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    // MARK: - 自写记录（供 FSEvents 去重）
    //
    // 本 App 自己落盘也会触发文件事件；记下「刚才是谁写的」，
    // 监听器据此忽略自己造成的变化，避免自激循环。

    private var selfWrites: [String: Date] = [:]
    private var lastWritten: [String: String] = [:]

    func lastSelfWrite(for path: String) -> Date? {
        selfWrites[path]
    }

    /// 是否还有防抖窗口内没落盘的输入
    func hasPendingWrite(_ id: String) -> Bool {
        dirty[id] != nil
    }

    /// 本 App 最后一次写入某个笔记的内容（用于判断磁盘上的变化是不是外部改的）
    func lastWrittenContent(_ id: String) -> String? {
        lastWritten[id]
    }

    // MARK: - 全量读取（搜索 / 附件回收用）

    func allNoteIDs() -> [String] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }
        return items
            .filter { $0.pathExtension == "md" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    /// 按修改时间倒序返回 (id, 内容)
    func allNotes() -> [(id: String, content: String, modified: Date)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }

        return items
            .filter { $0.pathExtension == "md" }
            .compactMap { u -> (String, String, Date)? in
                guard let v = try? u.resourceValues(forKeys: Set(keys)),
                      v.isRegularFile == true,
                      let text = try? String(contentsOf: u, encoding: .utf8) else { return nil }
                return (u.deletingPathExtension().lastPathComponent, text,
                        v.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.2 > $1.2 }
    }

    // MARK: - 写（防抖）

    func scheduleSave(_ id: String, markdown: String) {
        dirty[id] = Self.toDiskForm(markdown)
        flushTimer?.invalidate()
        flushTimer = Timer.scheduledTimer(withTimeInterval: debounce, repeats: false) { [weak self] _ in
            self?.flush()
        }
    }

    func flush() {
        // ★ 写失败的内容必须留在 dirty 里。
        //   之前是无条件 removeAll()：只要写失败一次，用户刚打的字就
        //   彻底没了 —— 界面上没提示，重试也不会再写第二次。
        for (id, text) in dirty where writeNow(id, text) {
            dirty.removeValue(forKey: id)
        }
    }

    /// 还有多少篇没成功落盘（自检 / 诊断用）
    var pendingWriteCount: Int { dirty.count }

    /// 唯一的原子写入口（临时文件 + replaceItemAt），其它写入方法都走这里
    @discardableResult
    private func writeNow(_ id: String, _ text: String) -> Bool {
        let dest = url(for: id)
        let tmp = dest.deletingLastPathComponent()
            .appendingPathComponent(".\(id).\(UUID().uuidString).tmp")
        do {
            try text.write(to: tmp, atomically: false, encoding: .utf8)
            _ = try FileManager.default.replaceItemAt(dest, withItemAt: tmp)
            selfWrites[dest.path] = Date()
            lastWritten[id] = text
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            NSLog("[NoteStore] 写入失败 \(id): \(error)")
            reportWriteFailure(id: id, error: error)
            return false
        }
    }

    /// 落盘失败时必须让人看见。
    ///
    /// 之前只写 NSLog：用户那边表现为「打了一堆字，文件却没出现」，
    /// 而且完全没有任何提示，只能怀疑是自己没保存 —— 排查时根本无从下手。
    /// 现在把原因回抛给界面，同时也把失败的那篇内容留在内存里，
    /// 万一只是暂时写不进去（比如权限弹窗还没点），下次 flush 还能补上。
    private func reportWriteFailure(id: String, error: Error) {
        let ns = error as NSError
        var hint = "「\(id)」保存失败"
        switch ns.code {
        case NSFileWriteNoPermissionError:
            hint += "：没有写入权限，请检查「系统设置 › 隐私与安全性 › 文件与文件夹」"
        case NSFileWriteOutOfSpaceError:
            hint += "：磁盘空间不足"
        case NSFileNoSuchFileError:
            hint += "：笔记目录不存在或已被移走"
        default:
            hint += "：\(ns.localizedDescription)"
        }
        if let cb = onWriteError {
            cb(hint)
        } else {
            Self.pendingWriteError = hint
        }
    }

    /// 整篇覆盖（归档时从今日笔记里摘掉条目用）
    @discardableResult
    func replaceAll(_ id: String, with content: String) -> Bool {
        dirty.removeValue(forKey: id)
        return writeNow(id, content)
    }

    // MARK: - 新建

    /// 按标题生成唯一笔记 ID（重名自动加序号）
    func uniqueNoteID(base: String) -> String {
        let stem = base.isEmpty ? "未命名笔记" : base
        if !FileManager.default.fileExists(atPath: url(for: stem).path) { return stem }
        var i = 2
        while FileManager.default.fileExists(atPath: url(for: "\(stem) \(i)").path) { i += 1 }
        return "\(stem) \(i)"
    }

    func newNoteID() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "笔记-\(f.string(from: Date()))"
    }

    // MARK: - 窗口位置记忆

    func saveFrame(_ rect: NSRect, for id: String) {
        UserDefaults.standard.set(NSStringFromRect(rect), forKey: "frame.\(id)")
    }

    func loadFrame(for id: String) -> NSRect? {
        guard let s = UserDefaults.standard.string(forKey: "frame.\(id)") else { return nil }
        let r = NSRectFromString(s)
        return r.width > 100 && r.height > 60 ? r : nil
    }
}
