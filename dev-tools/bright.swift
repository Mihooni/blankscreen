// 内置屏幕亮度读写工具（macOS / Apple Silicon）
// 策略链: DisplayServices(私有) -> CoreDisplay(私有) -> IOKit(IODisplayConnect)
// 用法:  bright          # 读取当前亮度(0.0-1.0)
//        bright 0.42     # 设置亮度
import Foundation
import CoreGraphics
import IOKit

let displayID = CGMainDisplayID()

// ---------- 策略 1: DisplayServices ----------
let dsPath = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
let dsHandle = dlopen(dsPath, RTLD_NOW)
typealias DSGet = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
typealias DSSet = @convention(c) (UInt32, Float) -> Int32

func dsRead() -> Float? {
    guard let h = dsHandle, let p = dlsym(h, "DisplayServicesGetBrightness") else { return nil }
    let f = unsafeBitCast(p, to: DSGet.self)
    var v: Float = -1
    return f(displayID, &v) == 0 ? v : nil
}
func dsWrite(_ v: Float) -> Int32? {
    guard let h = dsHandle, let p = dlsym(h, "DisplayServicesSetBrightness") else { return nil }
    let f = unsafeBitCast(p, to: DSSet.self)
    return f(displayID, v)
}

// ---------- 策略 2: CoreDisplay ----------
let cdPath = "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay"
let cdHandle = dlopen(cdPath, RTLD_NOW)
typealias CDGet = @convention(c) (UInt32) -> Double
typealias CDSet = @convention(c) (UInt32, Double) -> Void

func cdRead() -> Double? {
    guard let h = cdHandle, let p = dlsym(h, "CoreDisplay_Display_GetUserBrightness") else { return nil }
    return unsafeBitCast(p, to: CDGet.self)(displayID)
}
func cdWrite(_ v: Double) -> Bool {
    guard let h = cdHandle, let p = dlsym(h, "CoreDisplay_Display_SetUserBrightness") else { return false }
    unsafeBitCast(p, to: CDSet.self)(displayID, v)
    return true
}

// ---------- 策略 3: IOKit ----------
func ioServiceForDisplay() -> io_service_t {
    let matching = IOServiceMatching("IODisplayConnect")
    return IOServiceGetMatchingService(kIOMasterPortDefault, matching)
}
func ioRead() -> Float? {
    let s = ioServiceForDisplay()
    defer { IOObjectRelease(s) }
    var v: Float = -1
    let r = IODisplayGetFloatParameter(s, 0, kIODisplayBrightnessKey as CFString, &v)
    return r == KERN_SUCCESS ? v : nil
}
func ioWrite(_ v: Float) -> Bool {
    let s = ioServiceForDisplay()
    defer { IOObjectRelease(s) }
    return IODisplaySetFloatParameter(s, 0, kIODisplayBrightnessKey as CFString, v) == KERN_SUCCESS
}

// ---------- 主流程 ----------
let args = CommandLine.arguments

if args.count < 2 {
    // 读取
    if let v = dsRead() { print("OK DisplayServices read=\(String(format: "%.4f", v))"); exit(0) }
    if let v = cdRead() { print("OK CoreDisplay read=\(String(format: "%.4f", v))"); exit(0) }
    if let v = ioRead() { print("OK IOKit read=\(String(format: "%.4f", v))"); exit(0) }
    print("FAIL 三种策略均无法读取亮度")
    exit(1)
}

guard let target = Float(args[1]), target >= 0, target <= 1 else {
    print("FAIL 参数需为 0.0-1.0"); exit(1)
}

if let r = dsWrite(target) {
    if r == 0 { print("OK DisplayServices write=\(target)") } else { print("WARN DisplayServices ret=\(r)") }
} else if cdWrite(Double(target)) {
    print("OK CoreDisplay write=\(target)")
} else if ioWrite(target) {
    print("OK IOKit write=\(target)")
} else {
    print("FAIL 三种策略均无法写入亮度"); exit(1)
}
