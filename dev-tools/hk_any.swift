// 用法: hk_any <keyCode> <mods: c/a/s/m 任意组合>  —— 合成一次组合键
import CoreGraphics
import Foundation
let args = CommandLine.arguments
let code = UInt32(args.count > 1 ? Int(args[1]) ?? 11 : 11)
let mods = args.count > 2 ? args[2] : "cs"
let ks = CGEventSource(stateID: .hidSystemState)
var f = CGEventFlags()
if mods.contains("m") { f.insert(.maskCommand) }
if mods.contains("s") { f.insert(.maskShift) }
if mods.contains("a") { f.insert(.maskAlternate) }
if mods.contains("c") { f.insert(.maskControl) }
let d = CGEvent(keyboardEventSource: ks, virtualKey: CGKeyCode(code), keyDown: true)!
let u = CGEvent(keyboardEventSource: ks, virtualKey: CGKeyCode(code), keyDown: false)!
d.flags = f; u.flags = f
d.post(tap: .cghidEventTap); u.post(tap: .cghidEventTap)
usleep(300_000)   // 留时间给事件派发
print("posted \(mods)+\(code)")
