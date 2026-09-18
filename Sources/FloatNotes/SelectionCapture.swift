import AppKit
import ApplicationServices

/// 一次「划词捕获」的结果
struct CapturedSelection {
    var text: String
    var sourceApp: String?
    var sourceTitle: String?
    var sourceURL: String?
    var method: String          // "AX" 或 "剪贴板"
    var capturedAt: Date = Date()
}

/// 从任意 App 捕获当前选中的文字与来源信息。
///
/// 主路径走 macOS 辅助功能 API（AXUIElement），能同时拿到选中文字、
/// 窗口标题，以及浏览器/阅读器暴露的文档 URL。
/// 拿不到文字时退回「模拟 ⌘C + 读剪贴板」，并会还原用户原来的剪贴板内容。
enum SelectionCapture {

    // AX 属性名直接用字符串常量，绕开 CFString/String 的类型差异
    private static let attrFocusedElement = "AXFocusedUIElement" as CFString
    private static let attrFocusedWindow  = "AXFocusedWindow" as CFString
    private static let attrSelectedText   = "AXSelectedText" as CFString
    private static let attrDocument       = "AXDocument" as CFString
    private static let attrURL            = "AXURL" as CFString
    private static let attrTitle          = "AXTitle" as CFString
    private static let attrParent         = "AXParent" as CFString

    // MARK: - 权限

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// 弹出系统授权引导（会跳到「系统设置 › 隐私与安全性 › 辅助功能」）
    @discardableResult
    static func requestPermission() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - 捕获

    static func capture(allowClipboardFallback: Bool = true) -> CapturedSelection? {
        let front = NSWorkspace.shared.frontmostApplication
        let appName = front?.localizedName

        // 如果前台就是我们自己，模拟 ⌘C 只会去复制我们自己的内容
        // （WKWebView 甚至会把整页复制成 web archive），
        // 既没有意义，还会把用户的剪贴板冲掉。直接不兜底。
        let isSelf = front?.bundleIdentifier == Bundle.main.bundleIdentifier
        let mayUseClipboard = allowClipboardFallback && !isSelf

        if let (text, element) = axSelectedText(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let title = element.flatMap { windowTitle(from: $0) }
            let url = element.flatMap { documentURL(from: $0) }
            return CapturedSelection(text: text, sourceApp: appName,
                                     sourceTitle: title, sourceURL: url, method: "AX")
        }

        if mayUseClipboard, let text = clipboardSelection(),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let window = axFocusedWindow()
            let title = window.flatMap { copyAttr($0, attrTitle) as? String }
            let url = window.flatMap { documentURL(from: $0) }
            return CapturedSelection(text: text, sourceApp: appName,
                                     sourceTitle: title, sourceURL: url, method: "剪贴板")
        }

        return nil
    }

    // MARK: - AX 主路径

    private static func axSelectedText() -> (String, AXUIElement?)? {
        let system = AXUIElementCreateSystemWide()
        guard let focused = copyAttr(system, attrFocusedElement) else { return nil }
        let element = unsafeBitCast(focused, to: AXUIElement.self)
        guard let text = copyAttr(element, attrSelectedText) as? String else { return nil }
        return (text, element)
    }

    private static func axFocusedWindow() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        guard let w = copyAttr(system, attrFocusedWindow) else { return nil }
        return unsafeBitCast(w, to: AXUIElement.self)
    }

    /// 从元素往上找，直到找到暴露文档 URL 的祖先（浏览器一般挂在 web area / window 上）
    private static func documentURL(from element: AXUIElement, depth: Int = 0) -> String? {
        guard depth < 10 else { return nil }

        for attr in [attrDocument, attrURL] {
            if let v = copyAttr(element, attr) {
                if let s = v as? String, !s.isEmpty, s.hasPrefix("http") { return s }
                if let u = v as? URL, !u.absoluteString.isEmpty { return u.absoluteString }
            }
        }

        guard let parent = copyAttr(element, attrParent) else { return nil }
        return documentURL(from: unsafeBitCast(parent, to: AXUIElement.self), depth: depth + 1)
    }

    /// 往上找窗口标题
    private static func windowTitle(from element: AXUIElement) -> String? {
        if let t = copyAttr(element, attrTitle) as? String, !t.isEmpty { return t }
        var current: AXUIElement? = element
        for _ in 0..<10 {
            guard let el = current, let parent = copyAttr(el, attrParent) else { break }
            let p = unsafeBitCast(parent, to: AXUIElement.self)
            if let t = copyAttr(p, attrTitle) as? String, !t.isEmpty { return t }
            current = p
        }
        return nil
    }

    private static func copyAttr(_ element: AXUIElement, _ attr: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attr, &value)
        return err == .success ? value : nil
    }

    // MARK: - 剪贴板兜底

    /// 模拟 ⌘C 取选中内容，并把用户原本的剪贴板还原回去。
    private static func clipboardSelection() -> String? {
        let pb = NSPasteboard.general
        let savedCount = pb.changeCount
        let savedItems = PasteboardSnapshot.capture()

        postCommandC()

        // 等剪贴板真的变掉（最多 0.4 秒）
        var waited = 0.0
        while pb.changeCount == savedCount && waited < 0.4 {
            usleep(20_000)
            waited += 0.02
        }

        guard pb.changeCount != savedCount else {
            PasteboardSnapshot.restore(savedItems)
            return nil
        }

        // ★ 再等一小会儿再读、再还原。
        //   ⌘C 的剪贴板写入是「异步」的（WKWebView 要经 web 进程转发），
        //   changeCount 变了只说明有人开始写，不代表数据已经落定。
        //   立刻还原的话，会被那个迟到的写入覆盖掉 —— 表现就是剪贴板被清空。
        usleep(200_000)

        let text = pb.string(forType: .string)
        PasteboardSnapshot.restore(savedItems)

        // ⌘C 的落地时间可能比想象中晚得多（WKWebView 要经 web 进程，
        // 实测能拖到一秒以上）。这里隔一段时间再确认一次，
        // 被覆盖就再还一次 —— 用户原来的剪贴板不能被我们弄丢。
        scheduleRestoreCheck(savedItems)
        return text

    }

    /// 延迟复查：迟到的写入盖掉了就再还原一次
    private static func scheduleRestoreCheck(_ savedItems: PasteboardSnapshot.Items) {
        guard let want = savedItems.first?[.string].flatMap({ String(data: $0, encoding: .utf8) })
        else { return }
        for delay in [0.6, 1.5, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if NSPasteboard.general.string(forType: .string) != want {
                    PasteboardSnapshot.restore(savedItems)
                }
            }
        }
    }

    private static func postCommandC() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyC: CGKeyCode = 0x08   // 'c'
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyC, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyC, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }
}

// MARK: - 变成笔记内容

enum SelectionNote {

    /// 把捕获结果拼成 Markdown。纯函数，方便自检。
    static func markdown(for sel: CapturedSelection) -> String {
        var lines: [String] = []

        // 选中内容做成引用块
        let body = sel.text.trimmingCharacters(in: .whitespacesAndNewlines)
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            lines.append(t.isEmpty ? ">" : "> \(t)")
        }
        lines.append("")

        // 来源行
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        let stamp = f.string(from: sel.capturedAt)

        var source: [String] = []
        if let title = sel.sourceTitle, !title.isEmpty {
            if let url = sel.sourceURL, !url.isEmpty {
                source.append("摘自 [\(title)](\(url))")
            } else {
                source.append("摘自《\(title)》")
            }
        } else if let url = sel.sourceURL, !url.isEmpty {
            source.append("摘自 \(url)")
        }
        if let app = sel.sourceApp, !app.isEmpty {
            source.append("via \(app)")
        }
        source.append(stamp)

        lines.append(source.joined(separator: " · "))
        lines.append("")

        return lines.joined(separator: "\n")
    }

    /// 笔记标题：取来源标题或选中内容首行
    static func noteTitle(for sel: CapturedSelection) -> String {
        let raw: String
        if let t = sel.sourceTitle, !t.isEmpty {
            raw = String(t.prefix(24))
        } else {
            let first = sel.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n").first.map(String.init) ?? "摘录"
            raw = String(first.prefix(16))
        }
        return "摘录-" + sanitize(raw)
    }

    /// 文件名合法化：去掉路径分隔符与控制字符，压缩空白
    static func sanitize(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let cleaned = s.unicodeScalars
            .map { bad.contains($0) ? " " : Character($0) }
            .reduce(into: "") { $0.append($1) }
        let collapsed = cleaned.split(separator: " ").joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "未命名" : String(trimmed.prefix(40))
    }
}
