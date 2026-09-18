import WebKit

/// 自定义 URL scheme：`floatnotes://`
///
///   floatnotes://editor/index.html    → App 内置的编辑器页面
///   floatnotes://media/<文件名>        → 笔记附件目录里的图片
///
/// 为什么需要它：粘贴图片后编辑器要把图片显示出来，而图片存在
/// `~/Documents/悬浮笔记/attachments/`，在 `file://` 页面里既跨了目录
/// 又受 WebKit 的本地文件读取限制。走自定义 scheme 就没有这些约束，
/// 也不用起本地 HTTP 服务。
final class EditorSchemeHandler: NSObject, WKURLSchemeHandler {

    static let scheme = "floatnotes"

    private let editorDir: URL
    private let attachmentsDir: URL

    init(editorDir: URL, attachmentsDir: URL) {
        self.editorDir = editorDir
        self.attachmentsDir = attachmentsDir
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(fail("请求无 URL"))
            return
        }

        let root: URL
        switch url.host {
        case "editor": root = editorDir
        case "media":  root = attachmentsDir
        default:
            task.didFailWithError(fail("未知 host: \(url.host ?? "nil")"))
            return
        }

        // 防目录穿越
        let relative = url.path.removingPercentEncoding ?? url.path
        let target = root.appendingPathComponent(relative).standardizedFileURL
        guard target.path.hasPrefix(root.standardizedFileURL.path) else {
            task.didFailWithError(fail("路径越界: \(relative)"))
            return
        }

        guard let data = try? Data(contentsOf: target) else {
            let resp = HTTPURLResponse(url: url, statusCode: 404,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
            task.didReceive(resp)
            task.didReceive(Data())
            task.didFinish()
            return
        }

        let resp = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": Self.mimeType(for: target.pathExtension),
                "Content-Length": "\(data.count)",
                "Cache-Control": "no-cache",
                // 自定义 scheme 下 editor 与 media 属于不同 origin，
                // 不加这个头的话 JS 里的 fetch() 会被 CORS 挡掉
                "Access-Control-Allow-Origin": "*"
            ]
        )!
        task.didReceive(resp)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        // 同步读取，无需处理
    }

    private func fail(_ reason: String) -> NSError {
        NSLog("[Scheme] \(reason)")
        return NSError(domain: Self.scheme, code: 1,
                       userInfo: [NSLocalizedDescriptionKey: reason])
    }

    static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs":   return "text/javascript; charset=utf-8"
        case "css":         return "text/css; charset=utf-8"
        case "json":        return "application/json; charset=utf-8"
        case "svg":         return "image/svg+xml"
        case "png":         return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif":         return "image/gif"
        case "webp":        return "image/webp"
        case "heic":        return "image/heic"
        case "bmp":         return "image/bmp"
        case "tiff":        return "image/tiff"
        case "pdf":         return "application/pdf"
        default:            return "application/octet-stream"
        }
    }
}
