// 生成 BlankScreenBar 的应用图标（SF Symbol moon.fill + 深色圆角底）
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let S = 1024
guard let base = NSImage(systemSymbolName: "moon.fill", accessibilityDescription: nil) else {
    FileManager.default.createFile(atPath: out, contents: nil); exit(1)
}
let cfg = NSImage.SymbolConfiguration(pointSize: 620, weight: .medium)
let moon = base.withSymbolConfiguration(cfg)!

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: S, pixelsHigh: S,
                                 bitsPerSample: 8, samplesPerPixel: 4,
                                 hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let rect = NSRect(x: 0, y: 0, width: S, height: S)
// 渐变底：深蓝紫 → 近黑
let grad = NSGradient(starting: NSColor(calibratedRed: 0.13, green: 0.15, blue: 0.30, alpha: 1),
                      ending:   NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.09, alpha: 1))!
grad.draw(in: rect, angle: -90)
// 月亮
NSColor(white: 1, alpha: 0.95).set()
NSGraphicsContext.current?.compositingOperation = .sourceOver
moon.draw(in: NSRect(x: 202, y: 190, width: 620, height: 620))
NSGraphicsContext.restoreGraphicsState()

if let d = rep.representation(using: .png, properties: [:]) {
    try? d.write(to: URL(fileURLWithPath: out))
    print("图标已生成: \(out)")
} else { exit(1) }
