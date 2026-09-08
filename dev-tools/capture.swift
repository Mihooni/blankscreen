// 取帧验证: 模拟远程桌面/屏幕共享的底层取帧，并统计画面平均亮度
// 注意: CGDisplayCreateImage 自 macOS 27 起不可用（编译期报错），
// 改为调用系统 screencapture 出图，再用 ImageIO 解码统计。
import CoreGraphics
import Foundation
import ImageIO

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/cap.png"

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
p.arguments = ["-x", outPath]
p.standardOutput = FileHandle.nullDevice
p.standardError = FileHandle.nullDevice
try? p.run()
p.waitUntilExit()

guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: outPath) as CFURL, nil),
      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    print("FAIL 取帧失败 (无图像数据，可能缺少屏幕录制权限)")
    exit(1)
}

// 缩放到 32x32 求平均亮度
let w = 32, h = 32
var buf = [UInt8](repeating: 0, count: w * h * 4)
let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
ctx?.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
var sum = 0
for i in 0..<(w * h) { sum += Int(buf[i * 4]) + Int(buf[i * 4 + 1]) + Int(buf[i * 4 + 2]) }
let avg = Double(sum) / Double(w * h * 3) / 255.0

print(String(format: "OK 尺寸=%dx%d 平均亮度=%.3f -> %@", img.width, img.height, avg, outPath))
