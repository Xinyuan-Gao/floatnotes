import AppKit
import ScreenCaptureKit

/// 屏幕截取。
///
/// 用 ScreenCaptureKit 的 `captureImage(in:)`（macOS 15.2+）——
/// 它直接吃「屏幕空间的一个矩形」，跨显示器通吃，一次调用出图，
/// 不用像 `SCStream` 那样配流。老的 `CGWindowListCreateImage` 在新 SDK 里
/// 已经标为 unavailable，用不了。
///
/// **坐标系**：入参是屏幕点坐标，原点是主屏左上角、y 向下（CG 惯例）。
/// 出图是显示器物理像素，Retina 上会是 2 倍尺寸。
enum ScreenCapture {

    // MARK: - 权限

    /// 是否已经有「屏幕录制」权限
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// 申请权限。第一次调用会弹系统提示；已经被拒绝过则只会跳到设置页。
    @discardableResult
    static func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// 打开「系统设置 › 隐私与安全性 › 屏幕录制」
    static func openPrivacySettings() {
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 截取

    /// 截取屏幕上的一个矩形（屏幕点坐标，左上原点）。
    ///
    /// 用 `SCContentFilter` + `SCStreamConfiguration` 这条路，
    /// 它从 macOS 14.0 就有；更省事的 `SCScreenshotManager.captureImage(in:)`
    /// 要 15.2+，为了保住 14 的兼容性没用它。
    static func capture(rect: CGRect, completion: @escaping (CGImage?) -> Void) {
        guard rect.width >= 1, rect.height >= 1 else { completion(nil); return }
        Task {
            let image = await captureAsync(rect: rect)
            await MainActor.run { completion(image) }
        }
    }

    private static func captureAsync(rect: CGRect) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            guard let display = content.displays.first(where: {
                $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY))
            }) ?? content.displays.first else {
                NSLog("[ScreenCapture] 找不到对应显示器")
                return nil
            }

            // sourceRect 是「相对于该显示器左上角」的点坐标
            let local = CGRect(x: rect.minX - display.frame.minX,
                               y: rect.minY - display.frame.minY,
                               width: rect.width,
                               height: rect.height)

            let scale = backingScale(forDisplayID: display.displayID)
            let config = SCStreamConfiguration()
            config.sourceRect = local
            config.width = max(1, Int(rect.width * scale))
            config.height = max(1, Int(rect.height * scale))
            config.showsCursor = false
            config.captureResolution = .best
            config.scalesToFit = false

            let filter = SCContentFilter(display: display, excludingWindows: [])
            return await withCheckedContinuation { cont in
                SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: config
                ) { image, error in
                    if let error {
                        NSLog("[ScreenCapture] 截取失败: \(error.localizedDescription)")
                    }
                    cont.resume(returning: image)
                }
            }
        } catch {
            NSLog("[ScreenCapture] 准备截取失败: \(error.localizedDescription)")
            return nil
        }
    }

    /// 把 CGDirectDisplayID 映射回 NSScreen，拿它的 Retina 倍率
    private static func backingScale(forDisplayID id: CGDirectDisplayID) -> CGFloat {
        for screen in NSScreen.screens {
            if let num = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber, num.uint32Value == id {
                return screen.backingScaleFactor
            }
        }
        return NSScreen.main?.backingScaleFactor ?? 2
    }

    /// 把 Cocoa 全局坐标（左下原点）的矩形换算成屏幕点坐标（左上原点）
    static func screenPointRect(fromCocoa rect: NSRect) -> CGRect {
        // CG 的原点在主屏左上角。Cocoa 的主屏 frame 是 {{0,0},{w,h}}（左下原点）。
        let mainMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: rect.origin.x,
                      y: mainMaxY - rect.origin.y - rect.height,
                      width: rect.width,
                      height: rect.height)
    }

    /// 把截图放进剪贴板。
    ///
    /// 必须**显式声明 `public.png`**，不能图省事直接 `writeObjects([nsImage])` ——
    /// 那样只会写 TIFF，而编辑器（BlockNote）是按 MIME 类型挑块类型的：
    /// 匹配不上 `image/*` 就会退化成「文件附件」而不是内嵌图片。
    /// 顺带给上 TIFF，粘到 Word / 飞书 之类的地方也认。
    static func copyToPasteboard(_ image: NSImage) {
        let pb = NSPasteboard.general
        pb.clearContents()

        let item = NSPasteboardItem()
        var wrote = false

        if let tiff = image.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
            wrote = true

            if let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                item.setData(png, forType: .png)
            }
        }
        guard wrote else { return }
        pb.writeObjects([item])
    }
}
