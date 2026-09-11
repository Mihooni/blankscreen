// mkicon.swift —— 生成 LidKeep 应用图标
// 用法: swift Sources/mkicon.swift <输出 iconset 目录>
//
// v4 设计（先锋 / 潮流 / 简约）:
//   * macOS 11+ 规范: 1024 画布、824×824 圆角主体、四角透明（系统据此裁圆角）
//   * 主体: 深石墨 squircle + 内描边玻璃高光 —— 熄灭的屏幕
//   * 符号: 银色金属描边圆角方框 = 合上的盖子（lid）；框内开口圆弧 = 持续运行的轨迹；
//           青色发光指针 = 机器仍然通电。三者合起来表达「合盖保持运行」。
//   * 发光: 用多层递减透明度的圆头描边叠出辉光，不用 CIFilter / NSShadow
//           —— 可控、无依赖，且小尺寸能逐层关掉，不会在 16px 糊成一团。
//
// 旧版教训（勿回退）:
//   1. SF Symbol 是模板图像，会忽略 NSColor.set() 的填充色、按默认黑色渲染
//      → 深色背景上直接隐形；且 Apple 许可禁止将其用作 App 图标。
//   2. 顶部高光若只画上半块，渐变底边会留下一条肉眼可见的水平硬线。
//   3. 小尺寸（16/32px，登录项与系统设置列表的绘制尺寸）必须放大符号、
//      加粗笔画、去掉辉光，否则糊成一团。这里的做法是 tiny/small 两档降级。
//   4. 发光不能只靠「把线加粗再降透明度」糊一层 —— 那会让笔画发脏。
//      正确做法是宽度与透明度成对递减地叠若干层，核心层保持高对比纯色。

import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"

// MARK: - 绘制辅助

/// 渐变描边：NSBezierPath 没有渐变描边能力，先把描边转成填充轮廓，再裁切填渐变。
func gradientStroke(_ path: CGPath, lineWidth: CGFloat,
                    colors: [CGColor], start: CGPoint, end: CGPoint) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    let outline = path.copy(strokingWithWidth: lineWidth, lineCap: .round,
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

/// 单色圆头描边。辉光层靠它逐层叠加（层数与透明度由调用方控制）。
func strokePath(_ path: CGPath, width: CGFloat, color: CGColor) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    ctx.saveGState()
    ctx.setStrokeColor(color)
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.addPath(path)
    ctx.strokePath()
    ctx.restoreGState()
}

// MARK: - 渲染

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

    let rgb = CGColorSpaceCreateDeviceRGB()
    func cg(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: rgb, components: [r, g, b, a])!
    }
    // 两档降级：tiny 用于 16/32（登录项、访达列表），small 用于 64
    let tiny  = px <= 32
    let small = px <= 64

    // ---- 主体轮廓: 824/1024 圆角方形（macOS 规范），四角留给系统裁切 ----
    let pad = S * (small ? 52.0 / 1024 : 100.0 / 1024)
    let body = S - pad * 2
    let rect = NSRect(x: pad, y: pad, width: body, height: body)
    let corner = body * 208.0 / 824.0
    let squircle = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)

    // ---- 背景: 对角石墨渐变（左上受光）+ 中心径向柔光，避免大块死黑 ----
    ctx.saveGState()
    squircle.addClip()
    let bg = CGGradient(colorsSpace: rgb, colors: [
        cg(0.235, 0.247, 0.271),   // #3C3F45
        cg(0.071, 0.078, 0.094)    // #121418
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg,
                           start: CGPoint(x: S * 0.16, y: S * 0.95),
                           end:   CGPoint(x: S * 0.86, y: S * 0.04),
                           options: [])
    let halo = CGGradient(colorsSpace: rgb, colors: [
        cg(0.44, 0.48, 0.55, 0.20),
        cg(0.44, 0.48, 0.55, 0.0)
    ] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(halo,
                           startCenter: CGPoint(x: S / 2, y: S * 0.60), startRadius: 0,
                           endCenter:   CGPoint(x: S / 2, y: S * 0.60), endRadius: body * 0.80,
                           options: [])
    ctx.restoreGState()

    // ---- 玻璃边缘: 贴着轮廓内侧的一条高光，把主体从桌面背景里「拎」出来 ----
    ctx.saveGState()
    squircle.addClip()
    strokePath(squircle.cgPath, width: S * 0.007, color: cg(1, 1, 1, small ? 0.16 : 0.11))
    ctx.restoreGState()

    let cx = S / 2, cy = S / 2
    // 小尺寸整体放大符号，保证 16px 下仍能辨认
    let symScale: CGFloat = tiny ? 1.10 : (small ? 1.06 : (px <= 256 ? 1.04 : 1.0))
    let half = body * 0.248 * symScale                       // 盖子方框的半边长
    let fr = NSRect(x: cx - half, y: cy - half, width: half * 2, height: half * 2)
    let framePath = NSBezierPath(roundedRect: fr,
                                 xRadius: half * 0.42, yRadius: half * 0.42)
    let frameLW = body * (tiny ? 0.095 : (small ? 0.078 : 0.021))

    // ---- 盖子内部: 比底色更暗，制造内凹纵深，否则方框会像一张贴纸 ----
    if !small {
        ctx.saveGState()
        framePath.addClip()
        let inner = CGGradient(colorsSpace: rgb, colors: [
            cg(0.035, 0.043, 0.055, 0.90),
            cg(0.098, 0.110, 0.130, 0.30)
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(inner,
                               start: CGPoint(x: cx - half, y: cy + half),
                               end:   CGPoint(x: cx + half, y: cy - half),
                               options: [])
        ctx.restoreGState()
    }

    // ---- 盖子描边: 银色金属渐变（左上高光 → 右下暗部），图标的主体识别特征 ----
    if small {
        strokePath(framePath.cgPath, width: frameLW, color: cg(0.80, 0.84, 0.89, 1))
    } else {
        // 外圈柔光：深底上银色线条不"陷"进去
        strokePath(framePath.cgPath, width: frameLW * 2.8, color: cg(0.76, 0.81, 0.87, 0.09))
        gradientStroke(framePath.cgPath, lineWidth: frameLW,
                       colors: [cg(1.0, 1.0, 1.0),
                                cg(0.60, 0.645, 0.705),
                                cg(0.93, 0.955, 0.985)],
                       start: CGPoint(x: cx - half, y: cy + half),
                       end:   CGPoint(x: cx + half, y: cy - half))
    }

    // ---- 轨迹弧: 开口圆环 + 中心小环。细线在 64px 以下必然糊，故只在达标尺寸绘制 ----
    if !small {
        let r = half * 0.455
        let arc = CGMutablePath()
        // 开口朝左下：从左上 148° 顺时针绕过顶部与右侧，到右下 -52°
        arc.addArc(center: CGPoint(x: cx, y: cy), radius: r,
                   startAngle: 148 * .pi / 180, endAngle: -52 * .pi / 180, clockwise: true)
        strokePath(arc, width: body * 0.0105, color: cg(0.80, 0.85, 0.90, 0.90))

        // 轴环要比指针略大一圈，否则柔光会把它整圈吃掉，只剩一根斜杆
        let dot = CGMutablePath()
        dot.addEllipse(in: CGRect(x: cx - r * 0.245, y: cy - r * 0.245,
                                  width: r * 0.49, height: r * 0.49))
        strokePath(dot, width: body * 0.0092, color: cg(0.795, 0.845, 0.90, 0.85))
    }

    // ---- 青色指针: 全图唯一彩色。自中心指向左下 —— 合盖之后机器仍在转的那一下动势 ----
    let ang = 225.0 * Double.pi / 180
    let head = CGPoint(x: cx + half * 0.05, y: cy + half * 0.05)     // 略越过中心，视觉上"插"在轴心
    let len = half * 1.12
    let tail = CGPoint(x: head.x + CGFloat(cos(ang)) * len,
                       y: head.y + CGFloat(sin(ang)) * len)
    let bar = CGMutablePath()
    bar.move(to: head)
    bar.addLine(to: tail)
    let barW = body * (tiny ? 0.135 : (small ? 0.105 : 0.036))

    if !small {
        // 辉光: 宽度与透明度成对递减地叠三层；核心层稍后单独画，保持高对比
        for (mul, alpha) in [(4.6, 0.050), (2.8, 0.095), (1.8, 0.150)] {
            strokePath(bar, width: barW * CGFloat(mul), color: cg(0.129, 0.831, 0.933, CGFloat(alpha)))
        }
        // 轴心柔光: 指针起点附近泛出的光斑，暗示"通电"
        let spot = CGGradient(colorsSpace: rgb, colors: [
            cg(0.72, 0.96, 1.0, 0.42),
            cg(0.35, 0.88, 0.96, 0.0)
        ] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(spot,
                               startCenter: head, startRadius: 0,
                               endCenter: head, endRadius: barW * 1.9,
                               options: [])
    }

    // 核心层: 起点近白，末端偏青，模拟发光沿程衰减
    if small {
        strokePath(bar, width: barW, color: cg(0.58, 0.93, 0.99, 1))
    } else {
        gradientStroke(bar, lineWidth: barW,
                       colors: [cg(0.925, 0.995, 1.0), cg(0.31, 0.85, 0.95)],
                       start: head, end: tail)
    }

    return rep
}

// NSBezierPath → CGPath：只在需要渐变描边 / 纯 CG 描边时用
extension NSBezierPath {
    var cgPath: CGPath {
        let p = CGMutablePath()
        var pts = [CGPoint](repeating: .zero, count: 3)
        for i in 0..<elementCount {
            let t = element(at: i, associatedPoints: &pts)
            switch t {
            case .moveTo:    p.move(to: pts[0])
            case .lineTo:    p.addLine(to: pts[0])
            case .curveTo, .cubicCurveTo:
                p.addCurve(to: pts[2], control1: pts[0], control2: pts[1])
            case .quadraticCurveTo:
                p.addQuadCurve(to: pts[1], control: pts[0])
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
