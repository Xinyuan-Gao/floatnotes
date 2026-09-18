import AppKit

/// 「今日笔记」：所有静默捕获的摘录都追加到同一天的这一篇里。
///
/// 这是 M3 的核心思路——原来每划一次词就弹一个窗口，等于把「分屏的繁杂」
/// 换成了「窗口的繁杂」。改成静默追加之后，看文章时只多一个小提示，
/// 等读完了再打开今日笔记统一整理。
enum DailyNote {

    static func dateString(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func todayID(_ date: Date = Date()) -> String {
        "\(dateString(date)) 今日笔记"
    }

    /// 一条摘录在今日笔记里的样子
    static func entry(for sel: CapturedSelection) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let time = f.string(from: sel.capturedAt)

        var title = "摘录"
        if let t = sel.sourceTitle, !t.isEmpty {
            title = t.count > 42 ? String(t.prefix(42)) + "…" : t
        }

        var lines: [String] = []
        lines.append("## \(time) · \(title)")
        lines.append("")

        let body = sel.text.trimmingCharacters(in: .whitespacesAndNewlines)
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            lines.append(t.isEmpty ? ">" : "> \(t)")
        }

        if let url = sel.sourceURL, !url.isEmpty {
            lines.append("")
            lines.append("[原文链接](\(url))")
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// 追加一条内容到今日笔记。
    /// 笔记开着就走编辑器（避免和编辑器的自动保存互相覆盖），没开就直接写文件。
    /// completion 回传笔记 ID，失败回传空串。
    static func append(entry: String, completion: @escaping (String) -> Void) {
        let id = todayID()
        NoteStore.shared.ensureNote(id)

        if let editor = NoteWindowManager.shared.editor(for: id) {
            editor.appendMarkdown(entry) { ok in
                completion(ok ? id : "")
            }
        } else {
            let ok = NoteStore.shared.appendText(entry, to: id)
            completion(ok ? id : "")
        }
    }

    /// 今日笔记里已经攒了多少条摘录（数二级标题）
    static func entryCount(_ content: String) -> Int {
        content.split(separator: "\n").filter { $0.hasPrefix("## ") }.count
    }
}
