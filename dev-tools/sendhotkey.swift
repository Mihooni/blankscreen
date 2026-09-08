// 端到端验证用：合成一次 ⌃⌥⌘B 热键事件（模拟用户按键）
import CoreGraphics
let ks = CGEventSource(stateID: .hidSystemState)
let d = CGEvent(keyboardEventSource: ks, virtualKey: 11, keyDown: true)   // 11 = B
d?.flags = [.maskCommand, .maskAlternate, .maskControl]
d?.post(tap: .cgSessionEventTap)
let u = CGEvent(keyboardEventSource: ks, virtualKey: 11, keyDown: false)
u?.flags = [.maskCommand, .maskAlternate, .maskControl]
u?.post(tap: .cgSessionEventTap)
print("已合成 ⌃⌥⌘B")
