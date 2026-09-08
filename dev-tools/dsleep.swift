// 显示器睡眠状态检测: CGDisplayIsAsleep
import CoreGraphics
let id = CGMainDisplayID()
print("asleep=\(CGDisplayIsAsleep(id) != 0 ? 1 : 0)")
