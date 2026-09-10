// BlankScreenBar —— blankscreen 的菜单栏控制器 + 可视化设置
//
// 与 CLI 的协作方式:
//   - 共用 ~/Library/Application Support/blankscreen/ 下的 config.json 与状态文件
//   - 本 App 接管 service.pid，因此 `blankscreen off / on / status`
//     会自动识别为常驻服务，通过 SIGUSR1 / SIGUSR2 控制本进程，两边状态永远一致
//   - 本 App 可直接由 launchd 拉起实现开机自启（不依赖 CLI 的 service install）
import Foundation
import Cocoa
import CoreGraphics
import Carbon.HIToolbox
import Darwin

// MARK: - 路径（与 CLI 完全一致）
let fm = FileManager.default
let home = NSHomeDirectory()
let base = home + "/Library/Application Support/blankscreen"
let stateFile = base + "/brightness.state"
let pidFile = base + "/daemon.pid"
let serviceFile = base + "/service.pid"
let configFile = base + "/config.json"
let logPath = base + "/blankscreen.log"
let commandFile = base + "/command"        // CLI -> App 的指令(off/on/toggle)，比信号可靠

// 防睡眠 Level 2（覆盖电池与合盖）所需。caffeinate -s 按 man page 明写「仅 AC 有效」，
// 所以电池与合盖只能靠 pmset disablesleep，而它需要 root。
let helperPath = "/Library/PrivilegedHelperTools/com.blankscreen.pmset"
let sudoersPath = "/etc/sudoers.d/blankscreen"
// 关屏被拒绝（电量过低 / 亮度接口不可用）时的回传：CLI off 读完即清
let rejectFile = base + "/reject"
let barPlist = home + "/Library/LaunchAgents/com.blankscreen.bar.plist"
// 合盖模式托管的 CLI 守护进程的 pid 文件（与 CLI 命名一致）
let nosleepPidFile = base + "/nosleep.pid"
/// CLI 二进制路径：合盖模式以独立的 CLI 守护进程持有 disablesleep，
/// 从而在持有者账本里与黑屏联动（App 自身 pid）互不干扰。
let cliCandidates = ["/opt/homebrew/bin/blankscreen", "/usr/local/bin/blankscreen"]
let cliPath: String = cliCandidates.first(where: { fm.isExecutableFile(atPath: $0) }) ?? cliCandidates[0]

/// 以 launchd 实际注册状态为准：plist 文件存在但没 bootstrap 时，开机并不会启动
func isLoginItemEnabled() -> Bool {
    let t = Process()
    t.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    t.arguments = ["print", "gui/\(getuid())/\(barLabel)"]
    t.standardOutput = FileHandle.nullDevice
    t.standardError = FileHandle.nullDevice
    t.standardInput = FileHandle.nullDevice
    do { try t.run() } catch { return false }
    t.waitUntilExit()
    return t.terminationStatus == 0
}
let barLabel = "com.blankscreen.bar"

/// 登录项 plist。KeepAlive 用 SuccessfulExit=false：只有崩溃 / 被强杀才重启，
/// 正常退出（菜单「退出」、SIGTERM）不再拉起。
/// 原因：无条件 KeepAlive 会与 App 内部的单实例接管互相残杀 —— launchd 不停
/// 拉起新实例，新实例又杀掉旧实例，进程陷入重启竞赛，热键注册随进程不断消亡。
func loginItemPlist() -> String {
    let bundle = Bundle.main.bundlePath
    let exe = bundle.hasSuffix(".app")
        ? bundle + "/Contents/MacOS/BlankScreenBar"
        : "/Applications/BlankScreenBar.app/Contents/MacOS/BlankScreenBar"
    return """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key><string>\(barLabel)</string>
        <key>ProgramArguments</key><array><string>\(exe)</string></array>
        <key>RunAtLoad</key><true/>
        <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    </dict>
    </plist>
    """
}
try? fm.createDirectory(atPath: base, withIntermediateDirectories: true)

func blog(_ s: String) {
    if let a = try? fm.attributesOfItem(atPath: logPath),
       let size = a[.size] as? UInt64, size > 262_144 {
        try? fm.removeItem(atPath: logPath + ".old")
        try? fm.moveItem(atPath: logPath, toPath: logPath + ".old")
    }
    let line = "\(Date()) \(s)\n"
    if let h = FileHandle(forWritingAtPath: logPath) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
    else { fm.createFile(atPath: logPath, contents: line.data(using: .utf8)) }
}

// MARK: - 配置（字段可缺省，保证旧版 config.json 仍能读取）
struct Config: Codable {
    var keyCode: Int64 = 11                  // B
    var modFlags: UInt64 = MOD_CTRL | MOD_ALT | MOD_CMD   // 默认 ⌃⌥⌘
    var timeout: Double = 43200              // 黑屏后自动恢复兜底，秒；0 = 不启用
    var restoreFixed: Float? = nil           // nil = 恢复进入黑屏前的亮度
    var batteryFloor: Int = 20               // 电量下限 %，0 = 不限制
    var autoNosleep: Bool = false            // 关屏时同时防睡眠（默认关：合盖不睡有耗电风险）
    var lidAwake: Bool = false
    var lang: String = "auto"                             // 界面语言：auto=跟随系统 / zh / en               // 合盖不睡眠长期模式（菜单一键开关，重启自动恢复）

    enum CodingKeys: String, CodingKey { case keyCode, modFlags, timeout, restoreFixed, batteryFloor, autoNosleep, lidAwake, lang }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try c.decodeIfPresent(Int64.self, forKey: .keyCode) ?? 11
        modFlags = try c.decodeIfPresent(UInt64.self, forKey: .modFlags) ?? (MOD_CTRL | MOD_ALT | MOD_CMD)
        timeout = try c.decodeIfPresent(Double.self, forKey: .timeout) ?? 43200
        restoreFixed = try c.decodeIfPresent(Float.self, forKey: .restoreFixed)
        batteryFloor = try c.decodeIfPresent(Int.self, forKey: .batteryFloor) ?? 20
        autoNosleep = try c.decodeIfPresent(Bool.self, forKey: .autoNosleep) ?? false
        lidAwake = try c.decodeIfPresent(Bool.self, forKey: .lidAwake) ?? false
        lang = try c.decodeIfPresent(String.self, forKey: .lang) ?? "auto"
    }
}
let MOD_CTRL: UInt64  = 1 << 18
let MOD_ALT: UInt64   = 1 << 19
let MOD_CMD: UInt64   = 1 << 20
let MOD_SHIFT: UInt64 = 1 << 17

func loadConfig() -> Config {
    if let d = try? Data(contentsOf: URL(fileURLWithPath: configFile)),
       let c = try? JSONDecoder().decode(Config.self, from: d) { return c }
    return Config()
}
func saveConfig(_ c: Config) {
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let d = try? enc.encode(c) { try? d.write(to: URL(fileURLWithPath: configFile)) }
}

// MARK: - 键位表
let keyItems: [(String, Int64)] = [
    ("A", 0), ("B", 11), ("C", 8), ("D", 2), ("E", 14), ("F", 3), ("G", 5), ("H", 4),
    ("I", 34), ("J", 38), ("K", 40), ("L", 37), ("M", 46), ("N", 45), ("O", 31), ("P", 35),
    ("Q", 12), ("R", 15), ("S", 1), ("T", 17), ("U", 32), ("V", 9), ("W", 13), ("X", 7),
    ("Y", 16), ("Z", 6),
    ("F1", 122), ("F2", 120), ("F3", 99), ("F4", 118), ("F5", 96), ("F6", 97),
    ("F7", 98), ("F8", 100), ("F9", 101), ("F10", 109), ("F11", 103), ("F12", 111),
    ("F13", 105), ("F14", 107), ("F15", 113), ("F16", 106), ("F17", 64), ("F18", 79),
    ("F19", 80), ("F20", 90),
    (L("Space 空格"), 49), ("Esc", 53), (L("Return 回车"), 36), ("Tab", 48)
]
func keyName(_ code: Int64) -> String { keyItems.first { $0.1 == code }?.0 ?? "keyCode \(code)" }
func modText(_ flags: UInt64) -> String {
    var s = ""
    if flags & MOD_CTRL  != 0 { s += "⌃" }
    if flags & MOD_ALT   != 0 { s += "⌥" }
    if flags & MOD_SHIFT != 0 { s += "⇧" }
    if flags & MOD_CMD   != 0 { s += "⌘" }
    return s.isEmpty ? L("（无修饰键）") : s
}
func hotkeyText(_ c: Config) -> String { modText(c.modFlags) + keyName(c.keyCode) }

// MARK: - 全局热键：Carbon Event Manager
// 说明（important）：本程序此前用 CGEventTap 监听全局按键，那条链路强制要求
// 「输入监控 / 辅助功能」授权；而本 App 是 ad-hoc 签名（无 Team ID），每次重新
// 编译二进制 cdhash 都会变化，TCC 授权随之失效，导致用户反复勾选仍无效。
// Carbon RegisterEventHotKey 由 WindowServer 直接派发，不需要任何 TCC 权限，
// 因此作为热键主路径。
var carbonHotKeyRef: EventHotKeyRef?
var carbonHandlerRef: EventHandlerRef?
var carbonFire: (() -> Void)?        // 触发开关显示
var carbonProbe: (() -> Void)?       // 自检旁路，只记录不执行动作
let hotKeySignature: OSType = 0x424C4E4B        // 'BLNK'

/// NSEvent 修饰键位 -> Carbon 修饰键位
func carbonModifiers(_ flags: UInt64) -> UInt32 {
    var m: UInt32 = 0
    if flags & MOD_CMD   != 0 { m |= UInt32(cmdKey) }
    if flags & MOD_SHIFT != 0 { m |= UInt32(shiftKey) }
    if flags & MOD_ALT   != 0 { m |= UInt32(optionKey) }
    if flags & MOD_CTRL  != 0 { m |= UInt32(controlKey) }
    return m
}

@discardableResult
func registerCarbonHotKey(keyCode: Int64, modFlags: UInt64) -> OSStatus {
    if carbonHandlerRef == nil {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let st = InstallEventHandler(GetEventDispatcherTarget(),
            { _, _, _ -> OSStatus in
                // Carbon 回调在事件线程，切回主线程执行 UI / 亮度操作
                DispatchQueue.main.async { carbonProbe?(); carbonFire?() }
                return noErr
            }, 1, &spec, nil, &carbonHandlerRef)
        guard st == noErr else { return st }
    }
    if let old = carbonHotKeyRef { UnregisterEventHotKey(old); carbonHotKeyRef = nil }
    let hid = EventHotKeyID(signature: hotKeySignature, id: 1)
    let st = RegisterEventHotKey(UInt32(keyCode), carbonModifiers(modFlags), hid,
                                 GetEventDispatcherTarget(), 0, &carbonHotKeyRef)
    if st != noErr { carbonHotKeyRef = nil }
    return st
}
func carbonStatusText(_ st: OSStatus) -> String {
    switch st {
    case noErr:                   return L("已注册")
    case OSStatus(eventHotKeyExistsErr):      return L("已被系统或其他 App 占用，请换一个组合")
    case OSStatus(eventHotKeyInvalidErr):     return L("组合无效（全局热键需要至少一个修饰键）")
    default:                      return (L("注册失败（OSStatus ") + "\(st)" + L("）"))
    }
}

// MARK: - 亮度读写（DisplayServices 私有框架）
let dsHandle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
typealias DSGet = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
typealias DSSet = @convention(c) (UInt32, Float) -> Int32

var dsAvailable: Bool {
    guard let h = dsHandle else { return false }
    return dlsym(h, "DisplayServicesGetBrightness") != nil
        && dlsym(h, "DisplayServicesSetBrightness") != nil
}

/// 所有在线显示器。只操作 CGMainDisplayID() 会漏掉外接屏——用户要的是「关屏」，即全部。
func onlineDisplays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [CGMainDisplayID()] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(count, &ids, &count)
    return ids.prefix(Int(count)).isEmpty ? [CGMainDisplayID()] : Array(ids.prefix(Int(count)))
}

/// 上一次设置亮度时失败的显示器（多数 HDMI/DVI/DP 外接屏不支持软件亮度）。
/// 这类屏关不掉，必须让用户看见，而不是让他以为一切正常。
var lastFailedDisplays: [CGDirectDisplayID] = []

func setOneBrightness(_ id: CGDirectDisplayID, _ v: Float) -> Bool {
    guard let h = dsHandle, let p = dlsym(h, "DisplayServicesSetBrightness") else { return false }
    return unsafeBitCast(p, to: DSSet.self)(id, v) == 0
}

func readBrightness() -> Float {
    guard let h = dsHandle, let p = dlsym(h, "DisplayServicesGetBrightness") else { return -1 }
    let f = unsafeBitCast(p, to: DSGet.self)
    var v: Float = -1
    return f(CGMainDisplayID(), &v) == 0 ? v : -1
}
// 返回 false = 设置失败（实测成功时返回 0）。失败必须可见，否则用户会以为关屏成功、
// 实际屏幕还亮着。遍历所有在线显示器：只关主屏会让外接屏继续亮着，等于没关。
@discardableResult
func setBrightness(_ v: Float) -> Bool {
    var ok = false
    var failed: [CGDirectDisplayID] = []
    for id in onlineDisplays() {
        if setOneBrightness(id, v) { ok = true } else { failed.append(id) }
    }
    lastFailedDisplays = failed
    return ok
}
/// 恢复必须尽最大努力成功：失败意味着用户永远看不见屏幕，因此多次重试而非「设一次就走」
@discardableResult
func restoreBrightness(_ v: Float) -> Bool {
    for i in 0..<6 {
        var ok = false
        for id in onlineDisplays() { if setOneBrightness(id, v) { ok = true } }
        if ok { return true }
        usleep(UInt32(150_000 * (i + 1)))
    }
    return false
}

// MARK: - 电池状态（pmset -g batt，免授权；与 CLI 同一判定口径）
// 仅「电池供电且正在放电」视为耗尽风险：插电时电量再低也不会耗尽。
struct Battery { var onBattery = false, discharging = false, percent = 100 }

func batteryStatus() -> Battery {
    var b = Battery()
    // 测试钩子：BS_SIMULATE_BATTERY="电量,batt|ac,discharging|charging"（见 CLI 同名实现）
    if let sim = ProcessInfo.processInfo.environment["BS_SIMULATE_BATTERY"] {
        let parts = sim.lowercased().split(separator: ",").map(String.init)
        if let p = parts.first, let v = Int(p), (0...100).contains(v) {
            b.percent = v
            b.onBattery = parts.contains("batt")
            b.discharging = parts.contains("discharging")
            return b
        }
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    p.arguments = ["-g", "batt"]
    p.standardInput = FileHandle.nullDevice
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
    do { try p.run() } catch { return b }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard let out = String(data: data, encoding: .utf8), !out.isEmpty else { return b }
    b.onBattery = out.contains("Battery Power")
    b.discharging = out.range(of: "discharging", options: .caseInsensitive) != nil
    for tok in out.split(whereSeparator: { " \t\n;".contains($0) }) {
        if tok.hasSuffix("%"), let v = Int(tok.dropLast()) { b.percent = v; break }
    }
    return b
}

func notifyUser(_ msg: String) {
    let safe = msg.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "display notification \"\(safe)\" with title \"BlankScreen\""]
    try? p.run()
}

var gotTerminate = false
// SIGTERM/SIGINT 由传统 handler 置位，再由 Timer 在主线程安全收尾

// MARK: - 屏幕控制器（与 CLI 常驻服务同一套语义）
final class ScreenController {
    static let shared = ScreenController()

    var cfg = loadConfig()
    var blacked = false
    var saved: Float = 0.5
    var caff: Process?
    // 一律用 AppKit 原生 Timer：AppKit run loop 对 GCD main queue 的 timer / signal
    // source 交付不可靠（实测延迟数秒且乱序），NSTimer 挂 .common 模式则稳定
    var pinTimer: Timer?
    var timeoutTimer: Timer?
    var battTimer: Timer?
    var cmdTimer: Timer?
    var signalSources: [DispatchSourceSignal] = []
    var configMtime: Date? = nil
    var selfTesting = false
    var onStateChange: (() -> Void)?
    var restoreRetry: Timer?      // 亮度恢复失败后的持续重试（屏幕不能就此黑着）

    // MARK: 防睡眠
    //
    // 与关屏是两件事：关屏只让背光熄灭，防睡眠是阻止系统进入睡眠。
    // caffeinate -s 的断言仅 AC 有效（man page 明写），所以电池与合盖场景
    // 必须靠 pmset disablesleep（需 root、默认不安装）。
    var nosleepCaff: Process?
    var nosleepSystemOn = false
    var nosleepOn = false
    var nosleepAuto = false            // 由「关屏联动」开启时为 true，恢复显示时随之关闭

    // MARK: 合盖不睡眠（长期模式）
    //
    // 委托一个独立的 CLI 系统级守护（nosleep-daemon --system）持有 disablesleep：
    // 独立 pid = 持有者账本里的独立条目，与黑屏联动的 App 侧防睡眠互不干扰；
    // App 退出 / 重启都不影响它，重启电脑后由本函数按持久标志自动恢复。
    func lidDaemonPid() -> Int32? {
        guard let s = try? String(contentsOfFile: nosleepPidFile, encoding: .utf8),
              let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)),
              kill(pid, 0) == 0 else { return nil }
        return pid
    }

    /// 守护写入的状态行：level|since|systemOn。用于确认合盖守护真的到达系统级。
    func nosleepInfoStatus() -> (level: String, systemOn: Bool)? {
        guard lidDaemonPid() != nil,
              let s = try? String(contentsOfFile: base + "/nosleep.state", encoding: .utf8) else { return nil }
        let p = s.split(separator: "|").map(String.init)
        return (level: p.count > 0 ? p[0] : "caffeinate",
                systemOn: p.count > 2 ? p[2] == "1" : false)
    }

    var lidOn: Bool { cfg.lidAwake && lidDaemonPid() != nil }

    @discardableResult
    func setLidAwake(_ on: Bool) -> Bool {
        var c = loadConfig()
        guard let cli = fm.isExecutableFile(atPath: cliPath) ? cliPath : nil else {
            blog("bar: 合盖模式需要命令行工具")
            return false
        }
        if on {
            guard helperInstalled() else {
                blog("bar: 合盖模式需要提权助手（覆盖合盖睡眠必须 root）")
                return false
            }
            if c.batteryFloor > 0 {
                let b = batteryStatus()
                if b.onBattery && b.discharging && b.percent <= c.batteryFloor {
                    blog("bar: 电量 \(b.percent)% 低于下限，暂不能开启合盖模式")
                    return false
                }
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: cli)
            p.arguments = ["nosleep", "on", "--system"]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            do { try p.run(); p.waitUntilExit() } catch { blog("bar: 启动合盖守护失败 \(error)"); return false }
            guard lidDaemonPid() != nil else {
                blog("bar: 合盖守护启动未确认，详见 CLI 日志")
                return false
            }
            // 必须确认到达系统级：降级成进程级时合盖照样睡，用户会带着错误预期合盖
            if let info = nosleepInfoStatus(), info.level != "system" {
                blog("bar: 合盖守护降级为进程级（helper 调用失败），回滚")
                let q = Process()
                q.executableURL = URL(fileURLWithPath: cli)
                q.arguments = ["nosleep", "off"]
                q.standardOutput = FileHandle.nullDevice; q.standardError = FileHandle.nullDevice
                q.standardInput = FileHandle.nullDevice
                try? q.run(); q.waitUntilExit()
                return false
            }
            c.lidAwake = true
            blog("bar: 合盖不睡眠已开启 pid=\(lidDaemonPid() ?? 0)")
        } else {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: cli)
            p.arguments = ["nosleep", "off"]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            do { try p.run(); p.waitUntilExit() } catch { blog("bar: 停止合盖守护失败 \(error)") }
            c.lidAwake = false
            blog("bar: 合盖不睡眠已关闭")
        }
        saveConfig(c)
        cfg = c
        onStateChange?()
        return true
    }

    func helperInstalled() -> Bool {
        // sudoers 只判存在、不能读内容：0440 root:wheel 对普通用户不可读，读会误判未安装
        fm.isExecutableFile(atPath: helperPath) && fm.fileExists(atPath: sudoersPath)
    }

    private func helperExec(_ arg: String) -> String? {
        guard ["on", "off", "status", "detect"].contains(arg), helperInstalled() else { return nil }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", helperPath, arg]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = nil
        do { try p.run() } catch { return nil }
        // 必须先读再等：管道缓冲区写满会让子进程卡死在 write 上
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func systemSleepDisabled() -> Bool {
        guard let s = helperExec("status"), let v = Int(s) else { return false }
        return v == 1
    }

    /// 提权助手版本是否过旧：带「持有者记账」的版本 detect 会输出 owners= 字段。
    /// 旧版没有记账——关屏联动与手动防睡眠会互相踩掉对方的 disablesleep，需要重装助手。
    func helperOutdated() -> Bool {
        guard helperInstalled(), let d = helperExec("detect") else { return false }
        return !d.contains("owners=")
    }

    var nosleepLevelText: String {
        guard nosleepOn else { return L("未开启") }
        return nosleepSystemOn ? L("系统级（含电池与合盖）") : L("进程级（仅电源适配器）")
    }

    /// 黑屏期间持有 caffeinate，阻止空闲/显示器睡眠（-w 保证退出即回收）
    private func startCaff() {
        guard caff == nil else { return }
        let c = Process()
        c.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        c.arguments = ["-di", "-w", String(ProcessInfo.processInfo.processIdentifier)]
        try? c.run()
        caff = c
    }

    @discardableResult
    func startNosleep(auto: Bool = false) -> Bool {
        guard !nosleepOn else { return true }
        // 电量下限对防睡眠同样强制生效：合盖 + 电池 + 不睡是最容易耗尽电量的组合，
        // 机器在包里一直跑到没电，用户却毫不知情。
        if cfg.batteryFloor > 0 {
            let b = batteryStatus()
            if b.onBattery && b.discharging && b.percent <= cfg.batteryFloor {
                return reject((L("电量 ") + "\(b.percent)" + L("% 低于下限 ") + "\(cfg.batteryFloor)" + L("%，已取消开启防睡眠（避免耗尽电池）")))
            }
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let c = Process()
        c.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        c.arguments = ["-dis", "-w", String(pid)]
        try? c.run()
        nosleepCaff = c
        nosleepOn = true
        // -dis 已覆盖 -d -i，不必再单独持有黑屏用的 caffeinate
        caff?.terminate(); caff = nil

        if helperInstalled(), let r = helperExec("on"), r == "on", systemSleepDisabled() {
            nosleepSystemOn = true
            blog("bar: 防睡眠开启（系统级，覆盖电池与合盖）")
        } else {
            nosleepSystemOn = false
            blog("bar: 防睡眠开启（进程级，仅电源适配器时有效）")
        }
        nosleepAuto = auto
        scheduleBatteryGuard()
        onStateChange?()
        return true
    }

    /// 系统级开关是持久的，停止时必须显式复位，否则系统再也不会睡眠
    func stopNosleep(_ reason: String = L("手动关闭")) {
        guard nosleepOn else { return }
        if nosleepSystemOn { _ = helperExec("off"); nosleepSystemOn = false }
        nosleepCaff?.terminate(); nosleepCaff = nil
        nosleepOn = false
        nosleepAuto = false
        if blacked { startCaff() }      // 仍在黑屏则恢复黑屏所需的断言
        blog("bar: 防睡眠停止（\(reason)）")
        onStateChange?()
    }

    // MARK: 状态
    var isBlacked: Bool { fm.fileExists(atPath: stateFile) }

    /// 记录、通知并回传拒绝原因（CLI 从 rejectFile 读到后会给用户明确提示）
    private func reject(_ m: String) -> Bool {
        blog("bar: \(m)")
        notifyUser(m)
        try? m.write(toFile: rejectFile, atomically: true, encoding: .utf8)
        onStateChange?()
        return false
    }

    /// 返回 false = 没能进入黑屏（亮度接口不可用或电量过低）
    @discardableResult
    func blackout() -> Bool {
        guard !blacked else { return true }
        restoreRetry?.invalidate(); restoreRetry = nil
        guard dsAvailable else {
            return reject(L("亮度接口不可用（DisplayServices 缺失），无法关屏"))
        }
        // 电量下限：黑屏 + 阻止睡眠的组合让人最容易忘记，耗尽电池会带走未保存的工作
        if cfg.batteryFloor > 0 {
            let b = batteryStatus()
            if b.onBattery && b.discharging && b.percent <= cfg.batteryFloor {
                return reject((L("电量 ") + "\(b.percent)" + L("% 低于下限 ") + "\(cfg.batteryFloor)" + L("%，已取消关屏（避免耗尽电池）")))
            }
        }
        try? fm.removeItem(atPath: rejectFile)
        let cur = max(readBrightness(), 0)
        saved = cur > 0.001 ? cur : saved
        try? String(saved).write(toFile: stateFile, atomically: true, encoding: .utf8)
        blacked = true
        if !setBrightness(0.0) { blog("bar: 警告：首次设置亮度 0 失败") }
        startCaff()
        let t = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            if self?.blacked == true { setBrightness(0.0) }
        }
        RunLoop.main.add(t, forMode: .common)
        pinTimer = t
        scheduleTimeout()
        scheduleBatteryGuard()
        // 关屏与防睡眠联动：这是「屏幕黑着但机器保持可远程」的完整场景
        if cfg.autoNosleep { startNosleep(auto: true) }
        blog("bar: 进入黑屏，原亮度 \(saved)，电量下限 \(cfg.batteryFloor > 0 ? "\(cfg.batteryFloor)%" : "不限")")
        onStateChange?()
        return true
    }

    // 黑屏期间每 30s 复查电量，跌破下限立即恢复；这是硬保护，
    // 即使用户想保持黑屏也不放行——耗尽电池的代价比「被打断」大得多
    /// 电量守卫同时覆盖黑屏与防睡眠：合盖 + 电池 + 不睡眠是最容易耗尽电量的组合，
    /// 机器在包里持续发热直到没电，用户却毫不知情。
    func scheduleBatteryGuard() {
        battTimer?.invalidate(); battTimer = nil
        guard cfg.batteryFloor > 0 else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self = self, self.blacked || self.nosleepOn else { return }
            let b = batteryStatus()
            guard b.onBattery && b.discharging, b.percent <= self.cfg.batteryFloor else { return }
            let m = (L("电量 ") + "\(b.percent)" + L("% 已达下限 ") + "\(self.cfg.batteryFloor)" + L("%，自动恢复"))
            blog("bar: \(m)")
            notifyUser(m)
            self.stopNosleep((L("电量已达下限 ") + "\(self.cfg.batteryFloor)" + "%"))
            if self.blacked { self.restore() }
        }
        RunLoop.main.add(t, forMode: .common)
        battTimer = t
    }

    func restore() {
        guard blacked else { return }
        blacked = false
        pinTimer?.invalidate(); pinTimer = nil
        timeoutTimer?.invalidate(); timeoutTimer = nil
        battTimer?.invalidate(); battTimer = nil
        // 联动开启的防睡眠随黑屏一起结束；用户手动开启的保持不动
        if nosleepAuto { stopNosleep(L("已恢复显示")) }
        let target = cfg.restoreFixed ?? saved
        blog("bar: 恢复显示 \(target)")
        // 恢复失败不能就此罢休：屏幕会一直黑着。持续重试直到真的亮回来。
        if !restoreBrightness(target) {
            blog("bar: 错误：亮度恢复失败，转入持续重试")
            notifyUser(L("亮度恢复失败，正在持续重试"))
            restoreRetry?.invalidate()
            let rt = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] t in
                guard let self = self else { t.invalidate(); return }
                if restoreBrightness(target) {
                    blog("bar: 重试成功，亮度已恢复 \(target)")
                    t.invalidate(); self.restoreRetry = nil
                }
            }
            RunLoop.main.add(rt, forMode: .common)
            restoreRetry = rt
        }
        caff?.terminate(); caff = nil
        try? fm.removeItem(atPath: stateFile)
        onStateChange?()
    }

    func toggle() { if blacked { restore() } else { _ = blackout() } }

    func scheduleTimeout() {
        timeoutTimer?.invalidate(); timeoutTimer = nil
        guard cfg.timeout > 0 else { return }
        let t = Timer.scheduledTimer(withTimeInterval: cfg.timeout, repeats: false) { [weak self] _ in
            blog("bar: 兜底超时，自动恢复")
            self?.restore()
        }
        RunLoop.main.add(t, forMode: .common)
        timeoutTimer = t
    }

    // MARK: 热键
    var hotkeyReady = false                  // Carbon 全局热键是否已注册成功
    var lastHotkeyStatus: OSStatus = noErr
    private var lastLoggedStatus: OSStatus = noErr

    func installHotkey() {
        carbonFire = { [weak self] in
            guard self?.selfTesting != true else { return }
            self?.toggle()
        }
        let st = registerCarbonHotKey(keyCode: cfg.keyCode, modFlags: cfg.modFlags)
        hotkeyReady = (st == noErr)
        lastHotkeyStatus = st
        if hotkeyReady {
            lastLoggedStatus = noErr
            blog("bar: 全局热键已注册 \(hotkeyText(cfg))（Carbon 链路，无需授权）")
        } else if st != lastLoggedStatus {
            lastLoggedStatus = st
            blog("bar: 全局热键注册失败 \(hotkeyText(cfg)) —— \(carbonStatusText(st))")
        }
    }

    func reloadHotkey() { installHotkey() }

    // MARK: 自检：验证真实按键能否送达本程序
    /// 先合成一次组合键自动验证（App 自身有事件循环，合成事件能走完真实链路），
    /// 通过则无需用户手动按键
    func selfTest(completion: @escaping (Bool) -> Void) {
        guard hotkeyReady else { completion(false); return }
        var got = false
        selfTesting = true                 // 自检期间只记录，不真的开关屏幕
        carbonProbe = { got = true }
        postSyntheticHotkey()
        let deadline = Date().addingTimeInterval(2.5)
        let t = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            if got || Date() > deadline {
                timer.invalidate()
                self.selfTesting = false
                carbonProbe = nil
                blog("bar: 热键自检 \(got ? "通过" : "未收到按键") \(hotkeyText(self.cfg))")
                completion(got)
            }
        }
        RunLoop.main.add(t, forMode: .common)
    }

    /// 合成一次配置中的组合键（自动化自检用）
    private func postSyntheticHotkey() {
        let src = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(cfg.keyCode), keyDown: true),
              let up   = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(cfg.keyCode), keyDown: false)
        else { return }
        var f = CGEventFlags()
        if cfg.modFlags & MOD_CMD   != 0 { f.insert(.maskCommand) }
        if cfg.modFlags & MOD_SHIFT != 0 { f.insert(.maskShift) }
        if cfg.modFlags & MOD_ALT   != 0 { f.insert(.maskAlternate) }
        if cfg.modFlags & MOD_CTRL  != 0 { f.insert(.maskControl) }
        down.flags = f
        up.flags = f
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // MARK: 生命周期
    func start() {
        takeoverServiceSlot()
        killSiblingInstances()   // 用 NSRunningApplication 枚举，不依赖 ps
        // 自愈：上次异常退出遗留的黑屏状态
        if let s = try? String(contentsOfFile: stateFile, encoding: .utf8),
           let v = Float(s.trimmingCharacters(in: .whitespacesAndNewlines)), v > 0.001 {
            blog("bar: 发现遗留黑屏状态，自愈恢复到 \(v)")
            restoreBrightness(v)
        }
        try? fm.removeItem(atPath: stateFile)
        try? String(ProcessInfo.processInfo.processIdentifier).write(toFile: serviceFile, atomically: true, encoding: .utf8)
        try? fm.removeItem(atPath: commandFile)
        installHotkey()

        // 合盖模式是持久标志：App 重启 / 电脑重启后自动恢复守护；
        // 助手缺失（如被手动卸载）则停用标志并明确告知，不留「以为开着其实没开」的状态
        if loadConfig().lidAwake {
            if helperInstalled() {
                if lidDaemonPid() == nil { _ = setLidAwake(true) }
            } else {
                var c = loadConfig(); c.lidAwake = false; saveConfig(c); cfg = c
                notifyUser(L("「合盖后不睡眠」已停用：提权助手未安装（可能已被卸载）"))
            }
        }

        // 指令走命令文件：SIGUSR1/USR2 必须显式忽略（默认行为是终止进程），
        // 真正的开关动作由下方 Timer 轮询 command 文件完成
        for sig in [SIGUSR1, SIGUSR2, SIGHUP] { signal(sig, SIG_IGN) }
        signal(SIGTERM) { _ in gotTerminate = true }
        signal(SIGINT)  { _ in gotTerminate = true }

        let ct = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.pumpCommand()
        }
        RunLoop.main.add(ct, forMode: .common)
        cmdTimer = ct
        blog("bar: 服务已启动 pid=\(ProcessInfo.processInfo.processIdentifier)")
    }

    /// 若已有 CLI 的 daemon --service 占用 service.pid，先停掉，避免两个进程抢同一状态
    /// 终止同 bundle 的其他实例（比 takeoverServiceSlot 更彻底，不依赖 ps 与 pid 文件）
    /// 查找指定 pid 的 caffeinate 子进程（强杀旧实例前记录，事后清理）
    private func childCaffeinatePids(of parent: Int32) -> [Int32] {
        let t = Process()
        t.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        t.arguments = ["-P", String(parent), "caffeinate"]
        let pipe = Pipe(); t.standardOutput = pipe; t.standardError = FileHandle.nullDevice
        do { try t.run() } catch { return [] }
        t.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    private func killSiblingInstances() {
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "com.blankscreen.bar")
            .filter { $0.processIdentifier != me }
        for app in others {
            let oldPid = app.processIdentifier
            blog("bar: 终止同 bundle 旧实例 pid=\(oldPid)")
            // 先记下旧实例的 caffeinate 子进程：SIGKILL 无法触发其清理逻辑
            let kids = childCaffeinatePids(of: oldPid)
            app.terminate()
            usleep(500_000)
            if app.isTerminated == false {
                blog("bar: 旧实例未响应，强制终止 pid=\(oldPid)")
                app.forceTerminate()
            }
            for k in kids where kill(k, 0) == 0 {
                blog("bar: 清理旧实例遗留的 caffeinate pid=\(k)")
                kill(k, SIGTERM)
            }
        }
    }

    private func takeoverServiceSlot() {
        guard let s = try? String(contentsOfFile: serviceFile, encoding: .utf8),
              let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid != ProcessInfo.processInfo.processIdentifier, kill(pid, 0) == 0 else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-o", "command=", "-p", String(pid)]
        let pipe = Pipe(); task.standardOutput = pipe
        try? task.run(); task.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if out.contains("blankscreen") || out.contains("BlankScreenBar") {
            // 旧实例可能是 CLI daemon，也可能是上一个 BlankScreenBar 实例——都应接管（单实例语义）
            let which = out.contains("BlankScreenBar") ? L("上一个 BlankScreenBar 实例") : "blankscreen daemon"
            blog("bar: 接管 service.pid，终止旧 \(which) pid=\(pid)")
            kill(pid, SIGTERM)
            usleep(800_000)
            if kill(pid, 0) == 0 { kill(pid, SIGKILL); usleep(200_000) }   // 顽固时升级
        }
    }

    /// config.json 被改动（包括用 CLI 修改）时自动重载，无需重启
    private func reloadConfigIfChanged() {
        guard let a = try? fm.attributesOfItem(atPath: configFile),
              let m = a[.modificationDate] as? Date else { return }
        if let old = configMtime, m > old {
            let newCfg = loadConfig()
            let keyChanged = newCfg.keyCode != cfg.keyCode || newCfg.modFlags != cfg.modFlags
            cfg = newCfg
            if keyChanged { installHotkey() }
            if blacked { scheduleTimeout(); scheduleBatteryGuard() }
            blog("bar: 配置已自动重载 \(hotkeyText(cfg))")
        }
        configMtime = m
    }

    private func pumpCommand() {
        if gotTerminate { shutdown(); return }
        reloadConfigIfChanged()
        guard let s = try? String(contentsOfFile: commandFile, encoding: .utf8) else { return }
        try? fm.removeItem(atPath: commandFile)
        switch s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "off", "black":   blog("bar: 收到指令 off"); blackout()
        case "on", "restore":  blog("bar: 收到指令 on"); restore()
        case "toggle":         blog("bar: 收到指令 toggle"); toggle()
        default: break
        }
    }

    func shutdown() {
        restore()
        // 系统级开关是持久的：退出前必须复位，否则退出后系统再也不会睡眠
        stopNosleep(L("程序退出"))
        try? fm.removeItem(atPath: serviceFile)
        blog("bar: 退出")
        exit(0)
    }
}

// MARK: - 设置面板
final class SettingsPanel: NSObject, NSWindowDelegate {
    private var window: NSWindow!
    private let ctl = ScreenController.shared
    private var cfg = loadConfig()          // 面板内的编辑副本，保存时才写回生效

    private var modBtns: [UInt64: NSButton] = [:]
    private var keyPop: NSPopUpButton!
    private var hkLabel: NSTextField!
    private var timeoutPop: NSPopUpButton!
    private var batteryPop: NSPopUpButton!
    private var restorePop: NSPopUpButton!
    private var nosleepBtn: NSButton!
    private var lidBtn: NSButton!
    private var helperLabel: NSTextField!
    private var helperBtn: NSButton!
    private var restoreSlider: NSSlider!
    private var restoreValueLabel: NSTextField!
    private var loginBtn: NSButton!
    private var permLabel: NSTextField!
    private var checkBtn: NSButton!

    private let timeoutChoices: [(String, Double)] = [
        (L("不启用（一直保持黑屏）"), 0),
        (L("30 分钟"), 1800), (L("1 小时"), 3600), (L("2 小时"), 7200),
        (L("4 小时"), 14400), (L("8 小时"), 28800), (L("12 小时"), 43200)
    ]
    private let batteryChoices: [(String, Int)] = [
        (L("不限制"), 0), ("50%", 50), ("30%", 30),
        (L("20%（推荐）"), 20), ("15%", 15), ("10%", 10)
    ]

    func show() {
        if window == nil { window = build() }
        syncFromConfig()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 730),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = L("BlankScreen 设置")
        w.delegate = self
        w.isReleasedWhenClosed = false
        w.center()

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        w.contentView = root
        root.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: w.contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: w.contentView!.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: w.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: w.contentView!.trailingAnchor)
        ])

        // —— 热键
        root.addArrangedSubview(section(L("恢复热键")))
        let modRow = NSStackView(); modRow.orientation = .horizontal; modRow.spacing = 10
        for (title, flag) in [("⌃ Control", MOD_CTRL), ("⌥ Option", MOD_ALT),
                              ("⌘ Command", MOD_CMD), ("⇧ Shift", MOD_SHIFT)] {
            let b = NSButton(checkboxWithTitle: title, target: self, action: #selector(onHotkeyChanged(_:)))
            modBtns[flag] = b
            modRow.addArrangedSubview(b)
        }
        root.addArrangedSubview(modRow)

        keyPop = NSPopUpButton(frame: .zero, pullsDown: false)
        keyPop.addItems(withTitles: keyItems.map { "\($0.0)" })
        keyPop.target = self; keyPop.action = #selector(onHotkeyChanged(_:))
        root.addArrangedSubview(row(L("按键"), keyPop))

        hkLabel = NSTextField(labelWithString: "")
        hkLabel.font = .systemFont(ofSize: 12)
        hkLabel.textColor = .secondaryLabelColor
        root.addArrangedSubview(hkLabel)

        // —— 兜底超时
        root.addArrangedSubview(section(L("自动恢复兜底")))
        timeoutPop = NSPopUpButton(frame: .zero, pullsDown: false)
        timeoutPop.addItems(withTitles: timeoutChoices.map { $0.0 })
        timeoutPop.target = self; timeoutPop.action = #selector(onTimeoutChanged(_:))
        root.addArrangedSubview(row(L("黑屏后"), timeoutPop))
        let tip = wrapLabel(L("热键失效时的安全网。设为「不启用」则一直保持黑屏，直到手动恢复或退出本程序。"))
        root.addArrangedSubview(tip)

        // —— 电量下限
        root.addArrangedSubview(section(L("电量保护")))
        batteryPop = NSPopUpButton(frame: .zero, pullsDown: false)
        batteryPop.addItems(withTitles: batteryChoices.map { $0.0 })
        batteryPop.target = self; batteryPop.action = #selector(onBatteryChanged(_:))
        root.addArrangedSubview(row(L("低于"), batteryPop))
        let battTip = wrapLabel(L("仅在使用电池且正在放电时生效：低于下限会拒绝关屏；黑屏期间跌破下限则自动恢复并通知。插着电源时不干预。"))
        root.addArrangedSubview(battTip)

        // —— 防睡眠
        root.addArrangedSubview(section(L("防睡眠（阻止系统睡眠）")))
        nosleepBtn = NSButton(checkboxWithTitle: L("息屏时不睡眠（每次息屏/关屏自动生效）"), target: self, action: #selector(onNosleepToggled(_:)))
        root.addArrangedSubview(nosleepBtn)
        lidBtn = NSButton(checkboxWithTitle: L("合盖后不睡眠（长期模式，重启自动恢复）"), target: self, action: #selector(onLidToggled(_:)))
        root.addArrangedSubview(lidBtn)
        root.addArrangedSubview(wrapLabel(L("开启后合盖时内屏熄灭、机器持续运行——下载、远程访问、外接显示照常工作。") +
            L("建议接电源使用；电池放电低于电量下限会自动停止。需要提权助手（下方安装）。")))

        let helperRow = NSStackView(); helperRow.orientation = .horizontal; helperRow.spacing = 10
        helperBtn = NSButton(title: L("安装提权助手…"), target: self, action: #selector(onInstallHelper(_:)))
        helperRow.addArrangedSubview(helperBtn)
        root.addArrangedSubview(helperRow)
        helperLabel = wrapLabel("")
        root.addArrangedSubview(helperLabel)

        // —— 恢复亮度
        root.addArrangedSubview(section(L("恢复后的亮度")))
        restorePop = NSPopUpButton(frame: .zero, pullsDown: false)
        restorePop.addItems(withTitles: [L("恢复到关屏前的亮度"), L("固定为")])
        restorePop.target = self; restorePop.action = #selector(onRestoreModeChanged(_:))
        root.addArrangedSubview(row(L("策略"), restorePop))

        let sliderRow = NSStackView(); sliderRow.orientation = .horizontal; sliderRow.spacing = 8
        restoreSlider = NSSlider(value: 50, minValue: 5, maxValue: 100, target: self, action: #selector(onSliderChanged(_:)))
        restoreSlider.widthAnchor.constraint(equalToConstant: 240).isActive = true
        restoreValueLabel = NSTextField(labelWithString: "50%")
        restoreValueLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true
        restoreValueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        sliderRow.addArrangedSubview(restoreSlider)
        sliderRow.addArrangedSubview(restoreValueLabel)
        root.addArrangedSubview(sliderRow)

        // —— 安全提醒
        root.addArrangedSubview(section(L("安全提醒")))
        root.addArrangedSubview(wrapLabel(
            L("关屏只是把背光调到 0，画面仍在渲染——这正是远程/屏幕共享仍能使用的原因。")
            + L("但同样意味着：关屏期间任何能碰到键盘鼠标的人仍可操作这台机器，只是看不见画面。")
            + L("离开座位前请手动锁屏（⌃⌘Q）。")))

        // —— 开机自启
        root.addArrangedSubview(section(L("启动")))
        loginBtn = NSButton(checkboxWithTitle: L("登录时自动启动（菜单栏常驻）"), target: self, action: #selector(onLoginToggled(_:)))
        root.addArrangedSubview(loginBtn)

        // —— 热键状态
        root.addArrangedSubview(section(L("热键状态")))
        permLabel = wrapLabel("")
        root.addArrangedSubview(permLabel)

        let btnRow = NSStackView(); btnRow.orientation = .horizontal; btnRow.spacing = 10
        checkBtn = NSButton(title: L("运行自检"), target: self, action: #selector(onCheck(_:)))
        btnRow.addArrangedSubview(checkBtn)
        root.addArrangedSubview(btnRow)

        // 版本号放在底部：`关于`面板之外，用户反馈问题时能一眼报出版本
        let ver = NSTextField(labelWithString: "BlankScreen v\(BS_VERSION)  (\(BS_COMMIT))")
        ver.font = .systemFont(ofSize: 11)
        ver.textColor = .tertiaryLabelColor
        root.addArrangedSubview(ver)

        root.addArrangedSubview(NSView())
        return w
    }

    // MARK: 构建辅助
    private func section(_ t: String) -> NSTextField {
        let l = NSTextField(labelWithString: t)
        l.font = .systemFont(ofSize: 13, weight: .semibold)
        return l
    }
    /// 换行标签必须显式指定宽度，否则 intrinsicContentSize 会把栈撑得比窗口还宽
    private func wrapLabel(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.preferredMaxLayoutWidth = 410
        l.widthAnchor.constraint(equalToConstant: 410).isActive = true
        return l
    }
    private func row(_ label: String, _ view: NSView) -> NSStackView {
        let s = NSStackView(); s.orientation = .horizontal; s.spacing = 10
        let l = NSTextField(labelWithString: label)
        l.font = .systemFont(ofSize: 12)
        l.widthAnchor.constraint(equalToConstant: 44).isActive = true
        l.alignment = .right
        s.addArrangedSubview(l); s.addArrangedSubview(view)
        view.widthAnchor.constraint(equalToConstant: 220).isActive = true
        return s
    }

    // MARK: 同步
    func syncFromConfig() {
        cfg = ctl.cfg
        for (flag, b) in modBtns { b.state = (cfg.modFlags & flag != 0) ? .on : .off }
        keyPop.selectItem(at: keyItems.firstIndex { $0.1 == cfg.keyCode } ?? 1)
        hkLabel.stringValue = L("当前: ") + hotkeyText(cfg) + L("　（设置即时生效）")
        timeoutPop.selectItem(at: timeoutChoices.firstIndex { $0.1 == cfg.timeout }
                              ?? timeoutChoices.firstIndex { $0.1 == 43200 }!)
        let floor = cfg.batteryFloor
        batteryPop.selectItem(at: batteryChoices.firstIndex { $0.1 == floor }
                              ?? batteryChoices.firstIndex { $0.1 == 20 }!)
        let fixed = cfg.restoreFixed
        restorePop.selectItem(at: fixed == nil ? 0 : 1)
        restoreSlider.isEnabled = fixed != nil
        restoreSlider.doubleValue = Double((fixed ?? 0.5) * 100)
        restoreValueLabel.stringValue = "\(Int(restoreSlider.doubleValue))%"
        loginBtn.state = isLoginItemEnabled() ? .on : .off
        syncNosleep()
        lidBtn.state = ctl.lidOn ? .on : .off
        refreshPerm()
    }

    /// 防睡眠与提权助手状态。助手是「系统级防睡眠」的前提，必须让用户看得见当前能力边界。
    private func syncNosleep() {
        nosleepBtn.state = cfg.autoNosleep ? .on : .off
        if ctl.helperInstalled() {
            helperBtn.title = L("卸载提权助手")
            // 过旧的助手缺少「多持有者记账」：关屏联动与手动防睡眠会互相踩掉对方的设置
            helperLabel.stringValue = ctl.helperOutdated()
                ? L("提权助手：版本过旧 —— 缺少多持有者记账，关屏联动与手动防睡眠会互相关掉对方。")
                  + L("请卸载后重新安装（需要输入一次登录密码）。")
                : L("提权助手：已安装 —— 防睡眠可覆盖电池供电与合盖。") +
                  L("（仅授权单个 root:wheel 脚本的四个固定参数）")
        } else {
            helperBtn.title = L("安装提权助手…")
            helperLabel.stringValue = L("提权助手：未安装 —— 此时防睡眠仅在本机接电源时有效，") +
                L("电池供电与合盖仍会睡眠。安装需输入登录密码，只授权一个脚本的四个固定参数。")
        }
        helperLabel.needsLayout = true
    }

    @objc private func onNosleepToggled(_ sender: Any?) {
        cfg.autoNosleep = (nosleepBtn.state == .on)
        ctl.cfg = cfg
        commit()
        // 已处于黑屏时立即生效，不必等下次关屏
        if cfg.autoNosleep && ctl.blacked { ctl.startNosleep(auto: true) }
    }

    /// 设置面板里的合盖模式开关。助手未安装时引导到下方安装按钮。
    @objc private func onLidToggled(_ sender: Any?) {
        let want = lidBtn.state == .on
        if want && !ctl.helperInstalled() {
            lidBtn.state = .off
            let a = NSAlert()
            a.messageText = L("「合盖后不睡眠」需要提权助手")
            a.informativeText = L("合盖会触发系统级睡眠，只有 root 权限的 pmset 能阻止它。") +
                L("点击下方「安装提权助手」（弹一次系统密码框）后再开启本项。")
            a.runModal()
            return
        }
        if ctl.setLidAwake(want) {
            cfg = ctl.cfg
            commit()
        } else {
            lidBtn.state = want ? .off : .on
        }
    }

    /// 调用 CLI 完成提权安装：密码框由系统弹出，App 不接触凭据
    @objc private func onInstallHelper(_ sender: Any?) {
        let cands = ["/opt/homebrew/bin/blankscreen", "/usr/local/bin/blankscreen"]
        guard let cli = cands.first(where: { fm.isExecutableFile(atPath: $0) }) else {
            let a = NSAlert(); a.messageText = L("未找到命令行工具")
            a.informativeText = L("请先在终端安装 blankscreen，或手动执行：\nblankscreen nosleep install-helper")
            a.runModal(); return
        }
        let uninstall = ctl.helperInstalled()
        helperBtn.isEnabled = false
        // 密码框会阻塞，必须放到后台线程；否则设置面板会卡住直到用户输入完成
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process(); p.executableURL = URL(fileURLWithPath: cli)
            p.arguments = ["nosleep", uninstall ? "uninstall-helper" : "install-helper"]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            var out = ""
            if (try? p.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                out = String(data: data, encoding: .utf8) ?? ""
            } else { out = (L("无法启动 ") + "\(cli)") }
            DispatchQueue.main.async {
                self.helperBtn.isEnabled = true
                self.syncNosleep()
                let a = NSAlert()
                a.messageText = uninstall ? L("卸载提权助手") : L("安装提权助手")
                a.informativeText = out.isEmpty ? L("已完成（无输出）") : out
                a.runModal()
            }
        }
    }
    private func refreshPerm() {
        let c = ctl.cfg
        permLabel.stringValue = ctl.hotkeyReady
            ? ("\(hotkeyText(c))" + L("：✅ 已注册为系统全局热键。本程序走系统级热键链路，不需要「辅助功能 / 输入监控」授权，也不会因重装 App 而失效。"))
            : ("\(hotkeyText(c))" + L("：⚠️ ") + "\(carbonStatusText(ctl.lastHotkeyStatus))" + L("。请换一个组合（建议 ⇧⌘B 或 ⌃⌥⌘B）。"))
    }

    // MARK: 事件
    @objc private func onHotkeyChanged(_ sender: Any?) {
        var flags: UInt64 = 0
        for (flag, b) in modBtns where b.state == .on { flags |= flag }
        // 系统全局热键必须带至少一个修饰键，否则 RegisterEventHotKey 会失败
        guard flags != 0 else {
            let a = NSAlert(); a.alertStyle = .warning
            a.messageText = L("需要修饰键")
            a.informativeText = L("系统级全局热键必须包含 ⌘ / ⌃ / ⌥ / ⇧ 中的至少一个，不能只用一个普通键。")
            a.addButton(withTitle: L("好")); a.runModal()
            syncFromConfig(); return
        }
        cfg.modFlags = flags
        cfg.keyCode = keyItems[keyPop.indexOfSelectedItem].1
        commit()
    }
    @objc private func onTimeoutChanged(_ sender: Any?) {
        cfg.timeout = timeoutChoices[timeoutPop.indexOfSelectedItem].1
        commit()
    }
    @objc private func onBatteryChanged(_ sender: Any?) {
        cfg.batteryFloor = batteryChoices[batteryPop.indexOfSelectedItem].1
        commit()
    }
    @objc private func onRestoreModeChanged(_ sender: Any?) {
        if restorePop.indexOfSelectedItem == 0 { cfg.restoreFixed = nil }
        else { cfg.restoreFixed = Float(restoreSlider.doubleValue / 100) }
        restoreSlider.isEnabled = cfg.restoreFixed != nil
        commit()
    }
    @objc private func onSliderChanged(_ sender: Any?) {
        restoreValueLabel.stringValue = "\(Int(restoreSlider.doubleValue))%"
        if restorePop.indexOfSelectedItem == 1 { cfg.restoreFixed = Float(restoreSlider.doubleValue / 100) }
        commit()
    }
    private func commit() {
        saveConfig(cfg)
        ctl.cfg = cfg
        ctl.reloadHotkey()
        if ctl.blacked {
            ctl.scheduleTimeout()
            ctl.scheduleBatteryGuard()
        }
        hkLabel.stringValue = L("当前: ") + hotkeyText(cfg) + L("　（设置即时生效）")
        AppDelegate.shared?.refreshUI()
    }

    @objc private func onCheck(_ sender: Any?) {
        AppDelegate.shared?.checkHotkey(sender)
        refreshPerm()
    }
    @objc private func onLoginToggled(_ sender: Any?) {
        setLoginItem(loginBtn.state == .on)
        loginBtn.state = isLoginItemEnabled() ? .on : .off
    }

    // MARK: 开机自启
    private var appPath: String {
        Bundle.main.bundlePath.hasSuffix(".app") ? Bundle.main.bundlePath
            : "/Applications/BlankScreenBar.app"
    }

    private func setLoginItem(_ on: Bool) {
        guard on else {
            sh("/bin/launchctl", ["bootout", "gui/\(getuid())/\(barLabel)"])
            try? fm.removeItem(atPath: barPlist)
            blog("bar: 已关闭登录自启")
            return
        }
        let exe = appPath + "/Contents/MacOS/BlankScreenBar"
        guard fm.fileExists(atPath: exe) else { return }
        let plist = loginItemPlist()
        try? plist.write(toFile: barPlist, atomically: true, encoding: .utf8)
        let gui = "gui/\(getuid())"
        sh("/bin/launchctl", ["bootout", "\(gui)/\(barLabel)"])
        let r = sh("/bin/launchctl", ["bootstrap", gui, barPlist])
        if r != 0 { sh("/bin/launchctl", ["load", "-w", barPlist]) }
        sh("/bin/launchctl", ["kickstart", "-k", "\(gui)/\(barLabel)"])
        if r != 0 {
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = L("已写入配置，但未能注册到 launchd")
            a.informativeText = (L("请在「终端」中执行：\n\nlaunchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/") + "\(barLabel)" + L(".plist\n\n或在系统设置的「登录项」里手动添加 ") + "\(appPath)")
            a.addButton(withTitle: L("好"))
            a.runModal()
        }
        blog("bar: 登录自启 -> \(on)")
    }
}

@discardableResult func sh(_ exe: String, _ a: [String]) -> Int32 {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = a
    p.standardOutput = nil; p.standardError = nil; p.standardInput = nil
    try? p.run(); p.waitUntilExit(); return p.terminationStatus
}

// MARK: - 菜单栏
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static weak var shared: AppDelegate?
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var toggleItem: NSMenuItem!
    private var nosleepItem: NSMenuItem!
    private var lidItem: NSMenuItem!
    private var setupItem: NSMenuItem!
    private var stateItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var permItem: NSMenuItem!
    private var hotkeyUnavailable = false
    private let ctl = ScreenController.shared
    private var settings: SettingsPanel?

    func applicationDidFinishLaunching(_ a: Notification) {
        AppDelegate.shared = self
        ctl.start()
        ctl.onStateChange = { [weak self] in self?.refreshUI() }

        // 用 variableLength 以便无授权时在图标旁显示警示标记
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.image = icon(blacked: false)
            b.image?.isTemplate = true
            b.toolTip = L("BlankScreen —— 点击打开菜单")
        }
        menu = buildMenu()
        menu.delegate = self
        // 交给 AppKit 原生弹出菜单（左键/右键都弹），点击不再直接开关显示器
        statusItem.menu = menu
        // 热键走 Carbon 链路，不依赖辅助功能授权；这里只反映注册结果
        hotkeyUnavailable = !ctl.hotkeyReady
        refreshUI()

        // 调试用：构建设置面板并打印布局树，验证无零尺寸 / 越界后自动退出
        if CommandLine.arguments.contains("--uitest") {
            openSettings(nil)
            Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { _ in
                if let w = NSApp.windows.first(where: { $0.title == L("BlankScreen 设置") }) {
                    blog("bar: uitest 窗口 frame=\(w.frame)")
                    Self.dumpView(w.contentView!, depth: 0)
                } else { blog("bar: uitest 未找到设置窗口") }
                blog("bar: uitest 完成")
                exit(0)
            }
        }
        // 调试用：自动跑一次热键自检，结果写入日志后退出（不影响屏幕状态）
        if CommandLine.arguments.contains("--selftest") {
            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
                self?.ctl.selfTest { ok in
                    blog("bar: selftest 结果=\(ok ? "通过" : "未通过")")
                    exit(0)
                }
            }
        }
    }

    private func icon(blacked: Bool) -> NSImage? {
        let name = blacked ? "moon.fill" : "sun.max.fill"
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) { return img }
        return NSImage(systemSymbolName: "display", accessibilityDescription: nil)
    }

    // MARK: 菜单
    private func buildMenu() -> NSMenu {
        let m = NSMenu()
        // MARK: 三个核心功能，表述一一对应：
        //   ① 关闭显示器 —— 立即黑屏（机器保持运行）
        //   ② 息屏时不睡眠 —— 每次息屏/关屏期间自动阻止系统睡眠
        //   ③ 合盖后不睡眠 —— 合盖也持续运行（长期模式，重启自动恢复）
        stateItem = NSMenuItem(title: L("○ 屏幕正常"), action: nil, keyEquivalent: "")
        m.addItem(stateItem)
        m.addItem(.separator())
        toggleItem = NSMenuItem(title: L("关闭显示器"), action: #selector(toggle(_:)), keyEquivalent: "")
        toggleItem.target = self
        toggleItem.toolTip = L("立即熄灭屏幕，机器保持运行；再点一次（或按热键）恢复")
        m.addItem(toggleItem)
        nosleepItem = NSMenuItem(title: L("息屏时不睡眠"), action: #selector(toggleAutoNosleep(_:)), keyEquivalent: "")
        nosleepItem.target = self
        nosleepItem.toolTip = L("开启后，每次息屏/关屏期间自动阻止系统睡眠，恢复显示时自动解除")
        m.addItem(nosleepItem)
        // 合盖模式：长期持久的「合盖也不睡」，由独立 CLI 守护持有，重启自动恢复
        lidItem = NSMenuItem(title: L("合盖后不睡眠（长期运行）"), action: #selector(toggleLidAwake(_:)), keyEquivalent: "")
        lidItem.target = self
        lidItem.toolTip = L("开启后合盖也不睡眠：内屏熄灭、机器持续运行；重启电脑后自动恢复")
        m.addItem(lidItem)
        // 首次使用装一次提权助手（弹系统密码框）；装好后此入口隐藏（设置面板仍可卸载）。
        setupItem = NSMenuItem(title: L("安装提权助手（首次使用）…"), action: #selector(runSetup(_:)), keyEquivalent: "")
        setupItem.target = self
        setupItem.toolTip = L("让「息屏时不睡眠」「合盖后不睡眠」覆盖电池与合盖（需 root，弹一次密码框）")
        m.addItem(setupItem)
        m.addItem(.separator())
        let set = NSMenuItem(title: L("设置…"), action: #selector(openSettings(_:)), keyEquivalent: ",")
        set.target = self; m.addItem(set)
        let chk = NSMenuItem(title: L("热键自检"), action: #selector(checkHotkey(_:)), keyEquivalent: "")
        chk.target = self; m.addItem(chk)
        permItem = NSMenuItem(title: "", action: #selector(openAuthorizeFromMenu(_:)), keyEquivalent: "")
        permItem.target = self; m.addItem(permItem)
        m.addItem(.separator())
        loginItem = NSMenuItem(title: L("登录时启动"), action: #selector(toggleLogin(_:)), keyEquivalent: "")
        loginItem.target = self; m.addItem(loginItem)
        let log = NSMenuItem(title: L("打开日志"), action: #selector(openLog(_:)), keyEquivalent: "")
        log.target = self; m.addItem(log)
        m.addItem(.separator())
        let q = NSMenuItem(title: L("退出"), action: #selector(quit(_:)), keyEquivalent: "q")
        q.target = self; m.addItem(q)
        return m
    }

    func refreshUI() {
        let blacked = ctl.blacked
        statusItem.button?.image = icon(blacked: blacked)
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.title = hotkeyUnavailable ? "⚠" : ""
        statusItem.button?.toolTip = hotkeyUnavailable
            ? (L("BlankScreen —— 快捷键未生效：") + "\(carbonStatusText(ctl.lastHotkeyStatus))")
            : (L("BlankScreen —— 快捷键 ") + "\(hotkeyText(ctl.cfg))" + L("，点击打开菜单"))
        stateItem.title = blacked ? L("● 屏幕已关闭 · 机器运行中") : L("○ 屏幕正常")
        toggleItem.title = blacked ? (L("恢复显示器  ") + "\(hotkeyText(ctl.cfg))") : (L("关闭显示器  ") + "\(hotkeyText(ctl.cfg))")
        // ② 息屏时不睡眠：勾选 = 自动联动已开启；黑屏中额外显示当前生效层级
        nosleepItem.state = ctl.cfg.autoNosleep ? .on : .off
        if blacked && ctl.nosleepOn {
            nosleepItem.title = ctl.nosleepSystemOn
                ? L("息屏时不睡眠（已生效 · 系统级）")
                : L("息屏时不睡眠（已生效 · 仅接电源）")
        } else {
            nosleepItem.title = L("息屏时不睡眠")
        }
        // ③ 合盖后不睡眠：勾选由系统菜单的原生 ✓ 表达，不再重复加字
        lidItem.state = ctl.lidOn ? .on : .off
        lidItem.title = L("合盖后不睡眠（长期运行）")
        setupItem.isHidden = ctl.helperInstalled()
        loginItem?.state = isLoginItemEnabled() ? .on : .off
        if hotkeyUnavailable {
            permItem.title = L("⚠️ 快捷键未生效 —— 点击排查")
            permItem.isHidden = false
        } else {
            permItem.isHidden = true
        }
    }

    /// 热键注册失败时（多为组合被系统占用），每次打开菜单重试一次
    func ensureHotkey() {
        guard !ctl.hotkeyReady else { return }
        ctl.installHotkey()
        hotkeyUnavailable = !ctl.hotkeyReady
        refreshUI()
    }
    func menuWillOpen(_ menu: NSMenu) { ensureHotkey() }

    /// 一键防睡眠：调 CLI `nosleep setup`（装助手弹系统密码框 + 开联动 + 立即防睡眠）
    @objc private func runSetup(_ sender: Any?) {
        let cands = ["/opt/homebrew/bin/blankscreen", "/usr/local/bin/blankscreen"]
        guard let cli = cands.first(where: { fm.isExecutableFile(atPath: $0) }) else {
            let a = NSAlert(); a.messageText = L("未找到命令行工具")
            a.informativeText = L("请先安装 blankscreen 命令行工具（.pkg 安装包已包含）。")
            a.runModal(); return
        }
        setupItem.isEnabled = false
        // 密码框会阻塞，必须放后台线程，否则菜单会卡住直到用户输入完成
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process(); p.executableURL = URL(fileURLWithPath: cli)
            p.arguments = ["nosleep", "setup"]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            var out = ""
            if (try? p.run()) != nil {
                out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                p.waitUntilExit()
            } else { out = (L("无法启动 ") + "\(cli)") }
            DispatchQueue.main.async {
                self.setupItem.isEnabled = true
                self.refreshUI()
                let a = NSAlert()
                a.messageText = L("一键防睡眠")
                a.informativeText = out.isEmpty ? L("已完成") : out
                a.runModal()
            }
        }
    }

    static func dumpView(_ v: NSView, depth: Int) {
        let pad = String(repeating: "  ", count: depth)
        blog("\(pad)\(type(of: v)) frame=\(v.frame)")
        for sub in v.subviews { dumpView(sub, depth: depth + 1) }
    }

    /// 菜单弹出前刷新状态（menuWillOpen 已负责重试热键监听）
    @objc func menuNeedsUpdate(_ menu: NSMenu) { refreshUI() }
    @objc private func toggle(_ sender: Any?) { ctl.toggle() }

    /// ② 息屏时不睡眠：开关的是「自动联动」配置。已在黑屏中则立即生效/解除。
    @objc private func toggleAutoNosleep(_ sender: Any?) {
        var c = loadConfig()
        c.autoNosleep.toggle()
        saveConfig(c)
        ctl.cfg = c
        if c.autoNosleep {
            if ctl.blacked { ctl.startNosleep(auto: true) }
            notifyUser(L("已开启「息屏时不睡眠」：") +
                (ctl.helperInstalled()
                    ? L("每次息屏/关屏期间自动阻止系统睡眠（系统级，覆盖合盖与电池）。")
                    : L("每次息屏/关屏期间自动阻止系统睡眠。注意：未安装提权助手时仅接电源有效，合盖仍会睡。")))
        } else {
            // 正在黑屏中的联动防睡眠随之解除；合盖模式（独立守护）不受影响
            if ctl.nosleepOn && ctl.nosleepAuto { ctl.stopNosleep(L("已关闭「息屏时不睡眠」")) }
            notifyUser(L("已关闭「息屏时不睡眠」：息屏/关屏不再阻止系统睡眠。"))
        }
        refreshUI()
    }

    /// 合盖不睡眠（长期模式）：一键开关，无需终端。
    /// 未装提权助手时引导走「一键防睡眠」的图形化安装，装完再点一次即可开启。
    @objc private func toggleLidAwake(_ sender: Any?) {
        if loadConfig().lidAwake {
            _ = ctl.setLidAwake(false)
            notifyUser(L("「合盖后不睡眠」已关闭：合盖后将恢复正常睡眠。"))
            refreshUI()
            return
        }
        guard ctl.helperInstalled() else {
            let a = NSAlert()
            a.messageText = L("「合盖后不睡眠」需要提权助手")
            a.informativeText = L("合盖会触发系统级睡眠，只有 root 权限的 pmset 能阻止它。") +
                L("点击「一键防睡眠」安装（弹一次系统密码框，仅授权单个脚本的固定参数），装完后再点本项即可。")
            a.addButton(withTitle: L("一键安装并开启"))
            a.addButton(withTitle: L("取消"))
            if a.runModal() == .alertFirstButtonReturn {
                runSetup(sender)
                // runSetup 的 setup 流程已包含「立即开启系统级防睡眠」；再把持久标志写上
                if ctl.lidDaemonPid() != nil || ctl.helperInstalled() {
                    _ = ctl.setLidAwake(true)
                }
            }
            refreshUI()
            return
        }
        if ctl.setLidAwake(true) {
            let floor = ctl.cfg.batteryFloor
            notifyUser(L("「合盖后不睡眠」已开启：合盖后内屏熄灭、机器持续运行（下载 / 远程 / 外接显示均可用）。") +
                       (floor > 0 ? (L("电池放电低于 ") + "\(floor)" + L("% 会自动停止。")) : ""))
        } else {
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = L("「合盖后不睡眠」开启失败")
            a.informativeText = L("可能原因：电池电量低于下限 / 守护启动未确认。\n详见「打开日志」。")
            a.runModal()
        }
        refreshUI()
    }

    @objc private func openSettings(_ sender: Any?) {
        if settings == nil { settings = SettingsPanel() }
        settings?.show()
    }
    @objc func checkHotkey(_ sender: Any?) {
        ensureHotkey()
        guard ctl.hotkeyReady else {
            let a = NSAlert(); a.alertStyle = .warning
            a.messageText = L("快捷键未生效")
            a.informativeText = ("\(hotkeyText(ctl.cfg))" + L("：") + "\(carbonStatusText(ctl.lastHotkeyStatus))" + L("。\n\n本程序使用系统级全局热键，不需要「辅助功能 / 输入监控」授权。若组合被其他 App 占用，请在设置里换一个。"))
            a.addButton(withTitle: L("好")); a.runModal(); return
        }
        statusItem.button?.title = "⏳"
        ctl.selfTest { [weak self] ok in
            DispatchQueue.main.async {
                self?.hotkeyUnavailable = !(self?.ctl.hotkeyReady ?? false)
                self?.refreshUI()
                let a = NSAlert()
                a.alertStyle = ok ? .informational : .warning
                a.messageText = ok ? L("热键可用") : L("热键未响应")
                a.informativeText = ok
                    ? (L("已确认系统把 ") + "\(hotkeyText(self?.ctl.cfg ?? Config()))" + L(" 投递给了本程序，可直接开关显示。"))
                    : (L("自检未收到 ") + "\(hotkeyText(self?.ctl.cfg ?? Config()))" + L("。\n\n可能原因：① 该组合被其他 App 抢先接管，换一个组合再试；② 本程序刚重装，系统热键表尚未刷新，退出重开一次。"))
                a.addButton(withTitle: L("好")); a.runModal()
            }
        }
    }
    @objc private func toggleLogin(_ sender: Any?) {
        let on = !(loginItem.state == .on)
        let exe = Bundle.main.bundlePath + "/Contents/MacOS/BlankScreenBar"
        guard fm.fileExists(atPath: exe) else { return }
        let plist = loginItemPlist()
        if on {
            try? plist.write(toFile: barPlist, atomically: true, encoding: .utf8)
            let gui = "gui/\(getuid())"
            sh("/bin/launchctl", ["bootout", "\(gui)/\(barLabel)"])
            var r = sh("/bin/launchctl", ["bootstrap", gui, barPlist])
            if r != 0 { r = sh("/bin/launchctl", ["load", "-w", barPlist]) }
            if r != 0 {
                let a = NSAlert(); a.alertStyle = .warning
                a.messageText = L("已写入配置，但未能注册 launchd")
                a.informativeText = (L("请在终端执行：\nlaunchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/") + "\(barLabel)" + ".plist")
                a.addButton(withTitle: L("好")); a.runModal()
            }
        } else {
            sh("/bin/launchctl", ["bootout", "gui/\(getuid())/\(barLabel)"])
            try? fm.removeItem(atPath: barPlist)
        }
        refreshUI()
    }
    @objc private func openLog(_ sender: Any?) {
        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
    }
    @objc private func quit(_ sender: Any?) { ctl.shutdown() }

    /// 热键未生效时的排查入口。刻意不弹模态对话框挡住主线程，只给提示 + 重试
    @objc private func openAuthorizeFromMenu(_ sender: Any?) {
        ensureHotkey()
        if ctl.hotkeyReady {
            blog("bar: 排查后热键已恢复 \(hotkeyText(ctl.cfg))")
            return
        }
        let a = NSAlert(); a.alertStyle = .warning
        a.messageText = L("快捷键未生效")
        let hotkeyHelp: String
        if L10n.isEN {
            hotkeyHelp = """
            \(hotkeyText(ctl.cfg)): \(carbonStatusText(ctl.lastHotkeyStatus))

            This app uses the system-level global hotkey (Carbon), so it needs no Accessibility or Input Monitoring grant.
            When it doesn't work, it is usually one of these three:
            1. Another app owns the combo — pick a different one in Settings, e.g. ⇧⌘B or ⌃⌥⌘B;
            2. The combo has no modifier — macOS requires at least one of ⌘ / ⌃ / ⌥ / ⇧;
            3. The app was just reinstalled and macOS has not refreshed its hotkey table — quit and relaunch once.
            """
        } else {
            hotkeyHelp = """
            \(hotkeyText(ctl.cfg))：\(carbonStatusText(ctl.lastHotkeyStatus))

            本程序使用系统级全局热键（Carbon），不需要「辅助功能 / 输入监控」授权。
            未生效通常是这三种情况：
            1. 组合被其他 App 占用 —— 在设置里换一个，例如 ⇧⌘B、⌃⌥⌘B；
            2. 组合没带修饰键 —— 系统要求 ⌘ / ⌃ / ⌥ / ⇧ 至少一个；
            3. App 刚重装，系统热键表未刷新 —— 退出本程序重开一次。
            """
        }
        a.informativeText = hotkeyHelp
        a.addButton(withTitle: L("打开设置"))
        a.addButton(withTitle: L("好"))
        if a.runModal() == .alertFirstButtonReturn { openSettings(nil) }
    }
}

// MARK: - 入口
if CommandLine.arguments.contains("--version") {
    print("BlankScreenBar \(BS_VERSION) (\(BS_COMMIT))")
    exit(0)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)          // 不显示 Dock 图标
let delegate = AppDelegate()
app.delegate = delegate
app.run()
