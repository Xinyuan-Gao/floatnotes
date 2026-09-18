import AppKit

// MARK: - 附件垃圾回收

/// 笔记里删掉的图片，附件文件会变成孤儿。这里扫描所有笔记，
/// 把没有被引用的附件清理掉。
enum AttachmentGC {

    struct Result {
        var scannedNotes: Int
        var totalAttachments: Int
        var removed: Int
        var removedBytes: Int64
        var removedNames: [String]
    }

    /// dryRun = true 时只统计不删除
    static func collect(dryRun: Bool = false) -> Result {
        let store = NoteStore.shared
        let fm = FileManager.default

        // 1. 收集所有被引用的附件名
        var referenced = Set<String>()
        let notes = store.allNotes()
        for note in notes {
            for name in referencedAttachments(in: note.content) {
                referenced.insert(name)
            }
        }

        // 2. 列出附件目录
        let files = (try? fm.contentsOfDirectory(
            at: store.attachmentsDir,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var result = Result(scannedNotes: notes.count,
                            totalAttachments: files.count,
                            removed: 0, removedBytes: 0, removedNames: [])

        for file in files {
            let name = file.lastPathComponent
            guard !referenced.contains(name) else { continue }

            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if !dryRun {
                try? fm.removeItem(at: file)
            }
            result.removed += 1
            result.removedBytes += Int64(size)
            result.removedNames.append(name)
        }

        return result
    }

    /// 从 Markdown 里找出所有附件引用。
    /// 编辑器写出来的是 `![](floatnotes://media/xxx.png)`，
    /// 但用户也可能手写成相对路径 `attachments/xxx.png`，两种都认。
    static func referencedAttachments(in markdown: String) -> [String] {
        var names: [String] = []
        let patterns = [
            "floatnotes://media/",
            "attachments/"
        ]
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")

        for pattern in patterns {
            var searchRange = markdown.startIndex..<markdown.endIndex
            while let r = markdown.range(of: pattern, range: searchRange) {
                var i = r.upperBound
                var name = ""
                while i < markdown.endIndex, let scalar = markdown[i].unicodeScalars.first,
                      allowed.contains(scalar) {
                    name.unicodeScalars.append(scalar)
                    i = markdown.index(after: i)
                }
                if !name.isEmpty { names.append(name) }
                searchRange = i..<markdown.endIndex
            }
        }
        return names
    }
}

// MARK: - 导出

enum NoteExporter {

    /// HTML → RTF（富文本）
    static func rtfData(fromHTML html: String) -> Data? {
        guard let data = html.data(using: .utf8) else { return nil }
        guard let attr = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil
        ) else { return nil }

        return try? attr.data(
            from: NSRange(location: 0, length: attr.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }

    /// HTML → 纯文本
    static func plainText(fromHTML html: String) -> String? {
        guard let data = html.data(using: .utf8) else { return nil }
        guard let attr = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil
        ) else { return nil }
        return attr.string
    }

    /// 写到用户选定的位置
    static func write(_ data: Data, suggestedName: String, type: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(suggestedName).\(type)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            NSLog("[Export] 写入失败: \(error)")
            return nil
        }
    }

    /// 把 RTF 放进剪贴板（可以粘进飞书/Word 保留格式）
    static func copyRichText(html: String, plainFallback: String) {
        let pb = NSPasteboard.general
        pb.clearContents()

        if let rtf = rtfData(fromHTML: html) {
            pb.declareTypes([.rtf, .string], owner: nil)
            pb.setData(rtf, forType: .rtf)
            pb.setString(plainFallback, forType: .string)
        } else {
            pb.setString(plainFallback, forType: .string)
        }
    }
}

// MARK: - 搜索

struct SearchHit {
    var id: String
    var snippet: String
    var score: Int
    var modified: Date
}

enum NoteSearch {

    static func search(_ query: String, limit: Int = 30) -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }

        var hits: [SearchHit] = []
        for note in NoteStore.shared.allNotes() {
            let titleHit = note.id.range(of: q, options: .caseInsensitive) != nil
            let bodyHit = note.content.range(of: q, options: .caseInsensitive)

            guard titleHit || bodyHit != nil else { continue }

            var score = 0
            if titleHit { score += 100 }
            if bodyHit != nil { score += 10 }

            let snippetText = bodyHit.map { Self.snippet(around: $0, in: note.content, query: q) }
                ?? String(note.content.prefix(80))

            hits.append(SearchHit(id: note.id, snippet: snippetText,
                                  score: score, modified: note.modified))
        }

        return hits
            .sorted { ($0.score, $0.modified) > ($1.score, $1.modified) }
            .prefix(limit)
            .map { $0 }
    }

    /// 截取命中位置附近的一小段
    private static func snippet(around range: Range<String.Index>,
                                in text: String, query: String) -> String {
        let pad = 34
        let start = text.index(range.lowerBound, offsetBy: -pad,
                               limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: pad,
                             limitedBy: text.endIndex) ?? text.endIndex
        var s = String(text[start..<end])
        s = s.replacingOccurrences(of: "\n", with: " ")
        s = s.split(separator: " ").joined(separator: " ")
        return (start > text.startIndex ? "…" : "") + s + (end < text.endIndex ? "…" : "")
    }
}
