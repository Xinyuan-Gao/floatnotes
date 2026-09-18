import AppKit

/// 一种笔记背景
struct BackgroundOption {
    let key: String        // "none" 或文件名（不含扩展名）
    let label: String      // 设置里显示的名字
    let family: String     // 色系，设置面板里分组用
    var file: String? { key == "none" ? nil : "\(key).jpg" }
}

/// 可选背景清单。图片放在 Resources/backgrounds/，
/// 通过 floatnotes://bg/<文件名> 提供给编辑器。
enum BackgroundCatalog {

    static let none = BackgroundOption(key: "none", label: "无背景", family: "")

    static let all: [BackgroundOption] = [
        none,

        .init(key: "01-grid-apple",       label: "方格 · 苹果",   family: "米白"),
        .init(key: "02-lined-apple",      label: "横线 · 苹果",   family: "米白"),
        .init(key: "03-vertical-sun",     label: "竖线 · 阳光",   family: "米白"),
        .init(key: "04-stitched-apple",   label: "缝线苹果",      family: "米白"),
        .init(key: "05-cat-stationery",   label: "猫咪 · 文具",   family: "米白"),
        .init(key: "06-book-movie",       label: "书本 · 电影",   family: "米白"),

        .init(key: "07-sage-dots",        label: "点阵 · 桉叶",   family: "鼠尾草绿"),
        .init(key: "08-matcha-lines",     label: "横线 · 柑橘",   family: "抹茶绿"),
        .init(key: "09-blossom-grid",     label: "方格 · 樱花",   family: "藕粉"),
        .init(key: "10-rose-plain",       label: "空白 · 浆果枝", family: "玫瑰粉"),
        .init(key: "11-mist-blue-vertical", label: "竖线 · 纸飞机", family: "雾霾蓝"),
        .init(key: "12-night-stars",      label: "夜空 · 星星",   family: "深蓝"),
        .init(key: "13-butter-diagonal",  label: "斜纹 · 柠檬",   family: "奶油黄"),
        .init(key: "14-apricot-plain",    label: "空白 · 橘子",   family: "杏橘"),
        .init(key: "15-lavender-grid",    label: "方格 · 月牙",   family: "薰衣草紫"),
        .init(key: "16-kraft-plain",      label: "牛皮纸 · 咖啡", family: "牛皮棕"),
        .init(key: "17-morandi-grid",     label: "方格 · 几何",   family: "莫兰迪灰"),
        .init(key: "18-cornell-grid",     label: "康奈尔版式",    family: "暖灰"),
    ]

    static func option(for key: String) -> BackgroundOption {
        all.first { $0.key == key } ?? none
    }

    static func label(for key: String) -> String {
        option(for: key).label
    }

    /// 深色底：这类背景需要配深色主题，否则字看不清
    static let darkKeys: Set<String> = ["12-night-stars", "16-kraft-plain"]

    static func isDark(_ key: String) -> Bool { darkKeys.contains(key) }

    /// 设置面板用的缩略图（bundle 里的 background-thumbs/）
    static func thumbnail(for key: String) -> NSImage? {
        guard key != "none" else { return nil }
        guard let url = Bundle.main.url(forResource: key, withExtension: "jpg",
                                        subdirectory: "background-thumbs") else { return nil }
        return NSImage(contentsOf: url)
    }
}
