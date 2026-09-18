import Foundation

/// 可选正文字体。`css` 是直接塞给编辑器的 font-family 值，
/// 后面的备选字体保证缺字时能优雅回退。
struct FontOption {
    let key: String
    let label: String
    let css: String
    /// 预览用（在 SwiftUI 里直接用的字体名，取主字体）
    let previewFont: String?
}

enum FontCatalog {

    static let all: [FontOption] = [
        FontOption(key: "system", label: "系统默认",
                   css: "-apple-system, BlinkMacSystemFont, \"PingFang SC\", sans-serif",
                   previewFont: nil),

        FontOption(key: "pingfang", label: "苹方 · 黑体",
                   css: "\"PingFang SC\", \"Hiragino Sans GB\", sans-serif",
                   previewFont: "PingFang SC"),

        FontOption(key: "heiti", label: "黑体",
                   css: "\"Heiti SC\", \"PingFang SC\", sans-serif",
                   previewFont: "Heiti SC"),

        FontOption(key: "songti", label: "宋体",
                   css: "\"Songti SC\", \"STSong\", serif",
                   previewFont: "Songti SC"),

        FontOption(key: "kaiti", label: "楷体",
                   css: "\"Kaiti SC\", \"STKaiti\", serif",
                   previewFont: "Kaiti SC"),

        FontOption(key: "yuanti", label: "圆体",
                   css: "\"Yuanti SC\", \"PingFang SC\", sans-serif",
                   previewFont: "Yuanti SC"),

        FontOption(key: "hiragino", label: "冬青黑体",
                   css: "\"Hiragino Sans GB\", \"PingFang SC\", sans-serif",
                   previewFont: "Hiragino Sans GB"),

        FontOption(key: "mono", label: "等宽",
                   css: "Menlo, \"PingFang SC\", monospace",
                   previewFont: "Menlo"),
    ]

    static func css(for key: String) -> String {
        all.first { $0.key == key }?.css ?? all[0].css
    }

    static func label(for key: String) -> String {
        all.first { $0.key == key }?.label ?? all[0].label
    }

    static func previewFont(for key: String) -> String? {
        all.first { $0.key == key }?.previewFont
    }
}
