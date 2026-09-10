// mkicon.swift —— 生成 BlankScreenBar 应用图标
// 用法: swift Sources/mkicon.swift <输出 iconset 目录>
//
// v2 设计（原创路径绘制，不使用 SF Symbol —— Apple 许可禁止将其用作 App 图标）:
//   * macOS 11+ 规范: 1024 画布、824×824 圆角主体、四角透明（系统据此显示圆角）
//   * 语义: 深色 squircle = 熄灭的屏幕；亮色电源符号 = 机器仍在运行
//   * 旧版教训: SF Symbol 是模板图像，会忽略 NSColor.set() 的填充色，
//     按默认黑色渲染 → 深色背景上月亮隐形；且画布无圆角、小尺寸无优化。

import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"

func render(_ px: Int) -> NSBitmapImageRep {
    let S = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    // ---- 布局: 越小越满，保证 16px 下可辨认 ----
    let small = px <= 64
    let pad = S * (small ? 64.0 / 1024 : 100.0 / 1024)   // 透明边距
    let body = S - pad * 2
    let rect = NSRect(x: pad, y: pad, width: body, height: body)
    let corner = body * 185.0 / 824.0
    let squircle = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)

    // ---- 背景: 对角渐变，深蓝紫 → 近黑（熄灭的屏幕）----
    let grad = NSGradient(starting: NSColor(srgbRed: 0.16, green: 0.18, blue: 0.34, alpha: 1),
                          ending:   NSColor(srgbRed: 0.03, green: 0.03, blue: 0.07, alpha: 1))!
    grad.draw(in: squircle, angle: 45)

    // ---- 顶部高光: 玻璃质感。必须铺满整个主体做连续渐变——若只画上半块，
    //      渐变底边会形成一条肉眼可见的水平分界线。小尺寸省略（会糊）。----
    if !small {
        NSGradient(colors: [NSColor(white: 1, alpha: 0), NSColor(white: 1, alpha: 0.10)])?
            .draw(in: squircle, angle: 90)
    }

    // ---- 边缘细描边: 在浅色列表/菜单里保住轮廓 ----
    NSColor(white: 1, alpha: small ? 0.16 : 0.10).setStroke()
    let outline = squircle.copy() as! NSBezierPath
    outline.lineWidth = body * (small ? 0.020 : 0.012)
    outline.stroke()

    // ---- 电源符号: 圆环（顶部缺口）+ 竖线，语义「屏幕熄灭、机器通电」----
    let cx = S / 2, cy = S / 2
    let symScale: CGFloat = small ? 1.18 : (px <= 256 ? 1.06 : 1.0)
    let R = body * 0.28 * symScale
    let lw = body * (small ? 0.100 : 0.078)
    let ink = NSColor(srgbRed: 0.87, green: 0.94, blue: 1.0, alpha: 1)

    func drawSymbol() {
        let ring = NSBezierPath()
        ring.lineWidth = lw
        ring.lineCapStyle = .round
        // 缺口朝正上方（90°±40°）；逆时针从 130° 画到 50°+360°
        ring.appendArc(withCenter: NSPoint(x: cx, y: cy), radius: R,
                       startAngle: 130, endAngle: 50, clockwise: false)
        ink.setStroke()
        ring.stroke()

        let bar = NSBezierPath()
        bar.lineWidth = lw
        bar.lineCapStyle = .round
        bar.move(to: NSPoint(x: cx, y: cy - R * 0.10))
        bar.line(to: NSPoint(x: cx, y: cy + R + lw * 0.18))
        ink.setStroke()
        bar.stroke()
    }

    if !small {
        // 青色光晕（≥128px 才画；小尺寸下模糊半径会糊成一团）
        NSGraphicsContext.current?.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowColor = NSColor(srgbRed: 0.45, green: 0.80, blue: 1.0, alpha: 0.55)
        sh.shadowBlurRadius = body * 0.055
        sh.shadowOffset = NSSize(width: 0, height: 0)
        sh.set()
        drawSymbol()
        NSGraphicsContext.current?.restoreGraphicsState()
    }
    drawSymbol()

    return rep
}

// ---- 输出完整 iconset（缺任何一个尺寸 iconutil 都会拒绝）----
let specs: [(String, Int)] = [
    ("icon_16x16.png", 16),     ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),     ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),  ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),  ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),  ("icon_512x512@2x.png", 1024),
]

let fm = FileManager.default
try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
// 清掉旧文件，避免上一次的残留尺寸混进 icns
for f in (try? fm.contentsOfDirectory(atPath: outDir)) ?? [] {
    try? fm.removeItem(atPath: outDir + "/" + f)
}
for (name, px) in specs {
    let rep = render(px)
    guard let d = rep.representation(using: .png, properties: [:]) else { exit(1) }
    try! d.write(to: URL(fileURLWithPath: outDir + "/" + name))
}
print("iconset 已生成: \(outDir)（\(specs.count) 个尺寸）")
