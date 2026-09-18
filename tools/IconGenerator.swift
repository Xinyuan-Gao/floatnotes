// 悬浮笔记图标生成器
//
// 用 Core Graphics 把图标画出来，而不是让 AI 生成 —— 好处是：
//   · 每个尺寸都精确重绘，不靠缩放糊出来
//   · 小尺寸可以走简化版（少画几条线、卡片放大），16px 下仍看得清
//   · 改颜色/比例只要改常量，可复现
//
// 用法：swift tools/IconGenerator.swift <输出目录>
// 会产出 AppIcon.iconset/ 下的 10 个 PNG，供 iconutil 打包成 .icns

import AppKit
import CoreGraphics

// MARK: - 设计参数（要和悬浮球的配色保持一致）

let gradientTop    = CGColor(red: 74/255,  green: 96/255,  blue: 252/255, alpha: 1)
let gradientBottom = CGColor(red: 148/255, green: 62/255,  blue: 245/255, alpha: 1)
let accentLine     = CGColor(red: 99/255,  green: 118/255, blue: 250/255, alpha: 0.92)
let mutedLine      = CGColor(red: 150/255, green: 156/255, blue: 176/255, alpha: 0.55)

/// 画一条圆头横线（卡片上的文字占位）
func line(_ ctx: CGContext, x: CGFloat, y: CGFloat,
          width: CGFloat, height: CGFloat, radius: CGFloat, color: CGColor) {
    guard width > 0 else { return }
    let r = min(radius, height / 2)
    let rect = CGRect(x: x, y: y, width: width, height: height)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
    ctx.setFillColor(color)
    ctx.fillPath()
}

/// 在 1024×1024 的坐标系里作画
func drawIcon(_ ctx: CGContext, simplified: Bool) {

    let canvas: CGFloat = 1024
    let inset: CGFloat = canvas * 0.0977          // macOS 图标留白比例
    let side = canvas - inset * 2
    let squircleRadius = side * 0.2237            // 系统惯例的圆角比例

    let shape = CGRect(x: inset, y: inset, width: side, height: side)
    let shapePath = CGPath(roundedRect: shape,
                           cornerWidth: squircleRadius,
                           cornerHeight: squircleRadius,
                           transform: nil)

    // ── 1. 底：蓝紫渐变 ──────────────────────────────
    ctx.saveGState()
    ctx.addPath(shapePath)
    ctx.clip()

    let space = CGColorSpaceCreateDeviceRGB()
    if let grad = CGGradient(colorsSpace: space,
                             colors: [gradientTop, gradientBottom] as CFArray,
                             locations: [0, 1]) {
        ctx.drawLinearGradient(
            grad,
            start: CGPoint(x: shape.minX + side * 0.18, y: shape.maxY - side * 0.10),
            end:   CGPoint(x: shape.maxX - side * 0.10, y: shape.minY + side * 0.16),
            // ★ 必须加这两个选项：否则起点之前 / 终点之后的区域「完全不绘制」，
            //   左上角会留下透明空洞，图标看起来像缺了一块。
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }

    // 顶部一层柔和高光，避免纯平
    if let hl = CGGradient(colorsSpace: space,
                           colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 0.12),
                                    CGColor(red: 1, green: 1, blue: 1, alpha: 0.0)] as CFArray,
                           locations: [0, 1]) {
        ctx.drawLinearGradient(
            hl,
            start: CGPoint(x: shape.midX, y: shape.maxY),
            end:   CGPoint(x: shape.midX, y: shape.midY + side * 0.06),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }
    ctx.restoreGState()

    // ── 2. 悬浮卡片 ─────────────────────────────────
    let cardW = side * (simplified ? 0.62 : 0.535)
    let cardH = side * (simplified ? 0.50 : 0.422)
    let cardX = shape.midX - cardW / 2
    let cardY = shape.midY - cardH / 2 + side * 0.022
    let cardRect = CGRect(x: cardX, y: cardY, width: cardW, height: cardH)
    let cardRadius = cardW * 0.105

    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -side * (simplified ? 0.020 : 0.032)),
        blur: side * (simplified ? 0.030 : 0.055),
        color: CGColor(red: 0.05, green: 0.04, blue: 0.18, alpha: 0.40)
    )
    ctx.addPath(CGPath(roundedRect: cardRect,
                       cornerWidth: cardRadius, cornerHeight: cardRadius,
                       transform: nil))
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // 卡片自身的极淡竖向渐变，增加厚度感
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: cardRect,
                       cornerWidth: cardRadius, cornerHeight: cardRadius,
                       transform: nil))
    ctx.clip()
    if let cg = CGGradient(colorsSpace: space,
                           colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 1),
                                    CGColor(red: 0.945, green: 0.949, blue: 0.996, alpha: 1)] as CFArray,
                           locations: [0, 1]) {
        ctx.drawLinearGradient(cg,
                               start: CGPoint(x: cardRect.midX, y: cardRect.maxY),
                               end:   CGPoint(x: cardRect.midX, y: cardRect.minY),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
    ctx.restoreGState()

    // ── 3. 卡片上的文字线 ───────────────────────────
    let padX = cardW * 0.115
    let innerX = cardRect.minX + padX
    let innerW = cardW - padX * 2

    if simplified {
        // 小尺寸：只画两条、更粗，缩小后不会糊成一团
        let h = cardH * 0.155
        let gap = cardH * 0.20
        let top = cardRect.midY + (h + gap) / 2
        line(ctx, x: innerX, y: top - h, width: innerW * 0.74, height: h,
             radius: h / 2, color: accentLine)
        line(ctx, x: innerX, y: top - h - gap - h, width: innerW, height: h,
             radius: h / 2, color: mutedLine)
    } else {
        // 大尺寸：三条，第一条用强调色当"标题"
        let h1 = cardH * 0.088
        let h2 = cardH * 0.060
        let gap1 = cardH * 0.085
        let gap2 = cardH * 0.078

        let blockH = h1 + gap1 + h2 + gap2 + h2
        var y = cardRect.midY + blockH / 2 - h1

        line(ctx, x: innerX, y: y, width: innerW * 0.66, height: h1,
             radius: h1 / 2, color: accentLine)
        y -= (gap1 + h2)
        line(ctx, x: innerX, y: y, width: innerW, height: h2,
             radius: h2 / 2, color: mutedLine)
        y -= (gap2 + h2)
        line(ctx, x: innerX, y: y, width: innerW * 0.82, height: h2,
             radius: h2 / 2, color: mutedLine)
    }
}

// MARK: - 渲染

func renderPNG(pixelSize: Int, to url: URL) throws {
    let size = CGFloat(pixelSize)
    guard let ctx = CGContext(
        data: nil, width: pixelSize, height: pixelSize,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "icon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "无法创建 CGContext"])
    }

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    let scale = size / 1024.0
    ctx.scaleBy(x: scale, y: scale)
    drawIcon(ctx, simplified: pixelSize <= 32)

    guard let cgImage = ctx.makeImage() else {
        throw NSError(domain: "icon", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "无法生成 CGImage"])
    }

    let rep = NSBitmapImageRep(cgImage: cgImage)
    rep.size = NSSize(width: pixelSize, height: pixelSize)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "icon", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "PNG 编码失败"])
    }
    try png.write(to: url)
}

// MARK: - 入口

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("用法: swift IconGenerator.swift <输出目录>\n".data(using: .utf8)!)
    exit(1)
}

let outDir = URL(fileURLWithPath: args[1])
let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// iconutil 要求的 10 个文件
let variants: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

var done: [String] = []
for v in variants {
    let url = iconset.appendingPathComponent(v.name)
    do {
        try renderPNG(pixelSize: v.px, to: url)
        done.append("\(v.name)(\(v.px))")
    } catch {
        FileHandle.standardError.write("生成 \(v.name) 失败: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

print("✓ 已生成 \(done.count) 个尺寸: \(done.joined(separator: ", "))")
print("  iconset: \(iconset.path)")
