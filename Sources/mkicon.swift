// mkicon.swift —— 生成 BlankScreenBar 应用图标
// 用法: swift Sources/mkicon.swift <输出 iconset 目录>
//
// v3 设计（先锋 / 简约）:
//   * macOS 11+ 规范: 1024 画布、824×824 圆角主体、四角透明（系统据此裁圆角）
//   * 配色: 石墨黑底（旧版蓝紫渐变显旧，已弃）+ 薄荷青 → 靛紫的渐变符号
//   * 减法: 去掉旧版厚重的 shadow 光晕（廉价发光感），换成一层极淡的径向余光；
//           笔画更细，主体顶部只留一条 1px 级高光细线而非半块渐变
//   * 语义: 深色 squircle = 熄灭的屏幕；通电符号 = 机器仍在运行
//
// 旧版教训（勿回退）:
//   1. SF Symbol 是模板图像，会忽略 NSColor.set() 的填充色、按默认黑色渲染
//      → 深色背景上直接隐形；且 Apple 许可禁止将其用作 App 图标。
//   2. 顶部高光若只画上半块，渐变底边会留下一条肉眼可见的水平硬线。
//   3. 小尺寸（16/32px，登录项与系统设置列表的绘制尺寸）必须放大符号、
//      加粗笔画、去掉辉光，否则糊成一团。

import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"

/// 渐变描边：把「描边路径」转成填充轮廓后裁切，再画线性渐变。
/// NSBezierPath 没有渐变描边能力，这是唯一简洁可靠的做法。
func gradientStroke(_ path: CGPath, lineWidth: CGFloat,
                    colors: [CGColor], start: CGPoint, end: CGPoint,
                    cap: CGLineCap = .round) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    let outline = path.copy(strokingWithWidth: lineWidth, lineCap: cap,
                            lineJoin: .round, miterLimit: 4)
    ctx.saveGState()
    ctx.addPath(outline)
    ctx.clip()
    if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: colors as CFArray, locations: nil) {
        ctx.drawLinearGradient(g, start: start, end: end, options: [])
    }
    ctx.restoreGState()
}

func render(_ px: Int) -> NSBitmapImageRep {
    let S = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }
    guard let ctx = NSGraphicsContext.current?.cgContext else { return rep }

    // ---- 布局: 越小越满，保证 16px 下可辨认 ----
    let small = px <= 64
    let pad = S * (small ? 62.0 / 1024 : 100.0 / 1024)
    let body = S - pad * 2
    let rect = NSRect(x: pad, y: pad, width: body, height: body)
    let corner = body * 208.0 / 824.0
    let squircle = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)

    let rgb = CGColorSpaceCreateDeviceRGB()
    func cg(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: rgb, components: [r, g, b, a])!
    }

    // ---- 背景: 石墨 → 近黑，对角渐变（左上微亮，比纯垂直更有层次）----
    ctx.saveGState()
    squircle.addClip()
    let bg = CGGradient(colorsSpace: rgb, colors: [
        cg(0.208, 0.212, 0.243),   // #35363E
        cg(0.027, 0.027, 0.035)    // #070709 近黑
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg,
                           start: CGPoint(x: S * 0.15, y: S * 0.92),
                           end:   CGPoint(x: S * 0.85, y: S * 0.05),
                           options: [])
    ctx.restoreGState()

    // ---- 余光: 中心极淡的青色径向辉光，暗示「还在通电」。
    //      旧版用 NSShadow 做光晕，模糊半径在小尺寸会糊成一团且廉价感重，已弃。----
    if !small {
        ctx.saveGState()
        squircle.addClip()
        let glowR = body * 0.46
        let glow = CGGradient(colorsSpace: rgb, colors: [
            cg(0.369, 0.918, 0.831, 0.20),   // #5EEAD4 @20%
            cg(0.369, 0.918, 0.831, 0.0)
        ] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(glow,
                               startCenter: CGPoint(x: S / 2, y: S / 2), startRadius: 0,
                               endCenter:   CGPoint(x: S / 2, y: S / 2), endRadius: glowR,
                               options: [])
        ctx.restoreGState()
    }

    // ---- 通电符号: 圆环（顶部缺口）+ 竖线，语义「屏幕熄灭、机器通电」----
    //      笔画比旧版更细（0.078 → 0.056），是「简约」最直观的体现。
    let cx = S / 2, cy = S / 2
    let symScale: CGFloat = small ? 1.18 : (px <= 256 ? 1.06 : 1.0)
    let R = body * 0.285 * symScale
    let lw = body * (small ? 0.098 : 0.056)

    let ring = CGMutablePath()
    // 缺口朝正上方：从 125° 逆时针绕一大圈到 55°（缺口张角 70°）
    ring.addArc(center: CGPoint(x: cx, y: cy), radius: R,
                startAngle: 125 * .pi / 180, endAngle: 55 * .pi / 180, clockwise: false)

    let bar = CGMutablePath()
    bar.move(to: CGPoint(x: cx, y: cy - R * 0.12))
    bar.addLine(to: CGPoint(x: cx, y: cy + R + lw * 0.30))

    if small {
        // 小尺寸不上渐变：两色在 16px 下只会显得脏，用最亮的单色换取对比度
        NSColor(srgbRed: 0.55, green: 0.97, blue: 0.90, alpha: 1).setStroke()
        let p = NSBezierPath(cgPath: ring); p.lineWidth = lw; p.lineCapStyle = .round; p.stroke()
        let b = NSBezierPath(cgPath: bar); b.lineWidth = lw; b.lineCapStyle = .round; b.stroke()
    } else {
        // 薄荷青 → 靛紫：对角渐变，比单色更有当代感
        let ink: [CGColor] = [cg(0.369, 0.918, 0.831), cg(0.655, 0.714, 0.988)]
        let from = CGPoint(x: S * 0.28, y: S * 0.74)
        let to   = CGPoint(x: S * 0.72, y: S * 0.26)
        gradientStroke(ring, lineWidth: lw, colors: ink, start: from, end: to)
        gradientStroke(bar,  lineWidth: lw, colors: ink, start: from, end: to)
    }

    return rep
}

// NSBezierPath → CGPath：只在需要渐变描边时用（主体轮廓）
extension NSBezierPath {
    var cgPath: CGPath {
        let p = CGMutablePath()
        var pts = [CGPoint](repeating: .zero, count: 3)
        for i in 0..<elementCount {
            let t = element(at: i, associatedPoints: &pts)
            switch t {
            case .moveTo:    p.move(to: pts[0])
            case .lineTo:    p.addLine(to: pts[0])
            case .curveTo:   p.addCurve(to: pts[2], control1: pts[0], control2: pts[1])
            case .closePath: p.closeSubpath()
            @unknown default: break
            }
        }
        return p
    }
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
