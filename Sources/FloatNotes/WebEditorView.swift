import AppKit
import WebKit

/// 承载块编辑器的 WKWebView 包装。
/// Swift ←→ JS 只走一条极简协议，方便以后把 BlockNote 换成 Lexical 或原生 NSTextView。
///
/// JS → Swift :
///   { type: "ready" }
///   { type: "change", markdown }
///   { type: "upload", id, name, mime, data }   粘贴图片，data 为 base64
///   { type: "log", text }
///
/// Swift → JS :
///   window.FloatNotes.load(markdown) / .setEditable(b) / .setFontSize(px)
///   window.FloatNotes.focus() / .exportNow() / ._uploadResult(id, filename)
final class WebEditorView: NSView {

    private(set) var webView: WKWebView!
    private var schemeHandler: EditorSchemeHandler?
    private var editorDir: URL?

    var onReady: (() -> Void)?
    var onChange: ((String) -> Void)?
    var onLog: ((String) -> Void)?
    /// 指针是否停在编辑区的空白处（由 JS 上报）
    var onBlankHover: ((Bool) -> Void)?

    private var isReady = false
    private var pendingLoad: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        let cfg = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        ucc.add(self, name: "floatnotes")
        cfg.userContentController = ucc
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true

        // ★ 自定义 scheme 必须在创建 WKWebView 之前注册
        if let dir = Self.locateEditorDir() {
            editorDir = dir
            let handler = EditorSchemeHandler(
                editorDir: dir,
                attachmentsDir: NoteStore.shared.attachmentsDir
            )
            cfg.setURLSchemeHandler(handler, forURLScheme: EditorSchemeHandler.scheme)
            schemeHandler = handler
        }

        webView = WKWebView(frame: bounds, configuration: cfg)
        webView.autoresizingMask = [.width, .height]
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        addSubview(webView)

        loadEditor()
    }

    // MARK: - 资源定位

    /// 依次尝试：环境变量 → .app bundle → 源码目录（方便 swift run 调试）
    private static func locateEditorDir() -> URL? {
        func hasIndex(_ dir: URL) -> Bool {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("index.html").path)
        }

        if let env = ProcessInfo.processInfo.environment["FLOATNOTES_EDITOR_DIR"] {
            let u = URL(fileURLWithPath: env)
            if hasIndex(u) { return u }
        }
        if let idx = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "editor") {
            return idx.deletingLastPathComponent()
        }
        let sourceRelative = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Sources/FloatNotes
            .deletingLastPathComponent()      // Sources
            .deletingLastPathComponent()      // spike
            .appendingPathComponent("editor-src/dist")
        if hasIndex(sourceRelative) { return sourceRelative }

        let cwdRelative = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("editor-src/dist")
        return hasIndex(cwdRelative) ? cwdRelative : nil
    }

    private func loadEditor() {
        guard editorDir != nil else {
            onLog?("[editor] ✗ 找不到编辑器资源（index.html）")
            return
        }
        guard let url = URL(string: "\(EditorSchemeHandler.scheme)://editor/index.html") else { return }
        onLog?("[editor] 加载 \(url.absoluteString)")
        webView.load(URLRequest(url: url))
    }

    // MARK: - Swift → JS

    func load(markdown: String) {
        guard isReady else { pendingLoad = markdown; return }
        evaluate("window.FloatNotes && void window.FloatNotes.load(\(Self.jsString(markdown)));")
    }

    func setEditable(_ editable: Bool) {
        evaluate("void (window.FloatNotes && window.FloatNotes.setEditable(\(editable)));")
    }

    func setFontSize(_ size: Double) {
        evaluate("void (window.FloatNotes && window.FloatNotes.setFontSize(\(size)));")
    }

    /// 往文档末尾追加一段 Markdown（今日笔记用）
    func appendMarkdown(_ markdown: String, completion: @escaping (Bool) -> Void) {
        evaluate("window.FloatNotes._startAppend(\(Self.jsString(markdown)));") { _ in
            self.pollAppend(attempt: 0, completion: completion)
        }
    }

    private func pollAppend(attempt: Int, completion: @escaping (Bool) -> Void) {
        if attempt > 25 { completion(false); return }
        evaluate("window.__fnAppend ? JSON.stringify(window.__fnAppend) : 'null'") { [weak self] raw in
            guard let self else { return }
            guard let s = raw as? String, s != "null",
                  let d = s.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  (o["done"] as? Bool) == true else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.pollAppend(attempt: attempt + 1, completion: completion)
                }
                return
            }
            completion(o["ok"] as? Bool ?? false)
        }
    }

    /// 正文字体（CSS font-family）
    func setFontFamily(_ css: String) {
        evaluate("void (window.FloatNotes && window.FloatNotes.setFontFamily(\(Self.jsString(css))));")
    }

    /// mode: "auto" | "light" | "dark"
    func setTheme(_ mode: String) {
        evaluate("void (window.FloatNotes && window.FloatNotes.setTheme(\(Self.jsString(mode))));")
    }

    func focusEditor() {
        evaluate("window.FloatNotes && window.FloatNotes.focus();")
        window?.makeFirstResponder(webView)
    }

    func requestExport() {
        evaluate("window.FloatNotes && void window.FloatNotes.exportNow();")
    }

    /// 让 WKWebView 自己把页面渲染成图片。
    /// 这条路不需要「屏幕录制」权限，因为内容是 WebKit 自己画的，不是截屏。
    func snapshot(completion: @escaping (NSImage?) -> Void) {
        let cfg = WKSnapshotConfiguration()
        cfg.rect = webView.bounds
        webView.takeSnapshot(with: cfg) { image, error in
            if let error { self.onLog?("[snapshot] 失败: \(error.localizedDescription)") }
            completion(image)
        }
    }

    /// 在编辑器里执行任意 JS 并把结果回传（自检 / 调试用）
    func evaluate(_ js: String, completion: ((Any?) -> Void)? = nil) {
        webView.evaluateJavaScript(js) { [weak self] result, error in
            if let error {
                self?.onLog?("[editor] JS 执行出错: \(error.localizedDescription)")
            }
            completion?(result)
        }
    }

    /// 执行一段可以返回 Promise 的 JS。
    /// `evaluateJavaScript` 拿到 Promise 对象会报 "unsupported type"，
    /// 必须用 `callAsyncJavaScript` 才能正确 await 出结果。
    /// （该方法标了 NS_REFINED_FOR_SWIFT，Swift 侧只有 async 版本，没有 completionHandler 版本。）
    func evaluateAsync(_ body: String,
                       arguments: [String: Any] = [:],
                       completion: @escaping (Any?) -> Void) {
        Task { @MainActor in
            do {
                let value = try await webView.callAsyncJavaScript(
                    body, arguments: arguments, in: nil, in: .page
                )
                completion(value)
            } catch {
                self.onLog?("[editor] JS 异步执行出错: \(error.localizedDescription)")
                completion(nil)
            }
        }
    }

    static func jsString(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s], options: [])
        let arr = String(data: data, encoding: .utf8)!
        return String(arr.dropFirst().dropLast())   // 去掉外层 [ ]
    }
}

extension WebEditorView: WKScriptMessageHandler {

    func userContentController(_ ucc: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        switch type {
        case "ready":
            isReady = true
            onLog?("[editor] ✓ 编辑器就绪")
            onReady?()
            if let pending = pendingLoad {
                pendingLoad = nil
                load(markdown: pending)
            }

        case "change":
            onChange?(body["markdown"] as? String ?? "")

        case "blankHover":
            onBlankHover?(body["blank"] as? Bool ?? false)

        case "upload":
            handleUpload(body)

        case "log":
            onLog?("[editor] \(body["text"] as? String ?? "")")

        default:
            break
        }
    }

    /// 图片粘贴：JS 把文件读成 base64 传过来，这里落盘到附件目录，
    /// 再把文件名回传给编辑器（编辑器拼成 floatnotes://media/<名> 显示）。
    private func handleUpload(_ body: [String: Any]) {
        let id = body["id"] as? String ?? ""
        guard let b64 = body["data"] as? String,
              let data = Data(base64Encoded: b64) else {
            onLog?("[editor] 附件解码失败")
            replyUpload(id: id, filename: nil)
            return
        }
        let filename = NoteStore.shared.saveAttachment(
            data: data,
            preferredName: body["name"] as? String,
            mime: body["mime"] as? String
        )
        onLog?("[editor] 附件已保存 \(filename ?? "失败")（\(data.count) 字节）")
        replyUpload(id: id, filename: filename)
    }

    private func replyUpload(id: String, filename: String?) {
        let arg = filename.map { Self.jsString($0) } ?? "null"
        evaluate("window.FloatNotes && window.FloatNotes._uploadResult("
                 + "\(Self.jsString(id)), \(arg));")
    }
}
