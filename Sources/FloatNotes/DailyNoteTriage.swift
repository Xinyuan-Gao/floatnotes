import AppKit

/// 今日笔记里的一条摘录
struct DailyEntry: Identifiable, Hashable {
    let raw: String        // 完整原始块（含 ## 标题行）
    let heading: String    // "## 10:57 · 标题"
    let time: String       // "10:57"，没有则为空
    let title: String
    let url: String?
    let preview: String

    var id: String { raw }
}

struct ParsedDaily {
    var header: String = ""
    var entries: [DailyEntry] = []
}

/// 今日笔记的解析与归档。
///
/// 今日笔记本质是一个「收件箱」：读文章时往里丢，读完再逐条归档到主题笔记。
/// 归档会把条目从今日笔记**移走**（收件箱清空），并在目标笔记里保留
/// 日期与时间的出处信息。
enum DailyNoteTriage {

    // MARK: - 解析

    static func parse(_ content: String) -> ParsedDaily {
        var result = ParsedDaily()
        var headerLines: [String] = []
        var current: [String] = []
        var inEntries = false

        func flush() {
            guard !current.isEmpty else { return }
            let raw = current.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            current = []
            guard !raw.isEmpty, let e = makeEntry(raw) else { return }
            result.entries.append(e)
        }

        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = String(line)
            if l.hasPrefix("## ") {
                if !inEntries {
                    result.header = headerLines.joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    inEntries = true
                }
                flush()
                current.append(l)
            } else if inEntries {
                current.append(l)
            } else {
                headerLines.append(l)
            }
        }
        flush()
        return result
    }

    private static func makeEntry(_ raw: String) -> DailyEntry? {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let heading = lines.first, heading.hasPrefix("## ") else { return nil }

        let rest = String(heading.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        var time = ""
        var title = rest
        if let r = rest.range(of: " · ") {
            time = String(rest[rest.startIndex..<r.lowerBound])
            title = String(rest[r.upperBound...])
        }

        let body = lines.dropFirst().joined(separator: "\n")
        return DailyEntry(raw: raw, heading: heading, time: time, title: title,
                          url: firstURL(in: body), preview: makePreview(body))
    }

    /// 从 `[文字](https://...)` 里取出 URL
    private static func firstURL(in body: String) -> String? {
        guard let r = body.range(of: "](http") else { return nil }
        let start = body.index(r.lowerBound, offsetBy: 2)
        guard let end = body[start...].firstIndex(of: ")") else { return nil }
        let url = String(body[start..<end])
        return url.hasPrefix("http") ? url : nil
    }

    private static func makePreview(_ body: String) -> String {
        var parts: [String] = []
        for line in body.split(separator: "\n") {
            var t = String(line).trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix(">") else { continue }
            t = String(t.dropFirst()).trimmingCharacters(in: .whitespaces)
            // 去掉常见 markdown 标记，预览更干净
            for marker in ["**", "`", "*", "__"] {
                t = t.replacingOccurrences(of: marker, with: "")
            }
            if !t.isEmpty { parts.append(t) }
        }
        let joined = parts.joined(separator: " ")
        return joined.count > 90 ? String(joined.prefix(90)) + "…" : joined
    }

    // MARK: - 归档

    struct ArchiveResult {
        var moved: Int
        var failed: Int
        var targetID: String
    }

    /// 把条目从今日笔记移到目标笔记
    @discardableResult
    static func archive(entries: [DailyEntry],
                        from dailyID: String,
                        to targetID: String,
                        dateString: String) -> ArchiveResult {
        let store = NoteStore.shared
        store.flush()   // 先把编辑器里没落盘的输入写下去，否则会被覆盖

        // 1) 从今日笔记里摘掉这些块
        var daily = store.load(dailyID)
        var moved = 0
        for e in entries {
            if daily.contains(e.raw) {
                daily = removeBlock(e.raw, from: daily)
                moved += 1
            }
        }
        let okDaily = store.replaceAll(dailyID, with: daily)

        // 2) 追加到目标笔记（标题带上日期，保留出处）
        var addition = ""
        for e in entries {
            addition += reheaded(e, dateString: dateString) + "\n"
        }
        let okTarget = store.appendText(addition, to: targetID)

        return ArchiveResult(moved: moved,
                             failed: (okDaily && okTarget) ? 0 : entries.count,
                             targetID: targetID)
    }

    /// 追加内容到目标笔记时，把 "## 10:57 · 标题" 改成 "## 2026-09-18 10:57 · 标题"
    private static func reheaded(_ e: DailyEntry, dateString: String) -> String {
        let newHeading: String
        if e.time.isEmpty {
            newHeading = "## \(dateString) · \(e.title)"
        } else {
            newHeading = "## \(dateString) \(e.time) · \(e.title)"
        }
        let body = e.raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .dropFirst()
            .joined(separator: "\n")
        return newHeading + "\n" + body
    }

    /// 从今日笔记里删掉若干条目（删除功能用）
    static func remove(entries: [DailyEntry], from content: String) -> String {
        var result = content
        for e in entries { result = removeBlock(e.raw, from: result) }
        return result
    }

    private static func removeBlock(_ raw: String, from content: String) -> String {
        guard let r = content.range(of: raw) else { return content }
        var result = content
        result.removeSubrange(r)
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        if !result.hasSuffix("\n") { result += "\n" }
        return result
    }
}
