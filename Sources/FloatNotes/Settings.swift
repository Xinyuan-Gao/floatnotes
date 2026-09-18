import AppKit
import ServiceManagement

/// 全局设置。用 UserDefaults 持久化，变更时发通知让各窗口实时响应。
final class Settings {

    static let shared = Settings()
    static let didChange = Notification.Name("FloatNotesSettingsDidChange")

    private let d = UserDefaults.standard

    private init() {
        d.register(defaults: [
            "coverMenuBar": false,
            "showFloatingBall": true,
            "ballEdge": "right",
            "launchAtLogin": false,
            "collapseOnLaunch": true,
            "noteFontSize": 16.0,
            "noteFontFamily": "system",
            "captureMode": "daily",
            "showInDock": true
        ])
    }

    private func notify() {
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    // MARK: - 置顶层级

    /// 是否让笔记盖住菜单栏和 Dock。
    /// false → .floating(3)：在普通窗口之上，但在菜单栏/Dock 之下（不打扰系统 UI）
    /// true  → .statusBar(25)：连菜单栏一起盖住
    var coverMenuBar: Bool {
        get { d.bool(forKey: "coverMenuBar") }
        set { d.set(newValue, forKey: "coverMenuBar"); notify() }
    }

    var panelLevel: PanelLevel { coverMenuBar ? .statusBar : .floating }

    /// 是否在程序坞（Dock）和 ⌘Tab 里显示。
    /// 关掉就是纯菜单栏 App（更安静）；打开则像个普通 App，更好找。
    var showInDock: Bool {
        get { d.bool(forKey: "showInDock") }
        set { d.set(newValue, forKey: "showInDock"); notify() }
    }

    // MARK: - 悬浮球

    var showFloatingBall: Bool {
        get { d.bool(forKey: "showFloatingBall") }
        set { d.set(newValue, forKey: "showFloatingBall"); notify() }
    }

    /// "left" 或 "right"
    var ballEdge: String {
        get { d.string(forKey: "ballEdge") ?? "right" }
        set { d.set(newValue, forKey: "ballEdge"); notify() }
    }

    // MARK: - 启动行为

    var collapseOnLaunch: Bool {
        get { d.bool(forKey: "collapseOnLaunch") }
        set { d.set(newValue, forKey: "collapseOnLaunch"); notify() }
    }

    var launchAtLogin: Bool {
        get { LaunchAtLogin.isEnabled }
        set {
            let ok = LaunchAtLogin.setEnabled(newValue)
            d.set(newValue && ok, forKey: "launchAtLogin")
            notify()
        }
    }

    /// 开机自启是否可用（未正式签名/未放到 Applications 时会失败）
    var launchAtLoginAvailable: Bool { LaunchAtLogin.isAvailable }

    // MARK: - 编辑器

    var noteFontSize: Double {
        get { d.double(forKey: "noteFontSize") }
        set { d.set(newValue, forKey: "noteFontSize"); notify() }
    }

    /// 正文字体（FontCatalog 的 key）
    var noteFontFamily: String {
        get { d.string(forKey: "noteFontFamily") ?? "system" }
        set { d.set(newValue, forKey: "noteFontFamily"); notify() }
    }

    // MARK: - 划词捕获行为

    /// "daily" = 静默存入今日笔记（默认，不打断阅读）
    /// "window" = 每条摘录弹一个新窗口
    var captureMode: String {
        get { d.string(forKey: "captureMode") ?? "daily" }
        set { d.set(newValue, forKey: "captureMode"); notify() }
    }

    var captureToDailyNote: Bool { captureMode == "daily" }

    // MARK: - 每笔记外观（按笔记 ID 独立记忆）

    func opacity(for id: String) -> Double {
        guard let v = d.object(forKey: "opacity.\(id)") as? Double else { return 1.0 }
        return min(max(v, 0.35), 1.0)
    }

    func setOpacity(_ v: Double, for id: String) {
        d.set(min(max(v, 0.35), 1.0), forKey: "opacity.\(id)")
        notify()
    }

    /// "auto" | "light" | "dark"
    func theme(for id: String) -> String {
        d.string(forKey: "theme.\(id)") ?? "auto"
    }

    func setTheme(_ t: String, for id: String) {
        d.set(["auto", "light", "dark"].contains(t) ? t : "auto", forKey: "theme.\(id)")
        notify()
    }

    // MARK: - 笔记背景

    /// 全局默认背景（BackgroundCatalog 的 key）
    var noteBackground: String {
        get { d.string(forKey: "noteBackground") ?? "none" }
        set { d.set(newValue, forKey: "noteBackground"); notify() }
    }

    /// 某篇笔记实际用的背景：它自己有覆盖就用它自己的，否则跟随全局
    func background(for id: String) -> String {
        d.string(forKey: "bg.\(id)") ?? noteBackground
    }

    /// 这篇笔记是不是单独设过背景
    func hasOwnBackground(_ id: String) -> Bool {
        d.object(forKey: "bg.\(id)") != nil
    }

    /// 给单篇设背景；传 nil 表示「跟随全局」
    func setBackground(_ key: String?, for id: String) {
        if let key {
            d.set(key, forKey: "bg.\(id)")
        } else {
            d.removeObject(forKey: "bg.\(id)")
        }
        notify()
    }

    // MARK: - 首次启动

    var hasOnboarded: Bool {
        get { d.bool(forKey: "hasOnboarded") }
        set { d.set(newValue, forKey: "hasOnboarded") }
    }
}

// MARK: - 开机自启

enum LaunchAtLogin {

    static var isAvailable: Bool {
        // 未打包运行（swift run）时没有 bundle 标识，直接不可用
        Bundle.main.bundleIdentifier != nil
    }

    static var isEnabled: Bool {
        guard isAvailable else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    /// 返回是否设置成功
    @discardableResult
    static func setEnabled(_ on: Bool) -> Bool {
        guard isAvailable else {
            NSLog("[LaunchAtLogin] 无 bundle id，跳过")
            return false
        }
        do {
            if on {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            return true
        } catch {
            // 常见原因：App 不在 /Applications 下，或未用开发者证书签名
            NSLog("[LaunchAtLogin] 设置失败: \(error.localizedDescription)")
            return false
        }
    }

    /// 给用户看的状态说明
    static var statusDescription: String {
        guard isAvailable else { return "不可用（未打包运行）" }
        switch SMAppService.mainApp.status {
        case .enabled: return "已开启"
        case .notRegistered: return "未开启"
        case .requiresApproval: return "需要在「系统设置 › 通用 › 登录项」中批准"
        case .notFound: return "不可用（请把 App 移到「应用程序」文件夹）"
        @unknown default: return "未知状态"
        }
    }
}
