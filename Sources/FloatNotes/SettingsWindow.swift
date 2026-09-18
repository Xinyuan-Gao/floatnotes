import SwiftUI
import AppKit

extension Notification.Name {
    static let floatNotesResetBall = Notification.Name("floatNotesResetBall")
}

/// 设置项的 SwiftUI 模型：读写都落到 Settings（UserDefaults）
final class SettingsModel: ObservableObject {
    @Published var coverMenuBar: Bool        { didSet { Settings.shared.coverMenuBar = coverMenuBar } }
    @Published var showFloatingBall: Bool    { didSet { Settings.shared.showFloatingBall = showFloatingBall } }
    @Published var ballEdge: String          { didSet { Settings.shared.ballEdge = ballEdge } }
    @Published var collapseOnLaunch: Bool    { didSet { Settings.shared.collapseOnLaunch = collapseOnLaunch } }
    @Published var launchAtLogin: Bool       { didSet { Settings.shared.launchAtLogin = launchAtLogin } }
    @Published var noteFontSize: Double      { didSet { Settings.shared.noteFontSize = noteFontSize } }
    @Published var noteFontFamily: String    { didSet { Settings.shared.noteFontFamily = noteFontFamily } }
    @Published var captureMode: String       { didSet { Settings.shared.captureMode = captureMode } }
    @Published var showInDock: Bool          { didSet { Settings.shared.showInDock = showInDock } }

    @Published var launchAtLoginNote: String = LaunchAtLogin.statusDescription

    init() {
        let s = Settings.shared
        coverMenuBar = s.coverMenuBar
        showFloatingBall = s.showFloatingBall
        ballEdge = s.ballEdge
        collapseOnLaunch = s.collapseOnLaunch
        launchAtLogin = s.launchAtLogin
        noteFontSize = s.noteFontSize
        noteFontFamily = s.noteFontFamily
        captureMode = s.captureMode
        showInDock = s.showInDock
    }

    func refreshLoginStatus() {
        launchAtLoginNote = LaunchAtLogin.statusDescription
        launchAtLogin = Settings.shared.launchAtLogin
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Toggle("盖住菜单栏和程序坞", isOn: $model.coverMenuBar)
                Text(model.coverMenuBar
                     ? "笔记会浮在菜单栏和 Dock 之上，真正做到「谁也别想挡住我」。"
                     : "笔记浮在所有普通窗口之上，但会让开菜单栏和 Dock。推荐日常使用。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Label("置顶行为", systemImage: "pin.fill")
            }

            Section {
                Toggle("在程序坞中显示图标", isOn: $model.showInDock)
                Text(model.showInDock
                     ? "有 Dock 图标，也能用 ⌘Tab 切过来，更容易找到这个 App。"
                     : "纯菜单栏 App，不占 Dock、不进 ⌘Tab，更安静。")
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("显示悬浮球", isOn: $model.showFloatingBall)
                Text("随时按 ⌥⌘B 隐藏 / 显示；也可以右键悬浮球，或从菜单栏里切。")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("贴边位置", selection: $model.ballEdge) {
                    Text("屏幕右侧").tag("right")
                    Text("屏幕左侧").tag("left")
                }
                .pickerStyle(.segmented)
                .disabled(!model.showFloatingBall)
                Button("把悬浮球移回边缘") {
                    NotificationCenter.default.post(name: .floatNotesResetBall, object: nil)
                }
                .disabled(!model.showFloatingBall)
                Text("悬浮球可以拖到屏幕任意位置，靠近左右边缘时会自动吸附。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Label("启动按钮", systemImage: "circle.circle")
            }

            Section {
                Toggle("开机自动启动", isOn: $model.launchAtLogin)
                    .onChange(of: model.launchAtLogin) { _, _ in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            model.refreshLoginStatus()
                        }
                    }
                if !model.launchAtLoginNote.isEmpty {
                    Text(model.launchAtLoginNote)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("启动时收起全部笔记", isOn: $model.collapseOnLaunch)
                Text("避免上次留下的窗口铺满屏幕。随时可以用 ⌥⌘H 或 ⌥⌘R 展开。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Label("启动", systemImage: "power")
            }

            Section {
                HStack {
                    Text("正文字号")
                    Slider(value: $model.noteFontSize, in: 12...26, step: 1)
                    Text("\(Int(model.noteFontSize)) pt")
                        .monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                Picker("正文字体", selection: $model.noteFontFamily) {
                    ForEach(FontCatalog.all, id: \.key) { f in
                        Text(f.label).tag(f.key)
                    }
                }
                // 实时预览
                VStack(alignment: .leading, spacing: 4) {
                    Text("预览：读书笔记，笔记读书。")
                        .font(.custom(FontCatalog.previewFont(for: model.noteFontFamily)
                                      ?? ".AppleSystemUIFont",
                                      size: model.noteFontSize))
                    Text("The quick brown fox · 0123456789")
                        .font(.custom(FontCatalog.previewFont(for: model.noteFontFamily)
                                      ?? ".AppleSystemUIFont",
                                      size: max(11, model.noteFontSize - 3)))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } header: {
                Label("编辑器 · 字体", systemImage: "textformat.size")
            }

            Section {
                Picker("划词后", selection: $model.captureMode) {
                    Text("静默存入今日笔记").tag("daily")
                    Text("弹出新窗口").tag("window")
                }
                .pickerStyle(.radioGroup)
                Text(model.captureMode == "daily"
                     ? "选中文字按 ⌥⌘E，直接追加到当天那一篇，只弹一个小提示，不打断你读文章。读完用 ⌥⌘T 打开今日笔记统一整理。"
                     : "每摘录一条就开一个新窗口。适合边读边展开写的情况。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Label("划词捕获", systemImage: "scissors")
            }

            Section {
                HStack {
                    Button("打开笔记文件夹") {
                        NSWorkspace.shared.open(NoteStore.shared.root)
                    }
                    Button("打开附件文件夹") {
                        NSWorkspace.shared.open(NoteStore.shared.attachmentsDir)
                    }
                }
                Text(NoteStore.shared.root.path)
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } header: {
                Label("存储位置", systemImage: "folder")
            }

            Section {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    shortcutRow("⌥⌘E", "划词捕获（存入今日笔记 / 弹窗）")
                    shortcutRow("⌥⌘T", "打开今日笔记")
                    shortcutRow("⌥⌘N", "新建笔记")
                    shortcutRow("⌥⌘H", "显示 / 隐藏全部笔记")
                    shortcutRow("⌥⌘R", "全部收起 / 展开")
                    shortcutRow("⌥⌘L", "切换置顶层级")
                }
            } header: {
                Label("快捷键", systemImage: "keyboard")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 760)
        .onAppear { model.refreshLoginStatus() }
    }

    private func shortcutRow(_ key: String, _ desc: String) -> some View {
        GridRow {
            Text(key)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
            Text(desc).foregroundStyle(.secondary)
        }
    }
}

/// 设置窗口控制器
final class SettingsWindowController {

    static let shared = SettingsWindowController()
    private var window: NSWindow?
    private let model = SettingsModel()

    func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView(model: model))
        let w = NSWindow(contentViewController: hosting)
        w.title = "悬浮笔记 · 设置"
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.isReleasedWhenClosed = false
        w.center()
        w.level = .normal
        window = w

        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
