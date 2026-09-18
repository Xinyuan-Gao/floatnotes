// 图标验证 + 预览图生成
//
// 因为我（AI）没法"看"图片，所以用像素采样来客观核对渲染结果：
//   · 圆角外应该是透明的
//   · 卡片中心应该是白色
//   · 左上偏靛蓝、右下偏紫
//   · 16px 的简化版中心仍应偏亮（保证小尺寸可辨识）
// 同时拼一张预览图，方便人眼在浅色/深色背景下评估。

import AppKit
import CoreGraphics

func loadBitmap(_ path: String) -> NSBitmapImageRep? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let rep = NSBitmapImageRep(data: data) else { return nil }
    return rep
}

/// 返回 sRGB 四元组（0-255）
func rgba(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> (Int, Int, Int, Int) {
    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return (-1, -1, -1, -1) }
    return (Int(c.redComponent * 255), Int(c.greenComponent * 255),
            Int(c.blueComponent * 255), Int(c.alphaComponent * 255))
}

func hsv(_ rgb: (Int, Int, Int, Int)) -> (h: Int, s: Int, v: Int) {
    let c = NSColor(srgbRed: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255,
                    blue: CGFloat(rgb.2) / 255, alpha: 1)
    var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
    c.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
    return (Int(h * 360), Int(s * 100), Int(v * 100))
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1
               ? CommandLine.arguments[1]
               : FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("AppIcon.iconset")
// 预览用：如果 iconset 已被清理，就去 Resources 旁边找
let previewDir = FileManager.default.fileExists(atPath: iconset.path)
    ? iconset
    : root.appendingPathComponent("Resources/AppIcon.iconset")

var failures: [String] = []
func check(_ label: String, _ ok: Bool, _ detail: String) {
    print("  \(ok ? "✓" : "✗") \(label)：\(detail)")
    if !ok { failures.append(label) }
}

// ── 1. 1024 主图采样 ────────────────────────────────────
// 注意：NSBitmapImageRep.colorAt 用的是「左上原点」（y 向下），
// 和 Core Graphics 的左下原点相反，取样点按这个坐标系给。
print("【1024×1024 主图】")
if let big = loadBitmap(previewDir.appendingPathComponent("icon_512x512@2x.png").path) {
    print("  尺寸 = \(big.pixelsWide)×\(big.pixelsHigh)")

    let corner = rgba(big, 8, 8)
    check("圆角外透明", corner.3 < 12, "左上角 rgba=\(corner)")

    let center = rgba(big, 512, 512)
    check("卡片中心为白", center.0 > 235 && center.1 > 235 && center.2 > 235,
          "中心 rgb=(\(center.0),\(center.1),\(center.2)) α=\(center.3)")

    /// 在一块区域里找"最饱和"的像素，比单点取样稳
    func mostSaturated(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int)
        -> (rgb: (Int, Int, Int, Int), hue: Int, sat: Int) {
        var best = ((0, 0, 0, 0), 0, 0)
        for y in stride(from: y0, to: y1, by: 3) {
            for x in stride(from: x0, to: x1, by: 3) {
                let p = rgba(big, x, y)
                guard p.3 > 200 else { continue }
                let h = hsv(p)
                if h.s > best.2 { best = (p, h.h, h.s) }
            }
        }
        return best
    }

    // 左上区域（含顶部高光）
    let tl = mostSaturated(150, 150, 400, 380)
    check("左上偏靛蓝", tl.hue >= 215 && tl.hue <= 250 && tl.sat > 45,
          "最饱和 rgb=(\(tl.rgb.0),\(tl.rgb.1),\(tl.rgb.2)) 色相=\(tl.hue)° 饱和=\(tl.sat)%")

    // 右下区域
    let br = mostSaturated(660, 660, 900, 900)
    check("右下偏紫", br.hue >= 245 && br.hue <= 295 && br.sat > 45,
          "最饱和 rgb=(\(br.rgb.0),\(br.rgb.1),\(br.rgb.2)) 色相=\(br.hue)° 饱和=\(br.sat)%")

    // 底部中间（无高光干扰，应接近纯紫端）
    let bottom = mostSaturated(400, 800, 640, 900)
    print("  参考 · 底部中间最饱和：色相=\(bottom.hue)° 饱和=\(bottom.sat)%")

    // 卡片上的强调色标题线：卡片 CG y≈564..595 → 左上坐标 y≈429..460
    var foundAccent = false
    var accentSample = (0, 0, 0, 0)
    outer: for y in stride(from: 430, to: 462, by: 2) {
        for x in stride(from: 350, to: 560, by: 3) {
            let p = rgba(big, x, y)
            let h = hsv(p)
            if h.h > 210 && h.h < 260 && h.s > 40 && p.3 > 200 {
                foundAccent = true; accentSample = p; break outer
            }
        }
    }
    check("卡片上有强调色标题线", foundAccent,
          foundAccent ? "rgb=(\(accentSample.0),\(accentSample.1),\(accentSample.2))"
                      : "在 y=430..462 没扫到蓝色线")

    // 卡片下缘应能看到阴影导致的暗色（说明"浮起来"了）
    let justBelow = rgba(big, 512, 690)
    let farBelow  = rgba(big, 512, 800)
    let darker = (justBelow.0 + justBelow.1 + justBelow.2) < (farBelow.0 + farBelow.1 + farBelow.2)
    check("卡片下方有投影（悬浮感）", darker,
          "卡下 rgb=(\(justBelow.0),\(justBelow.1),\(justBelow.2)) vs 远处 rgb=(\(farBelow.0),\(farBelow.1),\(farBelow.2))")
} else {
    check("读取 1024 图", false, "文件不存在于 \(previewDir.path)")
}

// ── 2. 小尺寸简化版 ─────────────────────────────────────
print("\n【16×16 小尺寸】")
if let small = loadBitmap(previewDir.appendingPathComponent("icon_16x16.png").path) {
    let c = rgba(small, 8, 8)
    let lum = (c.0 + c.1 + c.2) / 3
    check("中心可辨识（偏亮）", lum > 150 && c.3 > 200, "中心 rgb=(\(c.0),\(c.1),\(c.2)) 亮度=\(lum)")

    let edge = rgba(small, 0, 0)
    check("外圈透明", edge.3 < 40, "角点 rgba=\(edge)")

    let corner2 = rgba(small, 3, 12)
    let h = hsv(corner2)
    check("底色仍是蓝紫", h.h > 200 && h.h < 300, "rgb=(\(corner2.0),\(corner2.1),\(corner2.2)) 色相=\(h.h)°")
} else {
    check("读取 16 图", false, "文件不存在")
}

// ── 3. 生成预览拼图 ─────────────────────────────────────
print("\n【生成预览图】")
let sheetW: CGFloat = 980, sheetH: CGFloat = 400
let sheet = NSImage(size: NSSize(width: sheetW, height: sheetH))
sheet.lockFocus()

// 左浅右深两种背景，方便同时评估
NSColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: sheetW / 2, height: sheetH).fill()
NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1).setFill()
NSRect(x: sheetW / 2, y: 0, width: sheetW / 2, height: sheetH).fill()

let sizes: [Int] = [16, 32, 64, 128, 256]
let names = ["16", "32", "64", "128", "256"]

// 深色那一半：大字标
let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 12, weight: .medium),
    .foregroundColor: NSColor(srgbRed: 0.55, green: 0.55, blue: 0.6, alpha: 1)
]
NSAttributedString(string: "浅色背景", attributes: titleAttrs)
    .draw(at: NSPoint(x: 24, y: sheetH - 30))
NSAttributedString(string: "深色背景", attributes: titleAttrs)
    .draw(at: NSPoint(x: sheetW / 2 + 24, y: sheetH - 30))

var x: CGFloat = 30
for (i, px) in sizes.enumerated() {
    let path = previewDir.appendingPathComponent("icon_\(px)x\(px).png").path
    if let img = NSImage(contentsOfFile: path) {
        // 上排：浅色底
        let y1 = sheetH - 60 - CGFloat(px)
        img.draw(in: NSRect(x: x, y: y1, width: CGFloat(px), height: CGFloat(px)))

        // 下排：深色底
        let x2 = sheetW / 2 + 30 + (x - 30)
        let y2 = sheetH - 60 - CGFloat(px)
        img.draw(in: NSRect(x: x2, y: y2, width: CGFloat(px), height: CGFloat(px)))

        let label = NSAttributedString(string: "\(names[i])px", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor(srgbRed: 0.5, green: 0.5, blue: 0.55, alpha: 1)
        ])
        label.draw(at: NSPoint(x: x, y: y1 - 16))
        label.draw(at: NSPoint(x: x2, y: y2 - 16))
    }
    x += CGFloat(px) + 26
}
sheet.unlockFocus()

let outURL = root.appendingPathComponent("icon-preview.png")
if let tiff = sheet.tiffRepresentation,
   let rep = NSBitmapImageRep(data: tiff),
   let png = rep.representation(using: .png, properties: [:]) {
    try? png.write(to: outURL)
    print("  ✓ 已输出 \(outURL.path)")
}

// ── 4. 结论 ─────────────────────────────────────────────
print("")
if failures.isEmpty {
    print("PASS ✅ 图标渲染符合设计")
    exit(0)
} else {
    print("FAIL ❌ 有 \(failures.count) 项不符：\(failures.joined(separator: ", "))")
    exit(1)
}
