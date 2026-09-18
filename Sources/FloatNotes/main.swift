import AppKit

// M0 Spike — 悬浮笔记 App 技术验证
//
// 验证目标：
//   S1 悬浮面板能否盖住浏览器全屏
//   S2 能否浮在别的 App 的全屏 Space 之上
//   S3 点笔记窗口时其他 App 不失焦（且中文可输入）
//   S4 WKWebView 里跑通块编辑器
//   S5 全局热键 + 菜单栏图标能唤起新窗口
//
// `swift run FloatNotes --selftest` 只打印诊断信息后退出。

// NSApplication.delegate 是 weak/unowned，必须自己持强引用
var strongDelegate: AppDelegate?

let app = NSApplication.shared
let delegate = AppDelegate()
strongDelegate = delegate
app.delegate = delegate
// 激活策略决定有没有 Dock 图标 / 是否出现在 ⌘Tab：
//   .regular   → 有 Dock 图标，像普通 App，好找
//   .accessory → 纯菜单栏 App，更安静
// 「点击笔记窗口不抢前台 App 焦点」靠的是面板的 .nonactivatingPanel，
// 和这个策略无关，所以两种模式下都不会打断阅读。
app.setActivationPolicy(Settings.shared.showInDock ? .regular : .accessory)
app.run()
