// blankscreen —— 关屏但不睡眠（显示器熄灭，系统保持唤醒，远程可正常操控）
//
// 设计要点:
//  1. 采用「亮度归零」而非「显示器硬件睡眠」，确保屏幕共享/远程桌面仍能正常抓帧，
//     且任何按键鼠标都不会意外恢复显示（恢复完全由本程序控制）。
//  2. 黑屏期间由 caffeinate -di 持有断言，阻止系统空闲睡眠与显示器硬件睡眠。
//  3. 以 0.5s 周期重设亮度为 0，压制环境光自动亮度。
//  4. 两种运行形态:
//     - 常驻服务(launchd): 热键 / CLI 信号 均可切换开关，开机自启
//     - 一次性 daemon:     `blankscreen off` 进入，恢复后进程退出
import Foundation
import CoreGraphics
import AppKit
import Carbon.HIToolbox
import Darwin

// MARK: - 路径
let home = NSHomeDirectory()
let base = home + "/Library/Application Support/blankscreen"
let stateFile = base + "/brightness.state"     // 存在即表示处于黑屏（同时保存待恢复亮度）
let pidFile = base + "/daemon.pid"             // 一次性 daemon
let serviceFile = base + "/service.pid"        // 常驻服务
let configFile = base + "/config.json"         // 持久化热键等配置
let plistFile = home + "/Library/LaunchAgents/com.blankscreen.agent.plist"
let logPath = base + "/blankscreen.log"
let commandFile = base + "/command"        // CLI -> 菜单栏 App 的指令文件
// 关屏被拒绝（电量过低 / 亮度接口不可用）时，常驻进程把原因写这里，
// 让发起命令的 CLI 能读到并明确提示用户，而不是只说「指令已发送」。
let rejectFile = base + "/reject"
let serviceLog = base + "/service.log"
let label = "com.blankscreen.agent"
let fm = FileManager.default
try? fm.createDirectory(atPath: base, withIntermediateDirectories: true)

func log(_ s: String) {
    // 轮转：常驻服务会长期运行，防日志无限增长
    if let a = try? fm.attributesOfItem(atPath: logPath),
       let size = a[.size] as? UInt64, size > 262_144 {
        try? fm.removeItem(atPath: logPath + ".old")
        try? fm.moveItem(atPath: logPath, toPath: logPath + ".old")
    }
    let line = "\(Date()) \(s)\n"
    if let h = FileHandle(forWritingAtPath: logPath) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
    else { fm.createFile(atPath: logPath, contents: line.data(using: .utf8)) }
}

// 真实可执行文件路径（CommandLine.arguments[0] 在经 PATH 调用时不含目录）
var execBuf = [CChar](repeating: 0, count: Int(PATH_MAX))
var execSize = UInt32(execBuf.count)
_ = _NSGetExecutablePath(&execBuf, &execSize)
let exePath = String(cString: execBuf)
@discardableResult func sh(_ exe: String, _ a: [String]) -> Int32 {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = a
    p.standardOutput = nil; p.standardError = nil; p.standardInput = nil
    try? p.run(); p.waitUntilExit(); return p.terminationStatus
}
/// 捕获 stdout。必须先读再 waitUntilExit：子进程输出超过管道缓冲时，
/// 先等待会与子进程互相阻塞形成死锁。
func runCapture(_ exe: String, _ a: [String]) -> String? {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = a
    p.standardInput = FileHandle.nullDevice
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
    do { try p.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8)
}

// MARK: - 进程归属校验
// 仅用 kill(pid,0) 判断进程存活是不够的：进程退出后 pid 会被系统复用，
// 此时向该 pid 发 SIGUSR1 会打到无关进程上（SIGUSR1 默认动作是终止！）。
// 因此必须核对 pid 对应的可执行文件路径确实属于 blankscreen。
func procPath(_ pid: Int32) -> String? {
    var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
    let n = proc_pidpath(pid, &buf, UInt32(buf.count))
    return n > 0 ? String(cString: buf) : nil
}
/// 取不到路径时返回 true（保持原有行为，避免因权限等因素误判导致功能不可用）
func isOurs(_ pid: Int32) -> Bool {
    guard let p = procPath(pid) else { return true }
    // 同时覆盖 /opt/homebrew/bin/blankscreen 与 .../BlankScreenBar.app/.../BlankScreenBar
    return p.lowercased().contains("blankscreen")
}

// MARK: - 轮询等待（比固定 usleep 可靠：慢机器上不会误判超时）
func waitUntil(timeout: TimeInterval, _ predicate: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if predicate() { return true }
        usleep(100_000)
    }
    return predicate()
}

// MARK: - 配置（常驻服务经 launchd 启动，无法传命令行参数，故持久化）
// 与 BlankScreenBar.app 共用同一个 config.json；字段全部可缺省，旧版文件仍能读取
let MOD_CTRL: UInt64  = 1 << 18
let MOD_ALT: UInt64   = 1 << 19
let MOD_CMD: UInt64   = 1 << 20
let MOD_SHIFT: UInt64 = 1 << 17

struct Config: Codable {
    var keyCode: Int64 = 11                                  // B
    var modFlags: UInt64 = MOD_CTRL | MOD_ALT | MOD_CMD      // 默认 ⌃⌥⌘
    var timeout: Double = 43200                              // 一次性模式安全兜底，秒；0 = 不限
    var restoreFixed: Float? = nil                           // nil = 恢复进入黑屏前的亮度
    var batteryFloor: Int = 20                               // 电量下限 %，0 = 不限制

    enum CodingKeys: String, CodingKey { case keyCode, modFlags, timeout, restoreFixed, batteryFloor }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try c.decodeIfPresent(Int64.self, forKey: .keyCode) ?? 11
        modFlags = try c.decodeIfPresent(UInt64.self, forKey: .modFlags) ?? (MOD_CTRL | MOD_ALT | MOD_CMD)
        timeout = try c.decodeIfPresent(Double.self, forKey: .timeout) ?? 43200
        restoreFixed = try c.decodeIfPresent(Float.self, forKey: .restoreFixed)
        batteryFloor = try c.decodeIfPresent(Int.self, forKey: .batteryFloor) ?? 20
    }
}
func loadConfig() -> Config {
    if let d = try? Data(contentsOf: URL(fileURLWithPath: configFile)),
       let c = try? JSONDecoder().decode(Config.self, from: d) { return c }
    return Config()
}
func saveConfig(_ c: Config) {
    if let d = try? JSONEncoder().encode(c) { try? d.write(to: URL(fileURLWithPath: configFile)) }
}

// MARK: - 亮度读写 (DisplayServices 私有框架)
let dsHandle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
typealias DSGet = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
typealias DSSet = @convention(c) (UInt32, Float) -> Int32

// DisplayServices 是可移除的私有框架：一旦 Apple 在新系统里拿掉它，所有亮度操作都会静默失效。
// 显式暴露可用状态，让 status / 黑屏入口都能明确报错，而不是「命令成功但屏幕没变化」。
var dsAvailable: Bool {
    guard let h = dsHandle else { return false }
    return dlsym(h, "DisplayServicesGetBrightness") != nil
        && dlsym(h, "DisplayServicesSetBrightness") != nil
}

func readBrightness() -> Float {
    guard let h = dsHandle, let p = dlsym(h, "DisplayServicesGetBrightness") else { return -1 }
    let f = unsafeBitCast(p, to: DSGet.self)
    var v: Float = -1
    return f(CGMainDisplayID(), &v) == 0 ? v : -1
}
// 返回 false = 设置失败（实测该 API 成功时返回 0）。调用方必须据此提示用户，
// 否则用户会以为关屏成功、实际屏幕还亮着。
@discardableResult
func setBrightness(_ v: Float) -> Bool {
    guard let h = dsHandle, let p = dlsym(h, "DisplayServicesSetBrightness") else { return false }
    return unsafeBitCast(p, to: DSSet.self)(CGMainDisplayID(), v) == 0
}
@discardableResult
func restoreBrightness(_ v: Float) -> Bool {
    let a = setBrightness(v); usleep(300_000); let b = setBrightness(v)
    return a || b          // 两次里有一次成功即算成功（第二次是压制环境光自动亮度的重试）
}

// MARK: - 电池状态与通知
// pmset -g batt 免任何授权。只有「电池供电且正在放电」才算有耗尽风险：
// 插着电时哪怕电量低也不会耗尽，此时阻止用户关屏毫无意义。
struct Battery { var onBattery = false, discharging = false, percent = 100 }

func batteryStatus() -> Battery {
    var b = Battery()
    // 测试钩子：BS_SIMULATE_BATTERY="电量,batt|ac,discharging|charging"
    // 例: BS_SIMULATE_BATTERY="15,batt,discharging" blankscreen off
    // 仅供验证电量保护路径（插电的机器无法真实触发），正式使用不需要也不读取它。
    if let sim = ProcessInfo.processInfo.environment["BS_SIMULATE_BATTERY"] {
        let parts = sim.lowercased().split(separator: ",").map(String.init)
        if let p = parts.first, let v = Int(p), (0...100).contains(v) {
            b.percent = v
            b.onBattery = parts.contains("batt")
            b.discharging = parts.contains("discharging")
            return b
        }
    }
    guard let out = runCapture("/usr/bin/pmset", ["-g", "batt"]), !out.isEmpty else { return b }
    b.onBattery = out.contains("Battery Power")
    b.discharging = out.range(of: "discharging", options: .caseInsensitive) != nil
    for tok in out.split(whereSeparator: { " \t\n;".contains($0) }) {
        if tok.hasSuffix("%"), let v = Int(tok.dropLast()) { b.percent = v; break }
    }
    return b
}

func notify(_ msg: String) {
    let safe = msg.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    _ = runCapture("/usr/bin/osascript", ["-e", "display notification \"\(safe)\" with title \"BlankScreen\""])
}

// 常用键位名（仅用于展示）
let keyTable: [(String, Int64)] = [
    ("A", 0), ("B", 11), ("C", 8), ("D", 2), ("E", 14), ("F", 3), ("G", 5), ("H", 4),
    ("I", 34), ("J", 38), ("K", 40), ("L", 37), ("M", 46), ("N", 45), ("O", 31), ("P", 35),
    ("Q", 12), ("R", 15), ("S", 1), ("T", 17), ("U", 32), ("V", 9), ("W", 13), ("X", 7),
    ("Y", 16), ("Z", 6), ("F13", 105), ("Space", 49)
]
func keyName(_ code: Int64) -> String { keyTable.first { $0.1 == code }?.0 ?? "keyCode \(code)" }
func modsText(_ flags: UInt64) -> String {
    var s = ""
    if flags & MOD_CTRL  != 0 { s += "⌃" }
    if flags & MOD_ALT   != 0 { s += "⌥" }
    if flags & MOD_SHIFT != 0 { s += "⇧" }
    if flags & MOD_CMD   != 0 { s += "⌘" }
    return s.isEmpty ? "（无修饰键）" : s
}

// MARK: - 全局热键（Carbon Event Manager，无需任何系统授权）
// 说明：曾用 CGEventTap 监听全局按键，那条链路强制要求「输入监控」授权，
// 且 ad-hoc 签名的二进制每次重新编译 TCC 授权都会失效。Carbon
// RegisterEventHotKey 由 WindowServer 直接派发，零授权、重装不失效。
// 注意：Carbon 热键事件只在 NSApplication 事件循环中派发，daemon/service
// 必须经 runAppLoop() 启动（裸 RunLoop 收不到）。
var carbonHotKeyRef: EventHotKeyRef?
var carbonHandlerRef: EventHandlerRef?
var carbonFire: (() -> Void)?

func installHotkey(keyCode: Int64, modFlags: UInt64 = MOD_CTRL | MOD_ALT | MOD_CMD, fire: @escaping () -> Void) {
    carbonFire = fire
    if carbonHandlerRef == nil {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let st = InstallEventHandler(GetEventDispatcherTarget(),
            { _, _, _ -> OSStatus in
                DispatchQueue.main.async { carbonFire?() }
                return noErr
            }, 1, &spec, nil, &carbonHandlerRef)
        guard st == noErr else { log("热键事件处理器安装失败 status=\(st)"); return }
    }
    if let old = carbonHotKeyRef { UnregisterEventHotKey(old); carbonHotKeyRef = nil }
    var m: UInt32 = 0
    if modFlags & MOD_CMD   != 0 { m |= UInt32(cmdKey) }
    if modFlags & MOD_SHIFT != 0 { m |= UInt32(shiftKey) }
    if modFlags & MOD_ALT   != 0 { m |= UInt32(optionKey) }
    if modFlags & MOD_CTRL  != 0 { m |= UInt32(controlKey) }
    let hid = EventHotKeyID(signature: 0x424C4E4B, id: 1)   // 'BLNK'
    let st = RegisterEventHotKey(UInt32(keyCode), m, hid, GetEventDispatcherTarget(), 0, &carbonHotKeyRef)
    if st == noErr {
        log("全局热键已注册 \(modsText(modFlags))\(keyName(keyCode))（Carbon 链路，无需授权）")
    } else if st == OSStatus(eventHotKeyExistsErr) {
        log("热键注册失败 \(modsText(modFlags))\(keyName(keyCode))：组合已被其他 App 占用（blankscreen config --mods ... --key ... 换一个）")
    } else {
        log("热键注册失败 \(modsText(modFlags))\(keyName(keyCode)) status=\(st)")
    }
}

/// daemon / service 的事件循环。Carbon 全局热键只经 NSApplication 派发，
/// 裸 RunLoop 收不到；accessory 策略保证 CLI 进程不出现 Dock 图标。
func runAppLoop() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.run()
    exit(0)
}

// 信号统一走「传统 handler 置位全局标志 + NSTimer 主循环轮询」：
// AppKit 事件循环下 GCD timer / signal source 交付不可靠（实测延迟数秒且乱序）
var cliSignalOff = false
var cliSignalOn = false
var cliSignalTerm = false

// MARK: - 形态一：一次性 daemon
func runDaemon(keyCode: Int64, timeout: TimeInterval?) -> Never {
    let cfg = loadConfig()
    // DisplayServices 不可用时，黑屏根本不会发生——必须明确报错，不能让命令「成功」但屏幕还亮着
    guard dsAvailable else {
        let m = "无法访问 DisplayServices 私有框架，亮度控制不可用（本 macOS 可能已移除它）"
        try? m.write(toFile: rejectFile, atomically: true, encoding: .utf8)
        FileHandle.standardError.write("""
        错误：\(m)
        本工具依赖该框架把亮度置 0 实现关屏。请在
        https://github.com/Mihooni/blankscreen/issues 反馈你的系统版本。
        """.data(using: .utf8)!)
        exit(1)
    }
    // 电量下限：电池供电时拒绝进入黑屏。黑屏 + 阻止睡眠的组合最容易让人忘记，
    // 一旦耗尽电池，未保存的工作会随之丢失。
    if cfg.batteryFloor > 0 {
        let b = batteryStatus()
        if b.onBattery && b.discharging && b.percent <= cfg.batteryFloor {
            let m = "电量 \(b.percent)% 低于下限 \(cfg.batteryFloor)%，已取消关屏（避免耗尽电池）"
            try? m.write(toFile: rejectFile, atomically: true, encoding: .utf8)
            FileHandle.standardError.write((m + "\n").data(using: .utf8)!)
            log(m); notify(m)
            exit(1)
        }
    }
    try? fm.removeItem(atPath: rejectFile)
    // 只读一次亮度：重复调用既浪费，又可能因并发自动亮度调整得到不一致的值
    let current = max(readBrightness(), 0.0)
    let saved = current > 0.001 ? current : 0.5          // 已是 0（如上次遗留）时给个可用兜底
    let restoreTarget = cfg.restoreFixed ?? saved
    try? String(saved).write(toFile: stateFile, atomically: true, encoding: .utf8)
    try? String(ProcessInfo.processInfo.processIdentifier).write(toFile: pidFile, atomically: true, encoding: .utf8)
    log("daemon 启动 pid=\(ProcessInfo.processInfo.processIdentifier) 原亮度=\(saved)")

    let caff = Process()
    caff.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
    // -w 自身 pid：本进程一旦退出（哪怕被 SIGKILL），caffeinate 也会自动退出，
    // 杜绝残留的孤儿 caffeinate 继续持有「禁止显示器睡眠」断言。
    caff.arguments = ["-di", "-w", String(ProcessInfo.processInfo.processIdentifier)]
    try? caff.run()

    var restored = false
    var pinTimer: Timer?                  // 用 NSTimer：AppKit 循环下 GCD timer 交付不可靠
    let pin = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
        if !restored { setBrightness(0.0) }   // 0.5s 周期重设，压制环境光自动亮度
    }
    RunLoop.main.add(pin, forMode: .common)
    pinTimer = pin

    func cleanup() {
        guard !restored else { return }
        restored = true
        pinTimer?.invalidate()
        log("恢复亮度 \(restoreTarget)，结束 caffeinate")
        restoreBrightness(restoreTarget)
        caff.terminate()
        try? fm.removeItem(atPath: pidFile)
        try? fm.removeItem(atPath: stateFile)
        exit(0)
    }

    // SIGTERM/SIGINT 只置标志，由下方 Timer 在主线程安全收尾
    cliSignalTerm = false
    for sig in [SIGTERM, SIGINT, SIGHUP] { signal(sig) { _ in cliSignalTerm = true } }
    let sigTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
        if cliSignalTerm { log("收到终止信号"); cleanup() }
    }
    RunLoop.main.add(sigTimer, forMode: .common)

    installHotkey(keyCode: keyCode, modFlags: cfg.modFlags) { log("热键触发"); cleanup() }

    if let t = timeout {
        Timer.scheduledTimer(withTimeInterval: t, repeats: false) { _ in log("超时自动恢复"); cleanup() }
    }
    // 黑屏期间持续监控电量：跌破下限就自动恢复，别等电池耗尽才被发现
    if cfg.batteryFloor > 0 {
        let bt = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            guard !restored else { return }
            let b = batteryStatus()
            guard b.onBattery && b.discharging, b.percent <= cfg.batteryFloor else { return }
            let m = "电量 \(b.percent)% 已达下限 \(cfg.batteryFloor)%，自动恢复显示"
            log(m); notify(m)
            cleanup()
        }
        RunLoop.main.add(bt, forMode: .common)
    }
    runAppLoop()
}

// MARK: - 形态二：常驻服务（热键 / 信号 切换开关）
func runService(keyCode: Int64) -> Never {
    let cfg = loadConfig()
    let myPid = ProcessInfo.processInfo.processIdentifier
    // 互斥：已有存活常驻服务（CLI daemon 或菜单栏 App）时拒绝启动，避免双服务抢状态
    if let other = servicePid(), other != myPid {
        log("service 拒绝启动 pid=\(myPid)：已有常驻服务 pid=\(other) 在运行")
        FileHandle.standardError.write("已有常驻服务在运行 (pid \(other))，本实例退出\n".data(using: .utf8)!)
        exit(1)
    }
    try? String(myPid).write(toFile: serviceFile, atomically: true, encoding: .utf8)
    log("service 启动 pid=\(myPid)")

    // 自愈：上次异常退出遗留的黑屏状态
    if let s = try? String(contentsOfFile: stateFile, encoding: .utf8),
       let v = Float(s.trimmingCharacters(in: .whitespacesAndNewlines)), v > 0.001 {
        log("发现遗留黑屏状态，自愈恢复到 \(v)")
        restoreBrightness(v)
    }
    try? fm.removeItem(atPath: stateFile)

    var blacked = false
    var saved: Float = 0.5
    var caff: Process?
    var pinTimer: Timer?
    var timeoutTimer: Timer?     // 兜底：热键失效/被占用时也能自动恢复
    var battTimer: Timer?        // 黑屏期间的电量守卫

    func restore() {
        guard blacked else { return }
        blacked = false
        pinTimer?.invalidate(); pinTimer = nil
        timeoutTimer?.invalidate(); timeoutTimer = nil
        battTimer?.invalidate(); battTimer = nil
        let target = cfg.restoreFixed ?? saved
        log("service 恢复显示 \(target)")
        restoreBrightness(target)
        caff?.terminate(); caff = nil
        try? fm.removeItem(atPath: stateFile)
    }

    /// 记录拒绝原因并告知用户；CLI 通过 rejectFile 读回，避免「已发送指令」的误导性成功
    func reject(_ m: String) -> Bool {
        log(m); notify(m)
        try? m.write(toFile: rejectFile, atomically: true, encoding: .utf8)
        return false
    }
    /// 返回 false = 没能进入黑屏（亮度接口不可用或电量过低）。调用方必须据此提示用户，
    /// 否则会出现「命令看起来成功、屏幕其实还亮着」的静默失败。
    @discardableResult
    func blackout() -> Bool {
        guard !blacked else { return true }
        guard dsAvailable else {
            return reject("亮度接口不可用（DisplayServices 缺失），无法关屏")
        }
        // 电量下限：关屏 + 阻止睡眠的组合让人最容易忘记，耗尽电池会带走未保存的工作
        if cfg.batteryFloor > 0 {
            let b = batteryStatus()
            if b.onBattery && b.discharging && b.percent <= cfg.batteryFloor {
                return reject("电量 \(b.percent)% 低于下限 \(cfg.batteryFloor)%，已取消关屏（避免耗尽电池）")
            }
        }
        try? fm.removeItem(atPath: rejectFile)
        let cur = max(readBrightness(), 0)
        saved = cur > 0.001 ? cur : saved
        try? String(saved).write(toFile: stateFile, atomically: true, encoding: .utf8)
        blacked = true
        if !setBrightness(0.0) { log("警告：首次设置亮度 0 失败") }
        let c = Process()
        c.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        // -w 自身 pid：本进程退出后 caffeinate 自动退出，杜绝孤儿断言残留
        c.arguments = ["-di", "-w", String(myPid)]
        try? c.run()
        caff = c
        let t = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            if blacked { setBrightness(0.0) }
        }
        RunLoop.main.add(t, forMode: .common)
        pinTimer = t
        // 兜底超时（与菜单栏 App 一致）：这是热键注册失败/被占用时唯一的自动恢复手段，
        // 缺失会导致「黑屏后无任何自动恢复途径」的永久黑屏。
        timeoutTimer?.invalidate(); timeoutTimer = nil
        if cfg.timeout > 0 {
            let tt = Timer.scheduledTimer(withTimeInterval: cfg.timeout, repeats: false) { _ in
                log("兜底超时 \(Int(cfg.timeout))s，自动恢复")
                restore()
            }
            RunLoop.main.add(tt, forMode: .common)
            timeoutTimer = tt
        }
        // 电量守卫：黑屏期间每 30s 复查，跌破下限立即恢复
        battTimer?.invalidate(); battTimer = nil
        if cfg.batteryFloor > 0 {
            let bt = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
                guard blacked else { return }
                let b = batteryStatus()
                guard b.onBattery && b.discharging, b.percent <= cfg.batteryFloor else { return }
                let m = "电量 \(b.percent)% 已达下限 \(cfg.batteryFloor)%，自动恢复显示"
                log(m); notify(m)
                restore()
            }
            RunLoop.main.add(bt, forMode: .common)
            battTimer = bt
        }
        log("service 进入黑屏，原亮度 \(saved)，兜底 \(Int(cfg.timeout))s，电量下限 \(cfg.batteryFloor)%")
        return true
    }

    func shutdown() {
        restore()
        try? fm.removeItem(atPath: serviceFile)
        exit(0)
    }

    installHotkey(keyCode: keyCode, modFlags: cfg.modFlags) {
        log("热键触发")
        if blacked { restore() } else { _ = blackout() }
    }

    // 信号：CLI 用 SIGUSR1(关)/SIGUSR2(开)/SIGTERM(退出)，经命令文件 + 标志双通道。
    // 传统 handler 置位全局标志，主循环 Timer 轮询执行（AppKit 下 GCD signal source 不可靠）。
    // 菜单栏 App 会忽略信号、只认命令文件；本 CLI 服务两者都认。
    cliSignalOff = false; cliSignalOn = false; cliSignalTerm = false
    signal(SIGUSR1) { _ in cliSignalOff = true }
    signal(SIGUSR2) { _ in cliSignalOn = true }
    signal(SIGTERM) { _ in cliSignalTerm = true }
    signal(SIGINT)  { _ in cliSignalTerm = true }
    let sigTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
        if cliSignalOff { cliSignalOff = false; log("收到 SIGUSR1"); blackout() }
        if cliSignalOn  { cliSignalOn = false;  log("收到 SIGUSR2"); restore() }
        if cliSignalTerm { log("收到终止信号"); shutdown() }
    }
    RunLoop.main.add(sigTimer, forMode: .common)

    runAppLoop()
}

// MARK: - 状态查询
func servicePid() -> Int32? {
    guard let s = try? String(contentsOfFile: serviceFile, encoding: .utf8),
          let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)),
          kill(pid, 0) == 0 else { return nil }
    // pid 可能已被系统复用于无关进程：此时绝不能发信号（SIGUSR1 默认动作是终止）
    guard isOurs(pid) else {
        log("service.pid 中的 pid=\(pid) 已不属于 blankscreen（pid 被复用），清理陈旧记录")
        try? fm.removeItem(atPath: serviceFile)
        return nil
    }
    return pid
}
func daemonRunning() -> (pid: Int32, brightness: String)? {
    guard let s = try? String(contentsOfFile: pidFile, encoding: .utf8),
          let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)),
          kill(pid, 0) == 0,
          let b = try? String(contentsOfFile: stateFile, encoding: .utf8) else { return nil }
    guard isOurs(pid) else {
        log("daemon.pid 中的 pid=\(pid) 已不属于 blankscreen（pid 被复用），清理陈旧记录")
        try? fm.removeItem(atPath: pidFile)
        return nil
    }
    return (pid, b.trimmingCharacters(in: .whitespacesAndNewlines))
}

// MARK: - 命令分发
let args = CommandLine.arguments
let cmd = args.count > 1 ? args[1] : "help"

/// 用 launchctl print 探测指定 label 是否已注册（退出码 0 = 已注册）
func runProbe(_ label: String) -> Bool {
    let r = Process()
    r.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    r.arguments = ["print", "gui/\(getuid())/\(label)"]
    r.standardOutput = FileHandle.nullDevice
    r.standardError = FileHandle.nullDevice
    r.standardInput = FileHandle.nullDevice
    do { try r.run() } catch { return false }
    r.waitUntilExit()
    return r.terminationStatus == 0
}

/// 常驻进程/daemon 拒绝关屏时留下的原因（读完即清，避免陈旧原因误导下一次调用）
func rejectReason() -> String? {
    guard let s = try? String(contentsOfFile: rejectFile, encoding: .utf8) else { return nil }
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    try? fm.removeItem(atPath: rejectFile)
    return t.isEmpty ? nil : t
}

switch cmd {
case "daemon":
    let cfg = loadConfig()
    var keyCode: Int64 = cfg.keyCode
    var timeout: TimeInterval? = cfg.timeout > 0 ? cfg.timeout : nil
    var serviceMode = false
    var i = 2
    while i < args.count {
        if args[i] == "--key", i + 1 < args.count { keyCode = Int64(args[i + 1]) ?? 11; i += 2 }
        else if args[i] == "--timeout", i + 1 < args.count { timeout = Double(args[i + 1]); i += 2 }
        else if args[i] == "--no-timeout" { timeout = nil; i += 1 }
        else if args[i] == "--service" { serviceMode = true; i += 1 }
        else { i += 1 }
    }
    serviceMode ? runService(keyCode: keyCode) : runDaemon(keyCode: keyCode, timeout: timeout)

// MARK: 常驻服务管理
case "service":
    let sub = args.count > 2 ? args[2] : ""
    switch sub {
    case "install":
        // 菜单栏 App 已注册为常驻服务时，CLI 服务不再安装（功能完全重叠，会互相抢状态）
        if runProbe("com.blankscreen.bar") {
            print("检测到菜单栏 App（BlankScreenBar）已注册为常驻服务。")
            print("两者功能完全重叠，同时运行会互相抢占状态。")
            print("→ 建议：直接使用菜单栏 App，无需安装本 CLI 服务。")
            print("→ 如确实要改用 CLI 服务，请先在菜单栏设置中关闭「登录时启动」。")
            exit(1)
        }
        let exe = exePath
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(label)</string>
            <key>ProgramArguments</key>
            <array><string>\(exe)</string><string>daemon</string><string>--service</string></array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
            <key>StandardOutPath</key><string>\(serviceLog)</string>
            <key>StandardErrorPath</key><string>\(serviceLog)</string>
        </dict>
        </plist>
        """
        try? plist.write(toFile: plistFile, atomically: true, encoding: .utf8)
        let gui = "gui/\(getuid())"
        sh("/bin/launchctl", ["bootout", "\(gui)/\(label)"])
        let r = sh("/bin/launchctl", ["bootstrap", gui, plistFile])
        if r != 0 { sh("/bin/launchctl", ["load", "-w", plistFile]) }
        sh("/bin/launchctl", ["kickstart", "-k", "\(gui)/\(label)"])
        usleep(900_000)
        if let pid = servicePid() {
            print("常驻服务已启动 pid=\(pid)")
            print("  热键 ⌃⌥⌘B 直接开关；也可用 blankscreen off / on")
            print("  开机自启，日志: \(serviceLog)")
        } else {
            print("""
            plist 已写入: \(plistFile)
            但当前环境无法与 launchd 通信（被沙箱或自动化环境调用时常见）。

            请在「终端」里手动执行:
              blankscreen service install

            临时常驻（不依赖 launchd，重启后失效）:
              nohup blankscreen daemon --service >/dev/null 2>&1 &
            """)
        }
    case "uninstall":
        sh("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        sh("/bin/launchctl", ["unload", plistFile])
        try? fm.removeItem(atPath: plistFile)
        try? fm.removeItem(atPath: serviceFile)
        print("常驻服务已卸载")
    case "status":
        if let pid = servicePid() {
            print("常驻服务: 运行中 pid=\(pid)，\(fm.fileExists(atPath: stateFile) ? "当前黑屏中" : "当前正常显示")")
        } else {
            print("常驻服务: 未运行（用 `blankscreen service install` 启用）")
        }
    default:
        print("用法: blankscreen service install | uninstall | status")
    }

case "config":
    var c = loadConfig()
    var i = 2
    while i < args.count {
        if args[i] == "--key", i + 1 < args.count { c.keyCode = Int64(args[i + 1]) ?? 11; i += 2 }
        else if args[i] == "--timeout", i + 1 < args.count { c.timeout = Double(args[i + 1]) ?? 43200; i += 2 }
        else if args[i] == "--mods", i + 1 < args.count {
            var f: UInt64 = 0
            for t in args[i + 1].lowercased().split(separator: ",") {
                switch t {
                case "ctrl", "control": f |= MOD_CTRL
                case "alt", "option":  f |= MOD_ALT
                case "cmd", "command": f |= MOD_CMD
                case "shift":          f |= MOD_SHIFT
                default: break
                }
            }
            c.modFlags = f; i += 2
        }
        else if args[i] == "--restore", i + 1 < args.count {
            let v = args[i + 1].lowercased()
            c.restoreFixed = (v == "original" || v == "auto") ? nil : (Float(v) ?? 0.5); i += 2
        }
        else if args[i] == "--battery", i + 1 < args.count {
            if let v = Int(args[i + 1]), (0...100).contains(v) {
                c.batteryFloor = v
            } else {
                print("错误：--battery 需要 0-100 的整数（0 = 不限制），收到: \(args[i + 1])"); exit(1)
            }
            i += 2
        }
        else if args[i] == "--reset" { c = Config(); i += 1 }
        else { i += 1 }
    }
    // 热键必须带至少一个修饰键：Carbon RegisterEventHotKey 对无修饰键组合必定注册失败，
    // 存下来只会让热键静默失效（与菜单栏 App 的约束保持一致）。
    if args.count > 2 && c.modFlags == 0 {
        print("错误：全局热键必须包含至少一个修饰键，否则系统无法注册（会静默失效）。")
        print("示例: blankscreen config --mods cmd,shift --key 0")
        exit(1)
    }
    if args.count > 2 { saveConfig(c); print("配置已保存: \(configFile)") }
    var m = ""
    if c.modFlags & MOD_CTRL  != 0 { m += "⌃" }
    if c.modFlags & MOD_ALT   != 0 { m += "⌥" }
    if c.modFlags & MOD_SHIFT != 0 { m += "⇧" }
    if c.modFlags & MOD_CMD   != 0 { m += "⌘" }
    print("  热键: \(m)\(keyName(c.keyCode))   (keyCode \(c.keyCode), mods \(c.modFlags))")
    print("  一次性模式超时: \(Int(c.timeout)) 秒（\(String(format: "%.1f", c.timeout / 3600)) 小时，0 = 不限）")
    print("  恢复亮度: \(c.restoreFixed.map { String(format: "固定 %.0f%%", $0 * 100) } ?? "进入黑屏前的亮度")")
    print("  电量下限: \(c.batteryFloor > 0 ? "\(c.batteryFloor)%（电池供电且放电时，低于此值拒绝关屏并自动恢复）" : "不限制")")
    print("  修改: blankscreen config --key 11 --mods ctrl,alt,cmd --timeout 43200 --battery 20 --restore original")

case "off":
    if let pid = servicePid() {                      // 常驻模式：命令文件 + 信号双通道
        try? fm.removeItem(atPath: rejectFile)        // 先清掉上一次的拒绝记录
        try? "off".write(toFile: commandFile, atomically: true, encoding: .utf8)
        kill(pid, SIGUSR1)                            // 菜单栏 App 会忽略信号、只认命令文件
        // 轮询等待：要么进入黑屏（stateFile），要么被拒绝（rejectFile）
        let ok = waitUntil(timeout: 3.0) { fm.fileExists(atPath: stateFile) || fm.fileExists(atPath: rejectFile) }
        if let reason = rejectReason() {
            FileHandle.standardError.write("未能关屏：\(reason)\n".data(using: .utf8)!)
            exit(1)
        }
        print(ok
              ? "已进入黑屏（常驻服务 pid=\(pid)）恢复: 热键或 blankscreen on"
              : "已发送进入黑屏指令（3s 内未确认，请查看 \(logPath)）")
        exit(0)
    }
    if let r = daemonRunning() { print("已在黑屏模式 (pid \(r.pid))，原亮度 \(r.brightness)"); exit(0) }
    var dargs = ["daemon"]                            // 一次性模式
    var i = 2
    while i < args.count { dargs.append(args[i]); i += 1 }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exePath)
    p.arguments = dargs
    p.standardOutput = nil; p.standardError = nil; p.standardInput = nil
    try? p.run()
    _ = waitUntil(timeout: 3.0) { daemonRunning() != nil }
    if let r = daemonRunning() {
        print("已进入黑屏模式 pid=\(r.pid) 原亮度=\(r.brightness)")
        print("恢复方式: 热键 ⌃⌥⌘B  /  blankscreen on  /  远程执行同一命令")
    } else if let reason = rejectReason() {
        FileHandle.standardError.write("未能关屏：\(reason)\n".data(using: .utf8)!)
        exit(1)
    } else {
        print("启动失败，请查看 \(logPath)")
        exit(1)
    }

case "on":
    if let pid = servicePid() {
        try? "on".write(toFile: commandFile, atomically: true, encoding: .utf8)
        kill(pid, SIGUSR2)
        let ok = waitUntil(timeout: 3.0) { !fm.fileExists(atPath: stateFile) }
        print(ok ? "已恢复显示" : "恢复指令已发送（3s 内仍在黑屏，请查看 \(logPath)）")
        exit(0)
    }
    guard let r = daemonRunning() else { print("当前不在黑屏模式"); exit(0) }
    kill(r.pid, SIGTERM)
    _ = waitUntil(timeout: 3.0) { daemonRunning() == nil }
    print("已恢复显示，亮度 \(r.brightness)，当前实际亮度 \(readBrightness())")

case "status":
    let cfg = loadConfig()
    let b = batteryStatus()
    let battText = b.onBattery
        ? "电池 \(b.percent)%\(b.discharging ? "（放电中）" : "")"
        : "已接电源"
    if !dsAvailable { print("⚠️  亮度接口不可用（DisplayServices 缺失），关屏功能将无法工作") }
    if let pid = servicePid() {
        print("常驻服务运行中 pid=\(pid)，\(fm.fileExists(atPath: stateFile) ? "黑屏中" : "正常显示")，当前亮度 \(readBrightness())")
    } else if let r = daemonRunning() {
        print("一次性模式黑屏中 pid=\(r.pid) 待恢复亮度=\(r.brightness) 当前亮度 \(readBrightness())")
    } else {
        print("正常模式（无常驻服务），当前亮度 \(readBrightness())")
    }
    print("电源: \(battText)，电量下限 \(cfg.batteryFloor > 0 ? "\(cfg.batteryFloor)%" : "不限")")

case "bright":
    if args.count > 2, let v = Float(args[2]) {
        if setBrightness(v) { print("亮度 -> \(v)") }
        else {
            FileHandle.standardError.write("设置亮度失败：亮度接口不可用或被系统拒绝（当前 macOS 可能已移除 DisplayServices）\n".data(using: .utf8)!)
            exit(1)
        }
    } else {
        let v = readBrightness()
        if v < 0 { print("读取亮度失败：亮度接口不可用"); exit(1) }
        print("当前亮度 \(v)")
    }

default:
    print("""
    blankscreen —— 关屏但不睡眠（显示器熄灭，系统保持唤醒，远程可正常操控）

      推荐方式：菜单栏 App（BlankScreenBar.app），热键零授权。见项目 README。

    CLI 用法:
      blankscreen service install            安装常驻服务（开机自启，热键直接开关）
      blankscreen service uninstall          卸载常驻服务
      blankscreen off / on                   进入 / 退出黑屏
      blankscreen status                     查看状态（含电源与电量）
      blankscreen config --key 11            查看/修改热键、超时、电量下限
      blankscreen bright [0.0-1.0]           直接读写亮度

      不用常驻服务时: blankscreen off [--timeout 秒] [--no-timeout]

    默认热键: ⌃⌥⌘B (B=keyCode 11)，修改: blankscreen config --key 11 --mods ctrl,alt,cmd
    热键走系统级全局热键（Carbon），不需要任何授权；若组合被其他 App 占用会写入日志。
    未注册热键时仍可用: blankscreen on（含远程 SSH）/ 一次性模式 12 小时超时兜底
    电量保护: 默认低于 20% 且使用电池时拒绝关屏，黑屏中跌破则自动恢复（config --battery 0 关闭）
    """)
}
