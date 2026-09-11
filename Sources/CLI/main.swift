// lidkeep —— 关屏但不睡眠（显示器熄灭，系统保持唤醒，远程可正常操控）
//
// 设计要点:
//  1. 采用「亮度归零」而非「显示器硬件睡眠」，确保屏幕共享/远程桌面仍能正常抓帧，
//     且任何按键鼠标都不会意外恢复显示（恢复完全由本程序控制）。
//  2. 黑屏期间由 caffeinate -is 持有断言，阻止系统空闲睡眠；不含 -d，
//     以免把「显示器睡眠」也一并挡住 —— 合盖熄屏正需要显示器能灭。
//  3. 以 0.5s 周期重设亮度为 0，压制环境光自动亮度。
//  4. 两种运行形态:
//     - 常驻服务(launchd): 热键 / CLI 信号 均可切换开关，开机自启
//     - 一次性 daemon:     `lidkeep off` 进入，恢复后进程退出
import Foundation
import CoreGraphics
import AppKit
import Carbon.HIToolbox
import IOKit
import Darwin

// MARK: - 路径
let home = NSHomeDirectory()
let base = home + "/Library/Application Support/LidKeep"
let stateFile = base + "/brightness.state"     // 存在即表示处于黑屏（同时保存待恢复亮度）
let pidFile = base + "/daemon.pid"             // 一次性 daemon
let serviceFile = base + "/service.pid"        // 常驻服务
let configFile = base + "/config.json"         // 持久化热键等配置
let plistFile = home + "/Library/LaunchAgents/com.lidkeep.agent.plist"
let logPath = base + "/LidKeep.log"
let commandFile = base + "/command"        // CLI -> 菜单栏 App 的指令文件
// 关屏被拒绝（电量过低 / 亮度接口不可用）时，常驻进程把原因写这里，
// 让发起命令的 CLI 能读到并明确提示用户，而不是只说「指令已发送」。
let rejectFile = base + "/reject"
let serviceLog = base + "/service.log"
let label = "com.lidkeep.agent"

// MARK: - 防睡眠（nosleep）
// caffeinate -s 的断言按 man page 明写「仅 AC 电源有效」，所以「电池供电」和
// 「合盖」两个场景进程级断言根本无效，只能走 pmset disablesleep（需 root）。
// 于是防睡眠分为两层：
//   Level 1  零权限：caffeinate（仅 AC 时有效，覆盖空闲/显示器睡眠）
//   Level 2  需 helper（默认不安装）：pmset disablesleep（覆盖电池 + 合盖）
let nosleepPidFile = base + "/nosleep.pid"          // 防睡眠守护进程
let nosleepStateFile = base + "/nosleep.state"      // 记录当前层级与开启时间
let helperDir = "/Library/PrivilegedHelperTools"
let helperPath = helperDir + "/com.lidkeep.pmset"
let sudoersPath = "/etc/sudoers.d/lidkeep"
let resetDaemon = "/Library/LaunchDaemons/com.lidkeep.nosleep.reset.plist"

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
// 因此必须核对 pid 对应的可执行文件路径确实属于 lidkeep。
func procPath(_ pid: Int32) -> String? {
    var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
    let n = proc_pidpath(pid, &buf, UInt32(buf.count))
    return n > 0 ? String(cString: buf) : nil
}
/// 取不到路径时返回 true（保持原有行为，避免因权限等因素误判导致功能不可用）
func isOurs(_ pid: Int32) -> Bool {
    guard let p = procPath(pid) else { return true }
    // 同时覆盖 /opt/homebrew/bin/lidkeep 与 .../LidKeep.app/.../LidKeep
    return p.lowercased().contains("lidkeep")
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
// 与 LidKeep.app 共用同一个 config.json；字段全部可缺省，旧版文件仍能读取
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
    /// 触底时做什么，见 BatteryAction；0 = 只恢复屏幕。由菜单栏 App 使用，CLI 必须镜像。
    var batteryAction: Int = 0
    /// 是否注册全局热键。由菜单栏 App 使用，CLI 必须镜像。
    var hotkeyEnabled: Bool = true
    var autoNosleep: Bool = false                            // 关屏时同时防睡眠（默认关：合盖不睡有耗电风险）
    // 合盖不睡眠长期模式：菜单栏 App 菜单一键管理
    var lidAwake: Bool = false
    // 合盖时熄灭内屏。与 lidAwake 分离：熄屏由合盖守护执行，
    // 关掉它则合盖只保持机器运转、内屏维持原亮度（熄屏异常时的退路）。
    var lidBlackout: Bool = true
    var lang: String = "auto"                             // 界面语言：auto=跟随系统 / zh / en
    var keepDisplayOn: Bool = false                       // 保持屏幕常亮：阻止显示器自动睡眠（caffeinate -d）
    /// 配置结构版本。旧配置没有这个字段 → 读出 0 → 走 migrate() 补齐语义。
    /// 借鉴 WorkBuddy 的 parsePowerSaveBlockerMode：字段语义一旦变过，老配置必须能被纠正，
    /// 而不是沿用写盘时的旧含义。
    var schemaVersion: Int = 0
    /// 以下两项由菜单栏 App 使用（自动检查更新）。CLI 不参与检查，但**必须镜像**：
    /// 两侧共写同一个 config.json，CLI 落盘时用自身 CodingKeys 编码，缺字段就会被抹掉。
    var autoCheckUpdate: Bool = true
    var lastUpdateCheckAt: Double = 0

    enum CodingKeys: String, CodingKey { case keyCode, modFlags, timeout, restoreFixed, batteryFloor, batteryAction, autoNosleep, lidAwake, lidBlackout, lang, keepDisplayOn, schemaVersion, autoCheckUpdate, lastUpdateCheckAt, hotkeyEnabled }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try c.decodeIfPresent(Int64.self, forKey: .keyCode) ?? 11
        modFlags = try c.decodeIfPresent(UInt64.self, forKey: .modFlags) ?? (MOD_CTRL | MOD_ALT | MOD_CMD)
        timeout = try c.decodeIfPresent(Double.self, forKey: .timeout) ?? 43200
        restoreFixed = try c.decodeIfPresent(Float.self, forKey: .restoreFixed)
        batteryFloor = try c.decodeIfPresent(Int.self, forKey: .batteryFloor) ?? 20
        batteryAction = try c.decodeIfPresent(Int.self, forKey: .batteryAction) ?? 0
        hotkeyEnabled = try c.decodeIfPresent(Bool.self, forKey: .hotkeyEnabled) ?? true
        autoNosleep = try c.decodeIfPresent(Bool.self, forKey: .autoNosleep) ?? false
        lidAwake = try c.decodeIfPresent(Bool.self, forKey: .lidAwake) ?? false
        lidBlackout = try c.decodeIfPresent(Bool.self, forKey: .lidBlackout) ?? true
        lang = try c.decodeIfPresent(String.self, forKey: .lang) ?? "auto"
        keepDisplayOn = try c.decodeIfPresent(Bool.self, forKey: .keepDisplayOn) ?? false
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        autoCheckUpdate = try c.decodeIfPresent(Bool.self, forKey: .autoCheckUpdate) ?? true
        lastUpdateCheckAt = try c.decodeIfPresent(Double.self, forKey: .lastUpdateCheckAt) ?? 0
    }
    /// 逐版本升级旧配置。返回 true 表示有改动、需要回写。
    /// 只由 loadConfig() 调用一次：init 里跑过的话，loadConfig 再跑会因版本已最新而无从判断是否该回写。
    @discardableResult
    mutating func migrate() -> Bool {
        guard schemaVersion < configSchemaVersion else { return false }
        if schemaVersion < 1 {
            // v0 → v1：合盖熄屏从「隐含在 lidAwake 里」拆成独立开关。
            // 之前开着合盖模式的用户，行为必须维持不变（合盖即熄屏）。
            if lidAwake { lidBlackout = true }
            schemaVersion = 1
        }
        return true
    }
}

/// 配置结构的当前版本。新增字段若带安全默认值（decodeIfPresent ?? x）就不必 bump；
/// 只有「同一字段换了语义」或「需要按旧值推导新值」时才 bump 并在 migrate() 里补一步。
let configSchemaVersion = 1

func loadConfig() -> Config {
    if let d = try? Data(contentsOf: URL(fileURLWithPath: configFile)),
       var c = try? JSONDecoder().decode(Config.self, from: d) {
        if c.migrate() { saveConfig(c) }     // 迁移结果落盘，避免每次启动重复迁移
        return c
    }
    var c = Config(); c.schemaVersion = configSchemaVersion
    return c
}

/// 原子写：先写同目录临时文件再 rename。
/// 菜单栏 App 与 CLI 守护会写同一个 config.json，直接覆盖会在崩溃/并发瞬间留下半截 JSON，
/// 下一次读出空配置（热键回到默认、模式全关）——这类故障极难复现，必须一开始就排除。
func saveConfig(_ c: Config) {
    guard let d = try? JSONEncoder().encode(c) else { return }
    let tmp = configFile + ".tmp.\(getpid())"
    do {
        try d.write(to: URL(fileURLWithPath: tmp))
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tmp)
        if rename(tmp, configFile) != 0 { try? fm.removeItem(atPath: tmp) }
    } catch {
        try? fm.removeItem(atPath: tmp)
    }
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

/// 所有在线显示器。
/// 只操作 CGMainDisplayID() 会漏掉外接显示器——用户要的是「关屏」，那必须是所有屏。
func onlineDisplays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [CGMainDisplayID()] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(count, &ids, &count)
    return ids.prefix(Int(count)).isEmpty ? [CGMainDisplayID()] : Array(ids.prefix(Int(count)))
}

/// 上一次设置亮度时失败的显示器。多数 HDMI / DVI 外接屏不支持软件亮度，
/// 这类屏幕关不掉，必须让用户看见，而不是让他以为一切正常。
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
// 返回 false = 设置失败（实测该 API 成功时返回 0）。调用方必须据此提示用户，
// 否则用户会以为关屏成功、实际屏幕还亮着。
// 遍历所有在线显示器：只关主屏会让外接屏继续亮着，等于没关。
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
/// 恢复必须尽最大努力成功：失败意味着用户永远看不见屏幕。
/// 因此多次重试（间隔递增），而不是「设一次就走」。
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

// MARK: - 内屏亮度（合盖熄屏专用，只动内屏，不碰外接屏）
//
// 合盖熄屏绝不能用 setBrightness(0)：那会把外接显示器也熄掉，而外接场景
// （clamshell 模式）下用户可能正盯着外接屏工作。只操作内建显示器。
func builtinDisplays() -> [CGDirectDisplayID] {
    onlineDisplays().filter { CGDisplayIsBuiltin($0) != 0 }
}

@discardableResult
func setBuiltinBrightness(_ v: Float) -> Bool {
    var ok = false
    for id in builtinDisplays() { if setOneBrightness(id, v) { ok = true } }
    return ok
}

func builtinBrightness() -> Float {
    guard let id = builtinDisplays().first,
          let h = dsHandle, let p = dlsym(h, "DisplayServicesGetBrightness") else { return -1 }
    var v: Float = -1
    return unsafeBitCast(p, to: DSGet.self)(id, &v) == 0 ? v : -1
}

// MARK: - 电池状态与通知
// pmset -g batt 免任何授权。只有「电池供电且正在放电」才算有耗尽风险：
// 插着电时哪怕电量低也不会耗尽，此时阻止用户关屏毫无意义。
struct Battery { var onBattery = false, discharging = false, percent = 100 }

func batteryStatus() -> Battery {
    var b = Battery()
    // 测试钩子：LK_SIMULATE_BATTERY="电量,batt|ac,discharging|charging"
    // 例: LK_SIMULATE_BATTERY="15,batt,discharging" lidkeep off
    // 仅供验证电量保护路径（插电的机器无法真实触发），正式使用不需要也不读取它。
    if let sim = ProcessInfo.processInfo.environment["LK_SIMULATE_BATTERY"] {
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
    _ = runCapture("/usr/bin/osascript", ["-e", "display notification \"\(safe)\" with title \"LidKeep\""])
}

// MARK: - 合盖检测（SMC MSLD 键）
//
// 为什么需要它：pmset disablesleep 只阻止「睡眠」这件事本身。合盖后系统不睡了，
// 但 macOS 也不会替我们熄灭内屏背光——屏幕在包里一直亮着（v1.5.1 及之前的缺陷）。
// 防睡眠守护必须自己知道盖子何时合上：合盖 → 熄灭内屏，开盖 → 恢复亮度。
//
// SMC 的 MSLD 键是固件维护的合盖状态（1=合盖，0=开盖，Asahi Linux 内核驱动
// macsmc-hid 即读它上报 SW_LID）。结构体与调用约定照搬 exelban/stats 的
// 实现——SMC 用户客户端的字节级布局多年来只被证明在这份定义下正确。
struct SMCKeyData_t {
    struct vers_t {
        var major: CUnsignedChar = 0
        var minor: CUnsignedChar = 0
        var build: CUnsignedChar = 0
        var reserved: CUnsignedChar = 0
        var release: CUnsignedShort = 0
    }
    struct LimitData_t {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }
    struct keyInfo_t {
        var dataSize: IOByteCount32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }
    var key: UInt32 = 0
    var vers = vers_t()
    var pLimitData = LimitData_t()
    var keyInfo = keyInfo_t()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
               (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

final class SMCLid {
    private var conn: io_connect_t = 0
    private(set) var opened = false

    /// 连接 AppleSMC。失败（台式机 / 虚拟机 / SMC 不可见）不致命，调用方降级即可。
    func open() -> Bool {
        guard !opened else { return true }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSMC"), &iterator) == kIOReturnSuccess else { return false }
        let device = IOIteratorNext(iterator)
        IOObjectRelease(iterator)
        guard device != 0 else { return false }
        defer { IOObjectRelease(device) }
        guard IOServiceOpen(device, mach_task_self_, 0, &conn) == kIOReturnSuccess else { return false }
        opened = true
        return true
    }

    func close() {
        guard opened else { return }
        IOServiceClose(conn)
        conn = 0
        opened = false
    }

    deinit { close() }

    private func call(_ input: inout SMCKeyData_t, _ output: inout SMCKeyData_t) -> kern_return_t {
        var outputSize = MemoryLayout<SMCKeyData_t>.stride
        return withUnsafeMutablePointer(to: &input) { ip in
            withUnsafeMutablePointer(to: &output) { op in
                IOConnectCallStructMethod(conn, 2, ip, MemoryLayout<SMCKeyData_t>.stride, op, &outputSize)
            }
        }
    }

    /// 读 1 字节 SMC 键。返回 nil = 键不存在 / SMC 不响应。
    private func readKeyByte(_ name: String) -> UInt8? {
        guard name.utf8.count == 4 else { return nil }
        var input = SMCKeyData_t()
        var output = SMCKeyData_t()
        input.key = name.utf8.reduce(0) { $0 << 8 | UInt32($1) }
        input.data8 = 9                              // SMC_CMD_READ_KEYINFO
        guard call(&input, &output) == kIOReturnSuccess, output.keyInfo.dataSize > 0 else { return nil }
        input.keyInfo.dataSize = output.keyInfo.dataSize
        input.data8 = 5                              // SMC_CMD_READ_BYTES
        guard call(&input, &output) == kIOReturnSuccess else { return nil }
        return output.bytes.0
    }

    /// 合盖状态：true = 已合盖。nil = 本机无法检测（台式机 / 虚拟机属正常）。
    ///
    /// 测试钩子：LK_SIMULATE_LID_CLOSED=1/0 强行指定合盖状态。
    /// 仅供冒烟测试在「盖子无法物理开合」的环境里驱动熄屏/恢复路径，正式使用不读取。
    func lidClosed() -> Bool? {
        if let sim = ProcessInfo.processInfo.environment["LK_SIMULATE_LID_CLOSED"] {
            let v = sim.lowercased()
            return v == "1" || v == "yes" || v == "true" || v == "closed"
        }
        guard opened, let v = readKeyByte("MSLD") else { return nil }
        return v == 1
    }
}

// MARK: - 提权助手（防睡眠 Level 2：覆盖电池与合盖）
//
// 为什么必须有它：caffeinate -s 的断言「仅 AC 电源有效」（man caffeinate 明写），
// 所以电池供电与合盖这两种防睡眠场景，进程级断言根本无效。
//
// 安全模型（吸取 Sleepless / Amphetamine 的教训，我们的约束比二者都更窄）：
//   * helper 放 /Library/PrivilegedHelperTools（root:wheel，普通用户不可写）→ 无法被替换提权
//   * sudoers 精确到「单用户 + (root) + 四个字面量参数各一条」，不接受通配
//     （Sleepless 是 <user> ALL=(root)，Amphetamine 是 %admin ALL=(ALL)，我们更窄）
//   * 默认不安装：用户显式执行 install-helper 才会装（会弹系统密码框）
//   * 开机强制复位：disablesleep 是持久全局设置，崩溃/卸载后若不复位会把系统
//     永久留在「永不睡眠」状态（本机 Amphetamine 就是活证据：SleepDisabled=1、7 天未睡眠）

/// 两个文件齐全才算已安装。只查文件会出现「装了一半」却静默降级的情况。
/// 注意 sudoers 只判存在、不能读内容：0440 root:wheel 对普通用户不可读，读会误判未安装。
func helperInstalled() -> Bool {
    guard fm.isExecutableFile(atPath: helperPath),
          fm.fileExists(atPath: sudoersPath) else { return false }
    return true
}

/// 提权助手版本是否过旧：带「持有者记账」的版本 detect 输出会带 owners= 字段。
/// 旧版没有记账 —— 关屏联动与手动防睡眠会互相踩掉对方的 disablesleep。
func helperOutdated() -> Bool {
    guard helperInstalled(), let d = helperExec("detect") else { return false }
    return !d.contains("owners=")
}

/// 经 sudo -n 调用 helper。arg 走白名单，杜绝参数注入。
/// 返回 nil = 不可用（未安装 / 授权失效 / pmset 已移除该选项），调用方必须据此降级并告知用户。
func helperExec(_ arg: String) -> String? {
    guard ["on", "off", "status", "detect"].contains(arg), helperInstalled() else { return nil }
    return runCapture("/usr/bin/sudo", ["-n", helperPath, arg])?
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// 系统级防睡眠当前是否真的生效（回读真实状态，不靠自己记的标志）
func systemSleepDisabled() -> Bool {
    guard let s = helperExec("status"), let v = Int(s) else { return false }
    return v == 1
}

/// 把脚本交给 root 执行（触发系统密码框）。脚本先落盘再执行，避免 shell 多层转义出错。
func runAsAdmin(_ scriptBody: String) -> (ok: Bool, out: String) {
    // 落在自己的状态目录（仅当前用户可写），而不是 /tmp。
    // /tmp 是全局可写目录：提权脚本放那里存在被其他进程抢先创建同名文件替换的窗口，
    // 而 osascript 随后会以 root 执行它。用私有目录消除这条提权旁路。
    let f = base + "/.install." + String(ProcessInfo.processInfo.processIdentifier) + ".sh"
    do {
        try scriptBody.write(toFile: f, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f)
    } catch { return (false, (L("无法写入临时脚本: ") + "\(error)")) }
    defer { try? fm.removeItem(atPath: f) }
    // 路径含空格（~/Library/Application Support/...），必须整体加引号再交给
    // do shell script：不加引号会被 sh 拆成「不存在的命令 + 参数」，
    // osascript 以非 0 退出、stdout 为空——旧实现只看 stdout 是否为 nil，
    // 于是静默漏装还报「安装完成」（v1.5.2 前 helper 一直没被真正升级的根因）。
    let safe = f.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "do shell script \"'\(safe)'\" with administrator privileges"]
    p.standardInput = FileHandle.nullDevice
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (false, (L("无法启动 osascript: ") + "\(error)")) }
    // 必须先读再等：管道缓冲写满会让子进程卡死在 write 上
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    // 以退出码判定成败；输出只用于展示（osascript 的报错文本在 stderr，已合并进来）
    return (p.terminationStatus == 0, out.isEmpty ? (p.terminationStatus == 0 ? L("完成") : L("授权失败或被取消")) : out)
}

// MARK: - 防睡眠状态

struct NosleepInfo { var level = "caffeinate"; var since = Date(); var systemOn = false }

func nosleepPid() -> Int32? {
    // 归属校验不能省：pid 被系统复用后发信号会打到无关进程上
    guard let s = try? String(contentsOfFile: nosleepPidFile, encoding: .utf8),
          let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)),
          kill(pid, 0) == 0, isOurs(pid) else { return nil }
    return pid
}

func nosleepInfo() -> NosleepInfo? {
    guard nosleepPid() != nil,
          let s = try? String(contentsOfFile: nosleepStateFile, encoding: .utf8) else { return nil }
    let p = s.split(separator: "|").map(String.init)
    var i = NosleepInfo()
    if p.count >= 1 { i.level = p[0] }
    if p.count >= 2, let t = Double(p[1]) { i.since = Date(timeIntervalSince1970: t) }
    if p.count >= 3 { i.systemOn = p[2] == "1" }
    return i
}

/// 第三方防睡眠持有者：远控类软件（UURemote / ToDesk / 向日葵等）以 root 周期性
/// 写入 pmset disablesleep=1 保持远程会话可用——它们与本程序共享这一个全局开关。
/// 本机实测（UURemoteHelper，root XPC）：无 sudo 记录、约 1-2 分钟节奏重写。
/// 检测到它们在跑时，「无守护 + 开关开着」不算本程序的残留：复位只会互相打架
/// （我们关→它再开→doctor 永远报红），应共存并如实告知用户。
func thirdPartySleepHolder() -> String? {
    let names = ["UURemote", "ToDesk", "SunloginClient", "SunloginAword", "OrayRemote",
                 "TeamViewer", "AnyDesk", "RustDesk", "rustdesk", "Parsec", "Splashtop"]
    for n in names {
        if let out = runCapture("/usr/bin/pgrep", ["-f", n]), !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return n
        }
    }
    return nil
}

/// 清理残留：守护进程已死但 disablesleep 仍开着时，必须复位。
/// 这是“卸载/崩溃后系统永不睡眠”的唯一补救通道（开机 LaunchDaemon 之外的第二道防线）。
/// 不要求先有状态文件：残留也可能来自外部（其他工具写入、状态文件被清理等），
/// 只要「没有我们的守护在跑 + 系统级开关仍开着」就该复位——doctor 对同一状态的
/// 判定口径也是如此，不能出现「doctor 报错、推荐的修复命令却不生效」的自相矛盾。
/// 例外：远控软件在持有该开关时（见 thirdPartySleepHolder）绝不复位。
func recoverStaleNosleep() {
    guard nosleepPid() == nil else { return }
    try? fm.removeItem(atPath: nosleepPidFile)
    try? fm.removeItem(atPath: nosleepStateFile)
    guard helperInstalled(), systemSleepDisabled() else { return }
    if let app = thirdPartySleepHolder() {
        log((L("nosleep: disablesleep 开启但无本程序守护；检测到远控软件 ") + "\(app)" + L(" 在运行，判定为其持有（保持远程可用），不复位")))
        return
    }
    _ = helperExec("off")
    log(L("nosleep: 检测到 disablesleep 仍开启但无守护进程，已自动复位"))
}

// MARK: - 提权助手资产（内嵌为唯一真相源）
//
// 资产内嵌在二进制里，而不是随包附带散文件：CLI 可能被拷到任何位置，
// 依赖同目录文件会让它换个地方就失效。packaging/helper/ 下的同名文件由
// `lidkeep nosleep write-assets` 生成，便于人工审计与 CI 校验一致性。

let helperScript = #"""
#!/bin/sh
# com.lidkeep.pmset —— 以 root 执行的极窄权限助手
#
# 存在的唯一理由：caffeinate -s 的断言仅在 AC 电源下有效（见 man caffeinate），
# 因此「电池供电」与「合盖」两种防睡眠场景无法用进程级断言实现，
# 只能求助于 pmset disablesleep 这个全局开关，而它需要 root。
#
# 安全约束（任意一条被破坏都必须视为漏洞）：
#   1. 本文件必须是 root:wheel 且权限 0755；目录 /Library/PrivilegedHelperTools
#      同样为 root:wheel —— 普通用户无法改写脚本内容。
#   2. sudoers 中精确列出「单用户 + (root) + 每个参数各一条」，不接受通配。
#   3. 只接受 on / off / status / detect 四个字面量，其他一律 exit 2。
#   4. 绝不接受路径或数值参数，杜绝 pmset 被借去改其他设置。
#   5. 引入持有者记账（见下方 OWNDIR）：关屏联动与手动防睡眠可能同时依赖这个
#      唯一的全局开关，任一方停止时只注销自己，绝不关掉别人正依赖的防睡眠。

set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

PMS=/usr/bin/pmset
LOG_TAG=com.lidkeep.pmset

# 持有者目录（root:wheel，普通用户不可写）。
#
# 为什么需要它：disablesleep 是**一个**全局开关，但可能有多个持有者同时依赖它
# —— 例如「关屏联动防睡眠」和「手动 nosleep 守护」各自独立启停。没有持有者记账时，
# 任何一方关闭都会顺手把另一方的防睡眠也关掉（互相踩踏）。
#
# 记账放在 root 拥有的目录里，普通用户无法伪造持有者来阻止复位。
OWNDIR=/var/db/lidkeep-nosleep

# 找到真正的调用者 pid：本脚本的祖先链是 helper -> sudo -> 调用者。
# 逐级上溯并跳过 sudo 自身，取第一个非 sudo 的进程。
caller_pid() {
    p=$$
    i=0
    while [ $i -lt 6 ]; do
        p=$(/bin/ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ') || return 0
        [ -n "$p" ] || return 0
        case "$(/bin/ps -o comm= -p "$p" 2>/dev/null)" in
            *sudo*) i=$((i+1)); continue ;;
            *) echo "$p"; return 0 ;;
        esac
    done
}

# 清理已失效的持有者：进程已退出，或 pid 已被系统复用给别的程序。
# 不清会让崩溃残留的持有者把系统永久留在「永不睡眠」状态——这是同类工具最常见的翻车方式。
prune_owners() {
    [ -d "$OWNDIR" ] || return 0
    for f in "$OWNDIR"/*; do
        [ -e "$f" ] || continue
        opid=${f##*/}
        case "$opid" in ''|*[!0-9]*) rm -f "$f"; continue ;; esac
        case "$(/bin/ps -o comm= -p "$opid" 2>/dev/null)" in
            *lidkeep*|*LidKeep*) ;;
            *) rm -f "$f" ;;
        esac
    done
    return 0
}

owner_count() {
    n=$(/bin/ls -A "$OWNDIR" 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')
    echo "${n:-0}"
}

usage() {
    echo "usage: com.lidkeep.pmset on|off|status|detect" >&2
    exit 2
}

[ $# -eq 1 ] || usage

case "$1" in
    on)
        # disablesleep 未文档化：在部分系统上可能已被移除。
        # 失败必须让调用方看得见（非 0 退出码），不能静默降级。
        if ! "$PMS" disablesleep 1 2>/dev/null; then
            echo "$LOG_TAG: 'pmset disablesleep 1' 失败（该选项可能已被移除）" >&2
            exit 1
        fi
        prune_owners
        /bin/mkdir -p "$OWNDIR" 2>/dev/null && /bin/chmod 700 "$OWNDIR"
        c=$(caller_pid)
        if [ -n "$c" ]; then : > "$OWNDIR/$c" 2>/dev/null; fi
        echo "on"
        ;;
    off)
        # 只注销自己。还有其他持有者在用时绝不能复位——那会把别人正依赖的防睡眠关掉。
        prune_owners
        c=$(caller_pid)
        if [ -n "$c" ]; then rm -f "$OWNDIR/$c" 2>/dev/null; fi
        if [ "$(owner_count)" = "0" ]; then
            "$PMS" disablesleep 0 >/dev/null 2>&1
        fi
        echo "off"
        ;;
    status)
        v=$("$PMS" -g 2>/dev/null | awk '/SleepDisabled/{print $2}')
        echo "${v:-0}"
        ;;
    detect)
        # 只读探测：报告当前值 + 本进程是否有写入权限。
        #
        # 不能用「写一次看退出码」来判定支持性 —— 实测在非 root 下
        # `pmset disablesleep 0` 退出码为 0 却并未生效（读回值不变），
        # 照退出码判定会得出「支持」的错误结论。
        # 同理，这里绝不能真的写入：本机若被其他工具设了 disablesleep=1，
        # 探测顺手改成 0 会破坏别人的状态（写入应由显式开启去做）。
        v=$("$PMS" -g 2>/dev/null | awk '/SleepDisabled/{print $2}')
        prune_owners
        n=$(owner_count)
        if [ "$(/usr/bin/id -u)" = "0" ]; then
            echo "root:current=${v:-0} owners=$n"
        else
            echo "user:current=${v:-0} owners=$n"
        fi
        ;;
    *)
        usage
        ;;
esac
"""#

let resetPlist = #"""
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!--
  com.lidkeep.nosleep.reset —— 开机时把 disablesleep 复位为 0。

  为什么必须有它：
  pmset disablesleep 是**持久**的全局设置，写入后即使进程被 SIGKILL 也仍然生效。
  这意味着崩溃、强退、卸载都可能把系统留在「永不睡眠」状态，且用户无从察觉。

  本 LaunchDaemon 只在开机瞬间执行一次（KeepAlive=false，跑完即退），
  保证每次启动都从干净状态开始；随后由用户显式开启防睡眠。
  它不是常驻 root 进程，攻击面极小。
-->
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.lidkeep.nosleep.reset</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/pmset</string>
        <string>disablesleep</string>
        <string>0</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
"""#

/// sudoers：精确到「单用户 + 仅 root + 四个字面量参数各一条」。
/// 比 Sleepless 的 `<user> ALL=(root)` 与 Amphetamine 的 `%admin ALL=(ALL)` 都更窄。
func sudoersBody(_ user: String) -> String {
    let lines = ["on", "off", "status", "detect"]
        .map { "\(user) ALL=(root) NOPASSWD: \(helperPath) \($0)" }
    return lines.joined(separator: "\n") + "\n"
}

/// 分段拼接而非一个整段多行字符串：heredoc 的终止符必须顶格才能被 shell 识别，
/// 而 Swift 多行字符串会整体剥离缩进，直接写在一起会让终止符带上前导空格而失效。
func installHelperScript(_ user: String) -> String {
    let part1 = """
    #!/bin/sh
    set -e
    H="\(helperPath)"
    S="\(sudoersPath)"
    D="\(resetDaemon)"

    /bin/mkdir -p \(helperDir)
    /bin/cat > "$H" <<'LIDKEEP_HELPER_EOF'
    """
    let part2 = """
    LIDKEEP_HELPER_EOF
    /usr/sbin/chown root:wheel "$H"; /bin/chmod 755 "$H"

    /bin/cat > "$S" <<'LIDKEEP_SUDOERS_EOF'
    """
    let part3 = """
    LIDKEEP_SUDOERS_EOF
    /usr/sbin/chown root:wheel "$S"; /bin/chmod 440 "$S"

    # 写坏 sudoers 会让整台机器无法提权，所以必须先校验；失败立即回滚。
    if ! /usr/sbin/visudo -c -f "$S" >/dev/null 2>&1; then
        /bin/rm -f "$S"
        echo "错误：sudoers 语法校验失败，已回滚" >&2
        exit 1
    fi

    /bin/cat > "$D" <<'LIDKEEP_PLIST_EOF'
    """
    let part4 = """
    LIDKEEP_PLIST_EOF
    /usr/sbin/chown root:wheel "$D"; /bin/chmod 644 "$D"

    echo "installed"
    """
    // 每段之间必须显式插入换行：Swift 多行字符串会吃掉结尾换行，
    // 而内嵌资产的 raw string 同样不以换行结尾。少了换行，heredoc 的终止符会与
    // 内容首行挤在同一行，导致 heredoc 整体失效（内容被当成命令参数）。
    return part1 + "\n" + helperScript + "\n" + part2 + "\n"
         + sudoersBody(user) + part3 + "\n" + resetPlist + "\n" + part4
}

/// 卸载顺序很关键：先复位 disablesleep，再删 helper。
/// 反过来的话，一旦 helper 被删就再也无法复位，系统会被永久留在「永不睡眠」状态
/// ——这正是同类工具最常见的翻车方式。
func uninstallHelperScript() -> String {
    """
    #!/bin/sh
    /usr/bin/pmset disablesleep 0 2>/dev/null || true
    /bin/launchctl bootout system/com.lidkeep.nosleep.reset 2>/dev/null || true
    /bin/rm -rf /var/db/lidkeep-nosleep
    /bin/rm -f \(resetDaemon)
    /bin/rm -f \(sudoersPath)
    /bin/rm -f \(helperPath)
    echo "uninstalled"
    """
}

// MARK: - 防睡眠守护进程

var nosleepStopFlag = false   // 信号处理只置位，收尾在主循环做（AppKit 下 GCD 交付不可靠）

func runNosleepDaemon(timeout: TimeInterval?, wantSystem: Bool) -> Never {
    let cfg = loadConfig()
    let myPid = ProcessInfo.processInfo.processIdentifier
    var systemOn = false
    var caff: Process?
    var stopped = false

    // MARK: 合盖 → 熄灭内屏（v1.5.2）
    //
    // disablesleep 只阻止睡眠：合盖后 macOS 不会替我们关掉内屏背光，屏幕在包里
    // 一直亮着。守护进程持有 disablesleep 的同时，也由它负责合盖熄屏——
    // 守护退出（电量下限 / 超时 / 手动 off）时一并恢复亮度，不留黑屏残局。
    let lidSMC = SMCLid()
    var lidMonitorOn = false        // SMC 可读才启用（台式机 / 虚拟机自动禁用）
    var lidDimmed = false           // 当前处于「已合盖 · 内屏已熄灭」状态
    var lidSaved: Float = 0.5       // 合盖前的内屏亮度
    var lidCloseStreak = 0          // 连续读数滤波：连续两次合盖才动作，防抖动误判
    var lidFailStreak = 0           // SMC 连续读取失败次数（用于避免刷屏）
    var lidPinTimer: Timer?
    var lidWakeObserver: NSObjectProtocol?

    /// 读合盖状态，并在连接失效时自愈重连一次。
    ///
    /// 为什么需要它：系统睡眠/唤醒后，SMC 的 IOService 连接常常失效，此后
    /// lidClosed() 一直返回 nil。早先的实现直接 return，既不熄屏也不留任何
    /// 日志 —— 用户看到的就是「合盖后屏幕一直亮着」，而排查时日志干干净净。
    func lidClosedHealing() -> Bool? {
        if let v = lidSMC.lidClosed() { lidFailStreak = 0; return v }
        lidSMC.close()
        if lidSMC.open(), let v = lidSMC.lidClosed() {
            lidFailStreak = 0
            log(L("lid: SMC 连接已重建（系统睡眠唤醒后连接会失效，已自动恢复）"))
            return v
        }
        lidFailStreak += 1
        // 每次失败都写日志会在长夜里刷爆日志，只记首次与之后每分钟一次
        if lidFailStreak == 1 || lidFailStreak % 120 == 0 {
            log(L("lid: SMC 读取失败且重连未成功，合盖熄屏暂时不可用"))
        }
        return nil
    }

    func lidRestoreBrightness(_ retryLog: String) {
        let target = lidSaved
        lidPinTimer?.invalidate(); lidPinTimer = nil
        if setBuiltinBrightness(target) { return }
        for i in 0..<5 {
            usleep(UInt32(120_000 * (i + 1)))
            if setBuiltinBrightness(target) { return }
        }
        log(retryLog)
    }

    /// immediate=true 时跳过防抖（系统唤醒后调用：此时盖子已合上一段时间，
    /// 再等两轮轮询就等于把「屏幕亮着」又延长了两秒）。
    func checkLid(immediate: Bool = false) {
        guard lidMonitorOn, !stopped else { return }
        guard let closed = lidClosedHealing() else { return }
        if closed {
            lidCloseStreak += 1
            guard lidCloseStreak >= 2 || immediate, !lidDimmed else { return }
            let cur = builtinBrightness()
            lidSaved = cur > 0.001 ? cur : 0.5
            if setBuiltinBrightness(0.0) {
                lidDimmed = true
                log((L("lid: 检测到合盖，内屏已熄灭（原亮度 ") + "\(lidSaved)" + L("，机器保持运行；外接屏不受影响）")))
                let p = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                    if lidDimmed { setBuiltinBrightness(0.0) }   // 压制环境光自动亮度
                }
                RunLoop.main.add(p, forMode: .common)
                lidPinTimer = p
            } else {
                log(L("lid: 已合盖但内屏亮度设置失败（DisplayServices 不可用？），本机屏幕将继续点亮"))
            }
        } else {
            lidCloseStreak = 0
            guard lidDimmed else { return }
            lidDimmed = false
            log((L("lid: 检测到开盖，恢复内屏亮度 ") + "\(lidSaved)"))
            lidRestoreBrightness(L("lid: 错误：内屏亮度恢复失败，请手动调整亮度"))
        }
    }

    func stop(_ reason: String, notifyUser: Bool) {
        guard !stopped else { return }
        stopped = true
        // 系统级开关是持久的，退出前必须显式复位，否则系统再也不会睡眠
        if systemOn {
            _ = helperExec("off")
            log(L("nosleep: 已复位 disablesleep=0"))
        }
        // 守护退出时若内屏还处于合盖熄灭状态，必须先恢复亮度再走，
        // 否则用户开盖后屏幕是黑的，而能负责恢复的进程已经不在了
        if lidDimmed {
            lidDimmed = false
            log((L("lid: 守护退出，恢复内屏亮度 ") + "\(lidSaved)"))
            lidRestoreBrightness(L("lid: 错误：退出时内屏亮度恢复失败，请手动调整亮度"))
        }
        if let ob = lidWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(ob)
            lidWakeObserver = nil
        }
        lidSMC.close()
        caff?.terminate(); caff = nil
        try? fm.removeItem(atPath: nosleepPidFile)
        try? fm.removeItem(atPath: nosleepStateFile)
        log((L("nosleep 停止：") + "\(reason)"))
        if notifyUser { notify((L("已停止防睡眠：") + "\(reason)")) }
    }

    // Level 1：进程级断言（零权限）。-w 保证本进程一旦退出 caffeinate 自动回收，杜绝孤儿。
    //
    // 注意这里是 -is 而不是 -dis：-d 的语义是「阻止显示器睡眠」，与合盖熄屏
    // 直接冲突 —— 合盖时 macOS 正要关掉显示器，却被这条断言挡住，屏幕就一直
    // 亮着。我们要阻止的是**系统**睡眠（由 -i/-s 与 disablesleep 负责），
    // 显示器该不该灭由本程序用亮度主动控制。
    let c = Process()
    c.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
    c.arguments = ["-is", "-w", String(myPid)]
    try? c.run()
    caff = c

    // Level 2：系统级开关（需 helper），覆盖电池 + 合盖。失败则降级但必须让用户知道。
    var level = "caffeinate"
    if wantSystem {
        if let r = helperExec("on"), r == "on", systemSleepDisabled() {
            systemOn = true
            level = "system"
            log(L("nosleep: 系统级防睡眠已开启（disablesleep=1），覆盖电池与合盖"))
        } else {
            log(L("nosleep: 系统级防睡眠不可用，降级为 caffeinate（仅 AC 有效）"))
            notify(L("防睡眠降级为「仅电源适配器」：未安装提权助手，电池与合盖仍会睡眠"))
        }
    }

    try? String(myPid).write(toFile: nosleepPidFile, atomically: true, encoding: .utf8)
    try? "\(level)|\(Date().timeIntervalSince1970)|\(systemOn ? 1 : 0)"
        .write(toFile: nosleepStateFile, atomically: true, encoding: .utf8)
    log((L("nosleep 启动 pid=") + "\(myPid)" + L(" 层级=") + "\(level)"))

    // 合盖检测启用：SMC 读得到 MSLD 才开（笔记本）。台式机 / 虚拟机读不到，静默禁用。
    // LK_SIMULATE_LID_CLOSED 存在时无条件启用（冒烟测试驱动熄屏/恢复路径）。
    let simLid = ProcessInfo.processInfo.environment["LK_SIMULATE_LID_CLOSED"] != nil
    // 「合盖后黑屏」是独立开关：关掉时机器照样不睡，只是不再主动熄屏
    // （个别机型熄屏后亮度回不来，这条就是退路）。
    let blackoutOn = loadConfig().lidBlackout
    if !blackoutOn && !simLid {
        log(L("lid: 设置中已关闭「合盖时熄灭内屏」，本次只保持机器运行，不干预屏幕亮度"))
        lidSMC.close()
    } else if lidSMC.open(), lidSMC.lidClosed() != nil {
        lidMonitorOn = true
        let nowClosed = lidSMC.lidClosed() == true
        log((L("lid: SMC 合盖检测已启用（当前：") + "\(nowClosed ? L("已合盖") : L("开盖"))" + L("）")))
        if nowClosed {
            // 以合盖状态启动（如重启自动恢复时盖子已合上）：直接按合盖处理，
            // 不等轮询，避免「启动即合盖」的窗口期屏幕继续亮着
            lidCloseStreak = 2
            checkLid()
        }
    } else if simLid {
        lidMonitorOn = true
        log((L("lid: 测试模式（LK_SIMULATE_LID_CLOSED=") + "\(ProcessInfo.processInfo.environment["LK_SIMULATE_LID_CLOSED"] ?? "")" + L("）")))
    } else {
        log(L("lid: 无法读取 SMC 合盖状态（台式机/虚拟机属正常），合盖熄屏已禁用"))
        lidSMC.close()
    }

    // 合盖时 macOS 会走一遍「尝试睡眠 → 被 disablesleep 拦下 → 唤醒」的流程。
    // 这期间用户空间定时器被冻结，系统会重新点亮内屏，而等它醒过来时我们的
    // Timer 早已错过合盖那一刻。所以必须监听唤醒通知，醒来的第一时间重新判断
    // 并补上熄屏 —— 这正是「合盖后屏幕又亮了」的根因。
    lidWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { _ in
        guard lidMonitorOn, !stopped else { return }
        log(L("lid: 系统已唤醒，重新检查合盖状态"))
        checkLid(immediate: true)
    }

    for sig in [SIGTERM, SIGINT, SIGHUP] { signal(sig) { _ in nosleepStopFlag = true } }

    let poll = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
        if nosleepStopFlag { stop(L("收到退出信号"), notifyUser: false); exit(0) }
        checkLid()
    }
    RunLoop.main.add(poll, forMode: .common)

    // 电量守卫：合盖 + 电池 + 不睡眠是最容易耗尽电量的组合，机器在包里发热直到没电。
    // 所以电量下限对防睡眠同样强制生效（与关屏共用同一阈值）。
    if cfg.batteryFloor > 0 {
        let g = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            let b = batteryStatus()
            guard b.onBattery, b.discharging, b.percent <= cfg.batteryFloor else { return }
            let m = (L("电量 ") + "\(b.percent)" + L("% 已达下限 ") + "\(cfg.batteryFloor)" + L("%，自动停止防睡眠"))
            log(m); clearLidAwake(); stop(m, notifyUser: true); exit(0)
        }
        RunLoop.main.add(g, forMode: .common)
    }

    if let t = timeout, t > 0 {
        Timer.scheduledTimer(withTimeInterval: t, repeats: false) { _ in
            log((L("nosleep: 超时 ") + "\(Int(t))" + "s"))
            clearLidAwake()
            stop((L("已到设定时长 ") + "\(Int(t))" + L(" 秒")), notifyUser: true); exit(0)
        }
    }
    runAppLoop()
}

/// 合盖模式的持久标志。凡防睡眠自动结束（电量 / 超时 / 手动 off）都必须清除，
/// 否则菜单栏 App 会在下次启动时把它当作仍然想要的模式重新拉起。
func clearLidAwake() {
    var c = loadConfig()
    if c.lidAwake { c.lidAwake = false; saveConfig(c) }
}

/// fork 自身启动 nosleep-daemon 并等待确认（stdio 必须全部丢弃，
/// 否则继承父进程管道会让父进程退出后子进程写失败）。
func spawnNosleepDaemon(wantSystem: Bool, timeout: TimeInterval?) -> (pid: Int32, info: NosleepInfo)? {
    var a = ["nosleep-daemon"]
    if wantSystem { a.append("--system") }
    if let t = timeout { a += ["--timeout", String(t)] }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exePath)
    p.arguments = a
    p.standardOutput = nil; p.standardError = nil; p.standardInput = nil
    do { try p.run() } catch {
        FileHandle.standardError.write((L("启动防睡眠守护进程失败: ") + "\(error)" + "\n").data(using: .utf8)!)
        return nil
    }
    _ = waitUntil(timeout: 5.0) { nosleepPid() != nil }
    if let pid = nosleepPid(), let info = nosleepInfo() { return (pid, info) }
    return nil
}

// 常用键位名（仅用于展示）
let keyTable: [(String, Int64)] = [    ("A", 0), ("B", 11), ("C", 8), ("D", 2), ("E", 14), ("F", 3), ("G", 5), ("H", 4),
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
    return s.isEmpty ? L("（无修饰键）") : s
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
        guard st == noErr else { log((L("热键事件处理器安装失败 status=") + "\(st)")); return }
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
        log((L("全局热键已注册 ") + "\(modsText(modFlags))" + "\(keyName(keyCode))" + L("（Carbon 链路，无需授权）")))
    } else if st == OSStatus(eventHotKeyExistsErr) {
        log((L("热键注册失败 ") + "\(modsText(modFlags))" + "\(keyName(keyCode))" + L("：组合已被其他 App 占用（lidkeep config --mods ... --key ... 换一个）")))
    } else {
        log((L("热键注册失败 ") + "\(modsText(modFlags))" + "\(keyName(keyCode))" + " status=" + "\(st)"))
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
    recoverStaleNosleep()   // 上次异常退出遗留的 disablesleep 必须先复位
    // DisplayServices 不可用时，黑屏根本不会发生——必须明确报错，不能让命令「成功」但屏幕还亮着
    guard dsAvailable else {
        let m = L("无法访问 DisplayServices 私有框架，亮度控制不可用（本 macOS 可能已移除它）")
        try? m.write(toFile: rejectFile, atomically: true, encoding: .utf8)
        let errBody: String
        if L10n.isEN {
            errBody = """
            Error: \(m)
            This tool needs that framework to set brightness to 0. Please report your macOS version at
            https://github.com/Mihooni/lidkeep/issues
            """
        } else {
            errBody = """
            错误：\(m)
            本工具依赖该框架把亮度置 0 实现关屏。请在
            https://github.com/Mihooni/lidkeep/issues 反馈你的系统版本。
            """
        }
        FileHandle.standardError.write(errBody.data(using: .utf8)!)
        exit(1)
    }
    // 电量下限：电池供电时拒绝进入黑屏。黑屏 + 阻止睡眠的组合最容易让人忘记，
    // 一旦耗尽电池，未保存的工作会随之丢失。
    if cfg.batteryFloor > 0 {
        let b = batteryStatus()
        if b.onBattery && b.discharging && b.percent <= cfg.batteryFloor {
            let m = (L("电量 ") + "\(b.percent)" + L("% 低于下限 ") + "\(cfg.batteryFloor)" + L("%，已取消关屏（避免耗尽电池）"))
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
    log((L("daemon 启动 pid=") + "\(ProcessInfo.processInfo.processIdentifier)" + L(" 原亮度=") + "\(saved)"))

    // auto-nosleep：黑屏期间同时阻止系统睡眠。系统级开关（disablesleep）是持久的，
    // 必须在恢复显示时显式复位，否则合盖永远不睡、放在包里一直耗电。
    var nosleepSystemOn = false
    if cfg.autoNosleep, helperInstalled(),
       let r = helperExec("on"), r == "on", systemSleepDisabled() {
        nosleepSystemOn = true
        // 写状态标记：进程被 SIGKILL 时，下次启动 recoverStaleNosleep 能据此复位 disablesleep
        try? "system|\(Date().timeIntervalSince1970)|1"
            .write(toFile: nosleepStateFile, atomically: true, encoding: .utf8)
        log(L("nosleep: 关屏联动已开启系统级防睡眠（覆盖电池与合盖）"))
    }
    let caff = Process()
    caff.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
    // -w 自身 pid：本进程一旦退出（哪怕被 SIGKILL），caffeinate 也会自动退出，
    // 杜绝残留的孤儿 caffeinate 继续持有「禁止显示器睡眠」断言。
    // auto-nosleep 时升级为 -dis：-s 阻止系统睡眠（仅 AC 有效，电池由 helper 覆盖）。
    caff.arguments = [cfg.autoNosleep ? "-dis" : "-di",
                      "-w", String(ProcessInfo.processInfo.processIdentifier)]
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
        if nosleepSystemOn {
            _ = helperExec("off"); nosleepSystemOn = false
            try? fm.removeItem(atPath: nosleepStateFile)
            log(L("nosleep: 已复位 disablesleep=0"))
        }
        log((L("恢复亮度 ") + "\(restoreTarget)" + L("，结束 caffeinate")))
        caff.terminate()
        // 恢复失败绝不能就此退出：那样屏幕会永久黑着，而用户没有任何自救手段
        // （热键已随进程消亡）。失败就留在原地持续重试，直到亮度真的回来。
        if !restoreBrightness(restoreTarget) {
            log(L("错误：亮度恢复失败，转入持续重试（屏幕必须亮回来）"))
            notify(L("亮度恢复失败，正在持续重试"))
            let rt = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                if restoreBrightness(restoreTarget) {
                    log((L("重试成功，亮度已恢复 ") + "\(restoreTarget)"))
                    exit(0)
                }
            }
            RunLoop.main.add(rt, forMode: .common)
            return
        }
        try? fm.removeItem(atPath: pidFile)
        try? fm.removeItem(atPath: stateFile)
        exit(0)
    }

    // SIGTERM/SIGINT 只置标志，由下方 Timer 在主线程安全收尾
    cliSignalTerm = false
    for sig in [SIGTERM, SIGINT, SIGHUP] { signal(sig) { _ in cliSignalTerm = true } }
    let sigTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
        if cliSignalTerm { log(L("收到终止信号")); cleanup() }
    }
    RunLoop.main.add(sigTimer, forMode: .common)

    installHotkey(keyCode: keyCode, modFlags: cfg.modFlags) { log(L("热键触发")); cleanup() }

    if let t = timeout {
        Timer.scheduledTimer(withTimeInterval: t, repeats: false) { _ in log(L("超时自动恢复")); cleanup() }
    }
    // 黑屏期间持续监控电量：跌破下限就自动恢复，别等电池耗尽才被发现
    if cfg.batteryFloor > 0 {
        let bt = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            guard !restored else { return }
            let b = batteryStatus()
            guard b.onBattery && b.discharging, b.percent <= cfg.batteryFloor else { return }
            let m = (L("电量 ") + "\(b.percent)" + L("% 已达下限 ") + "\(cfg.batteryFloor)" + L("%，自动恢复显示"))
            log(m); notify(m)
            cleanup()
        }
        RunLoop.main.add(bt, forMode: .common)
    }
    runAppLoop()
}

// MARK: - 形态二：常驻服务（热键 / 信号 切换开关）
func runService(keyCode: Int64) -> Never {
    var cfg = loadConfig()
    let myPid = ProcessInfo.processInfo.processIdentifier
    // 互斥：已有存活常驻服务（CLI daemon 或菜单栏 App）时拒绝启动，避免双服务抢状态
    if let other = servicePid(), other != myPid {
        log((L("service 拒绝启动 pid=") + "\(myPid)" + L("：已有常驻服务 pid=") + "\(other)" + L(" 在运行")))
        FileHandle.standardError.write((L("已有常驻服务在运行 (pid ") + "\(other)" + L(")，本实例退出\n")).data(using: .utf8)!)
        exit(1)
    }
    try? String(myPid).write(toFile: serviceFile, atomically: true, encoding: .utf8)
    log((L("service 启动 pid=") + "\(myPid)"))

    // 自愈：上次异常退出遗留的黑屏状态
    if let s = try? String(contentsOfFile: stateFile, encoding: .utf8),
       let v = Float(s.trimmingCharacters(in: .whitespacesAndNewlines)), v > 0.001 {
        log((L("发现遗留黑屏状态，自愈恢复到 ") + "\(v)"))
        restoreBrightness(v)
    }
    try? fm.removeItem(atPath: stateFile)
    recoverStaleNosleep()   // 上次异常退出遗留的 disablesleep 必须先复位

    var blacked = false
    var saved: Float = 0.5
    var caff: Process?
    var nosleepSystemOn = false   // 关屏联动开启的系统级防睡眠（恢复时必须复位）
    var pinTimer: Timer?
    var timeoutTimer: Timer?     // 兜底：热键失效/被占用时也能自动恢复
    var battTimer: Timer?        // 黑屏期间的电量守卫
    var restoreRetry: Timer?     // 亮度恢复失败后的持续重试（屏幕不能就此黑着）
    var configMtime: Date?       // config.json 被改动时热重载（CLI 与 App 行为一致）

    func restore() {
        guard blacked else { return }
        blacked = false
        pinTimer?.invalidate(); pinTimer = nil
        timeoutTimer?.invalidate(); timeoutTimer = nil
        battTimer?.invalidate(); battTimer = nil
        restoreRetry?.invalidate(); restoreRetry = nil
        let target = cfg.restoreFixed ?? saved
        log((L("service 恢复显示 ") + "\(target)"))
        // 恢复失败不能就此罢休：屏幕会一直黑着，而常驻服务本身还在运行，
        // 用户很难想到要杀进程。必须持续重试直到真的亮回来。
        if !restoreBrightness(target) {
            log(L("错误：亮度恢复失败，转入持续重试"))
            notify(L("亮度恢复失败，正在持续重试"))
            let rt = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { t in
                if restoreBrightness(target) {
                    log((L("重试成功，亮度已恢复 ") + "\(target)"))
                    t.invalidate(); restoreRetry = nil
                }
            }
            RunLoop.main.add(rt, forMode: .common)
            restoreRetry = rt
        }
        if nosleepSystemOn {
            _ = helperExec("off"); nosleepSystemOn = false
            try? fm.removeItem(atPath: nosleepStateFile)
            log(L("nosleep: 已复位 disablesleep=0"))
        }
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
    /// 热键动作单独抽出来：配置热重载后重新注册时复用同一份行为，避免两处逻辑分叉
    func hotkeyAction() {
        log(L("热键触发"))
        if blacked { restore() } else { _ = blackout() }
    }

    /// 兜底超时 + 电量守卫。抽成函数以便配置热重载后按新值重排。
    func scheduleGuards() {
        timeoutTimer?.invalidate(); timeoutTimer = nil
        if cfg.timeout > 0 {
            let tt = Timer.scheduledTimer(withTimeInterval: cfg.timeout, repeats: false) { _ in
                log((L("兜底超时 ") + "\(Int(cfg.timeout))" + L("s，自动恢复")))
                restore()
            }
            RunLoop.main.add(tt, forMode: .common)
            timeoutTimer = tt
        }
        battTimer?.invalidate(); battTimer = nil
        if cfg.batteryFloor > 0 {
            let bt = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
                guard blacked else { return }
                let b = batteryStatus()
                guard b.onBattery && b.discharging, b.percent <= cfg.batteryFloor else { return }
                let m = (L("电量 ") + "\(b.percent)" + L("% 已达下限 ") + "\(cfg.batteryFloor)" + L("%，自动恢复显示"))
                log(m); notify(m)
                restore()
            }
            RunLoop.main.add(bt, forMode: .common)
            battTimer = bt
        }
    }

    /// config.json 被改动（含菜单栏 App 或 CLI 修改）时自动重载，无需重启服务。
    /// 与菜单栏 App 行为保持一致，否则用户改完配置会困惑「为什么没生效」。
    func reloadConfigIfChanged() {
        guard let a = try? fm.attributesOfItem(atPath: configFile),
              let m = a[.modificationDate] as? Date else { return }
        if let old = configMtime, m > old {
            let n = loadConfig()
            let keyChanged = n.keyCode != cfg.keyCode || n.modFlags != cfg.modFlags
            cfg = n
            if keyChanged { installHotkey(keyCode: cfg.keyCode, modFlags: cfg.modFlags, fire: hotkeyAction) }
            if blacked { scheduleGuards() }
            log((L("配置已自动重载 热键=") + "\(modsText(cfg.modFlags))" + "\(keyName(cfg.keyCode))"))
        }
        configMtime = m
    }

    /// 返回 false = 没能进入黑屏（亮度接口不可用或电量过低）。调用方必须据此提示用户，
    /// 否则会出现「命令看起来成功、屏幕其实还亮着」的静默失败。
    @discardableResult
    func blackout() -> Bool {
        guard !blacked else { return true }
        restoreRetry?.invalidate(); restoreRetry = nil
        guard dsAvailable else {
            return reject(L("亮度接口不可用（DisplayServices 缺失），无法关屏"))
        }
        // 电量下限：关屏 + 阻止睡眠的组合让人最容易忘记，耗尽电池会带走未保存的工作
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
        if !setBrightness(0.0) { log(L("警告：首次设置亮度 0 失败")) }
        let c = Process()
        c.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        // -w 自身 pid：本进程退出后 caffeinate 自动退出，杜绝孤儿断言残留。
        // auto-nosleep 时升级为 -dis（-s 仅 AC 有效，电池与合盖由 helper 系统级开关覆盖）。
        c.arguments = [cfg.autoNosleep ? "-dis" : "-di", "-w", String(myPid)]
        try? c.run()
        caff = c
        if cfg.autoNosleep, helperInstalled(),
           let r = helperExec("on"), r == "on", systemSleepDisabled() {
            nosleepSystemOn = true
            // 状态标记：本进程被 SIGKILL 时，recoverStaleNosleep 据此复位 disablesleep
            try? "system|\(Date().timeIntervalSince1970)|1"
                .write(toFile: nosleepStateFile, atomically: true, encoding: .utf8)
            log(L("nosleep: 关屏联动已开启系统级防睡眠（覆盖电池与合盖）"))
        }
        let t = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            if blacked { setBrightness(0.0) }
        }
        RunLoop.main.add(t, forMode: .common)
        pinTimer = t
        scheduleGuards()
        log((L("service 进入黑屏，原亮度 ") + "\(saved)" + L("，兜底 ") + "\(Int(cfg.timeout))" + L("s，电量下限 ") + "\(cfg.batteryFloor)" + "%"))
        return true
    }

    func shutdown() {
        restore()
        try? fm.removeItem(atPath: serviceFile)
        exit(0)
    }

    installHotkey(keyCode: keyCode, modFlags: cfg.modFlags, fire: hotkeyAction)

    // 信号：CLI 用 SIGUSR1(关)/SIGUSR2(开)/SIGTERM(退出)，经命令文件 + 标志双通道。
    // 传统 handler 置位全局标志，主循环 Timer 轮询执行（AppKit 下 GCD signal source 不可靠）。
    // 菜单栏 App 会忽略信号、只认命令文件；本 CLI 服务两者都认。
    cliSignalOff = false; cliSignalOn = false; cliSignalTerm = false
    signal(SIGUSR1) { _ in cliSignalOff = true }
    signal(SIGUSR2) { _ in cliSignalOn = true }
    signal(SIGTERM) { _ in cliSignalTerm = true }
    signal(SIGINT)  { _ in cliSignalTerm = true }
    let sigTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
        reloadConfigIfChanged()
        if cliSignalOff { cliSignalOff = false; log(L("收到 SIGUSR1")); blackout() }
        if cliSignalOn  { cliSignalOn = false;  log(L("收到 SIGUSR2")); restore() }
        if cliSignalTerm { log(L("收到终止信号")); shutdown() }
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
        log((L("service.pid 中的 pid=") + "\(pid)" + L(" 已不属于 lidkeep（pid 被复用），清理陈旧记录")))
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
        log((L("daemon.pid 中的 pid=") + "\(pid)" + L(" 已不属于 lidkeep（pid 被复用），清理陈旧记录")))
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

/// 无常驻服务时启动一次性 daemon（关屏）。off 与 toggle 共用，避免两条路径行为分叉。
func startOneShotDaemon(extra: [String]) -> Int32 {
    var dargs = ["daemon"]
    dargs.append(contentsOf: extra)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exePath)
    p.arguments = dargs
    p.standardOutput = nil; p.standardError = nil; p.standardInput = nil
    do { try p.run() } catch {
        FileHandle.standardError.write((L("启动失败: ") + "\(error)" + "\n").data(using: .utf8)!)
        return 1
    }
    _ = waitUntil(timeout: 3.0) { daemonRunning() != nil }
    if let r = daemonRunning() {
        print((L("已进入黑屏模式 pid=") + "\(r.pid)" + L(" 原亮度=") + "\(r.brightness)"))
        print((L("恢复方式: 热键 ") + "\(modsText(loadConfig().modFlags))" + "\(keyName(loadConfig().keyCode))" + L("  /  lidkeep on  /  远程执行同一命令")))
        return 0
    }
    if let reason = rejectReason() {
        FileHandle.standardError.write((L("未能关屏：") + "\(reason)" + "\n").data(using: .utf8)!)
        return 1
    }
    print((L("启动失败，请查看 ") + "\(logPath)"))
    return 1
}

/// 父进程已经消失的 caffeinate —— 真的孤儿（正常 caffeinate -w 会随父进程自动退出）。
/// 刻意不把「父进程不是 lidkeep」算作孤儿：用户自己起的 caffeinate 不该被误报。
func orphanCaffeinate() -> [Int32] {
    guard let out = runCapture("/usr/bin/pgrep", ["-x", "caffeinate"]) else { return [] }
    var res: [Int32] = []
    for tok in out.split(separator: "\n") {
        guard let pid = Int32(tok.trimmingCharacters(in: .whitespaces)) else { continue }
        guard let pp = runCapture("/bin/ps", ["-o", "ppid=", "-p", String(pid)]),
              let ppid = Int32(pp.trimmingCharacters(in: .whitespaces)) else { continue }
        if kill(ppid, 0) != 0 { res.append(pid) }
    }
    return res
}

/// 综合自检：把「能不能关屏、谁在跑、有没有残留」一次性摆出来。
/// 退出码 0 = 无致命问题，1 = 存在必须修复的问题（供脚本与 CI 使用）。
struct PowerAssertion {
    var kind: String      // 断言类型，如 NoIdleSleepAssertion
    var pid: Int32
    var name: String      // 持有者自报的断言名
    var elapsed: String   // 已持有时长
    var ours: Bool
}

/// 取正则捕获组。pmset 输出没有稳定字段数，只能按模式抓。
func capture(_ s: String, _ pattern: String, group: Int = 1) -> String? {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
    let ns = s as NSString
    guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
          m.numberOfRanges > group, m.range(at: group).location != NSNotFound else { return nil }
    return ns.substring(with: m.range(at: group))
}

/// 断言持有者是不是我们拉起来的。
///
/// caffeinate 的断言名恒为 "caffeinate command-line tool"，与任何第三方 caffeinate
/// 完全无法区分（正如 WorkBuddy 与小米互联服务的断言都叫 "Electron"）。因此改从
/// 亲缘关系判定：父进程是 lidkeep 家族即视为本程序持有。
func assertionOwnerIsOurs(_ pid: Int32) -> Bool {
    guard let pps = runCapture("/bin/ps", ["-o", "ppid=", "-p", String(pid)]),
          let ppid = Int32(pps.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
    let cmd = runCapture("/bin/ps", ["-o", "command=", "-p", String(ppid)]) ?? ""
    return cmd.contains("lidkeep") || cmd.contains("LidKeep")
}

/// 当前系统里所有「阻止睡眠」的断言持有者 —— 用户问「谁不让我的 Mac 睡」时的唯一权威答案。
func powerAssertions() -> [PowerAssertion] {
    guard let out = runCapture("/usr/bin/pmset", ["-g", "assertions"]) else { return [] }
    var res: [PowerAssertion] = []
    for rawLine in out.split(separator: "\n") {
        let s = String(rawLine)
        // 行形如: pid 32344(caffeinate): [0x0000...] 08:04:53 PreventUserIdleSystemSleep named: "..."
        //        时长字段可选，因此不能按下标取，只能扫 token。
        guard let pidStr = capture(s, #"pid (\d+)\("#), let pid = Int32(pidStr),
              let mark = s.range(of: "]") else { continue }
        let tail = String(s[mark.upperBound...])
        let toks = tail.split(whereSeparator: { $0 == " " || $0 == "\t" }).filter { !$0.isEmpty }
        var elapsed = ""
        var kind = ""
        for t in toks {
            if t.contains(":") && t.allSatisfy({ $0.isNumber || $0 == ":" }) && elapsed.isEmpty {
                elapsed = String(t); continue
            }
            if kind.isEmpty, t.allSatisfy({ $0.isLetter || $0.isNumber }) { kind = String(t) }
        }
        guard !kind.isEmpty else { continue }
        let name = capture(s, ##"named: "(.*)""##) ?? ""
        res.append(PowerAssertion(kind: kind, pid: pid, name: name, elapsed: elapsed,
                                  ours: assertionOwnerIsOurs(pid)))
    }
    return res
}
func runDoctor() -> Int32 {
    var errors: [String] = []
    var warns: [String] = []

    print((L("LidKeep 诊断 —— v") + "\(LK_VERSION)" + " (" + "\(LK_COMMIT)" + ")"))
    print((L("系统: ") + "\(ProcessInfo.processInfo.operatingSystemVersionString)"))

    print(L("\n【关屏能力】"))
    if dsAvailable {
        print((L("  ✅ 亮度接口 DisplayServices 可用，当前亮度 ") + "\(readBrightness())"))
    } else {
        errors.append(L("DisplayServices 不可用"))
        print(L("  ❌ 亮度接口不可用：本 macOS 可能已移除该私有框架，关屏功能整体失效"))
    }
    for id in onlineDisplays() {
        var v: Float = -1
        var ok = false
        if let h = dsHandle, let p = dlsym(h, "DisplayServicesGetBrightness") {
            ok = unsafeBitCast(p, to: DSGet.self)(id, &v) == 0
        }
        let tag = id == CGMainDisplayID() ? L("主显示器") : L("外接显示器")
        if ok {
            print(("  ✅ " + "\(tag)" + " id=" + "\(id)" + L(" 亮度 ") + "\(String(format: "%.3f", v))" + L("（可用亮度归零关闭）")))
        } else {
            warns.append((L("显示器 ") + "\(id)" + L(" 不支持软件亮度")))
            print(("  ⚠️  " + "\(tag)" + " id=" + "\(id)" + L(" 不支持软件亮度控制（HDMI/DVI/DP 外接屏常见），关屏时这块屏不会熄灭")))
        }
    }

    print((L("\n【配置】") + "\(configFile)"))
    let c = loadConfig()
    print((L("  热键 ") + "\(modsText(c.modFlags))" + "\(keyName(c.keyCode))" + L("　兜底 ") + "\(Int(c.timeout))" + L("s　"))
          + (L("电量下限 ") + "\(c.batteryFloor)" + L("%　关屏联动防睡眠 ") + "\(c.autoNosleep ? L("开") : L("关"))"))
    if c.modFlags == 0 {
        errors.append(L("热键无修饰键"))
        print(L("  ❌ 热键未带修饰键：系统不会注册，等于没有热键（lidkeep config --mods cmd,shift --key 0）"))
    }

    print(L("\n【常驻进程】"))
    if let pid = servicePid() {
        print((L("  ✅ 常驻服务运行中 pid=") + "\(pid)" + L("，") + "\(fm.fileExists(atPath: stateFile) ? L("当前黑屏中") : L("当前正常显示"))"))
    } else if let r = daemonRunning() {
        print((L("  ✅ 一次性黑屏 daemon pid=") + "\(r.pid)" + L("，待恢复亮度 ") + "\(r.brightness)"))
    } else {
        warns.append(L("无常驻进程"))
        print(L("  ⚠️  没有常驻进程：热键不可用，只能用 CLI 命令开关屏幕"))
        print(L("     → 启动菜单栏 App，或安装 CLI 常驻服务（lidkeep service install）"))
    }
    if fm.fileExists(atPath: serviceFile) && servicePid() == nil {
        warns.append(L("service.pid 陈旧"))
        print(L("  ⚠️  service.pid 指向已不存在的进程（上次异常退出），下次启动会自动清理"))
    }
    if fm.fileExists(atPath: stateFile), servicePid() == nil, daemonRunning() == nil {
        errors.append(L("残留黑屏状态"))
        print(L("  ❌ brightness.state 存在但没有任何进程维持黑屏 —— 上次崩溃的残留，屏幕可能仍黑着"))
        print(L("     → 执行 `lidkeep on` 恢复，或重启菜单栏 App 自动自愈"))
    }

    print(L("\n【开机自启】"))
    let bar = runProbe("com.lidkeep.bar")
    let agent = runProbe(label)
    print((L("  菜单栏 App: ") + "\(bar ? L("✅ 已注册") : L("未注册（设置里勾选「登录时启动」）"))"))
    print((L("  CLI 常驻服务: ") + "\(agent ? L("已注册") : L("未注册"))"))
    if bar && agent {
        warns.append(L("双常驻"))
        print(L("  ⚠️  两者同时注册会互相抢占状态，建议只保留菜单栏 App"))
    }

    print(L("\n【防睡眠】"))
    let b = batteryStatus()
    let pwrText = b.onBattery ? (L("电池 ") + "\(b.percent)" + "%" + (b.discharging ? L("（放电中）") : "")) : L("电源适配器")
    print(L("  电源: ") + pwrText)
    if helperInstalled() {
        print(L("  ✅ 提权助手已安装"))
        if let d = helperExec("detect") { print("     \(d)") }
        if helperOutdated() {
            warns.append(L("提权助手过旧"))
            print(L("  ⚠️  提权助手版本过旧：缺少「多持有者记账」，关屏联动与手动防睡眠会互相关掉对方"))
            print(L("     → 重新安装：lidkeep nosleep install-helper --force（需输入一次密码）"))
        }
        print((L("  系统级开关: ") + "\(systemSleepDisabled() ? L("开启（系统当前不会睡眠）") : L("关闭"))"))
        if let pid = nosleepPid() { print((L("  守护进程: 运行中 pid=") + "\(pid)")) }
        else if systemSleepDisabled() {
            if let app = thirdPartySleepHolder() {
                print((L("  ℹ️ 无本程序守护，但检测到远控软件 ") + "\(app)" + L(" 在运行——系统级开关由其持有以保持远程可用，属正常共存，无需处理")))
            } else {
                errors.append(L("disablesleep 残留"))
                print(L("  ❌ 没有守护进程在跑，系统级防睡眠却仍开着 —— 执行 `lidkeep nosleep off` 复位"))
            }
        }
    } else {
        print(L("  ⚠️  提权助手未安装：防睡眠仅在接电源时有效，电池供电与合盖仍会睡眠"))
        print(L("     → 一键安装：lidkeep nosleep setup"))
    }

    print(L("\n【电源断言】"))
    print(L("  下面列出此刻真正在阻止 Mac 睡眠的持有者（pmset -g assertions）。"))
    let asserts = powerAssertions()
    let mine = asserts.filter { $0.ours }
    let others = asserts.filter { !$0.ours }
    if mine.isEmpty {
        print(L("  · 本程序：未持有断言"))
    } else {
        for a in mine {
            print((L("  ✅ 本程序持有 pid=") + "\(a.pid)" + " " + a.kind
                   + (a.elapsed.isEmpty ? "" : (L("（已 ") + a.elapsed + L("）")))))
        }
    }
    if others.isEmpty {
        print(L("  ✅ 无第三方持有者"))
    } else {
        for a in others {
            let who = a.name.isEmpty ? L("（未署名）") : ("\"" + a.name + "\"")
            print((L("  ℹ️ 其他持有者 pid=") + "\(a.pid)" + " " + who + " — " + a.kind
                   + (a.elapsed.isEmpty ? "" : (L("（已 ") + a.elapsed + L("）")))))
        }
        print(L("     → 这些与本程序无关；若要让 Mac 恢复自动睡眠，需到对应应用里关闭。"))
    }
    // 断言是「真实状态」，配置只是「意图」：两者不符才是最该报出来的问题
    if (c.autoNosleep || c.lidAwake) && mine.isEmpty && !systemSleepDisabled() {
        warns.append(L("防睡眠未生效"))
        print(L("  ⚠️  配置要求防睡眠，但当前没有任何断言在生效中（黑屏时才会起断言）"))
    }

    print(L("\n【合盖检测】"))
    let lid = SMCLid()
    if lid.open(), let closed = lid.lidClosed() {
        print((L("  ✅ SMC 合盖检测可用（MSLD），当前：") + "\(closed ? L("已合盖") : L("开盖"))"))
        print(L("     防睡眠运行期间合盖会自动熄灭内屏，开盖自动恢复"))
        lid.close()
    } else {
        print(L("  ⚠️  SMC 合盖检测不可用（台式机 / 虚拟机属正常；合盖熄屏功能将自动禁用）"))
    }

    print(L("\n【残留进程】"))
    let orphans = orphanCaffeinate()
    if orphans.isEmpty {
        print(L("  ✅ 无孤儿 caffeinate"))
    } else {
        warns.append(L("孤儿 caffeinate"))
        for o in orphans {
            print(("  ⚠️  caffeinate pid=" + "\(o)" + L(" 的父进程已不存在，属崩溃残留：kill ") + "\(o)"))
        }
    }

    print("")
    if !errors.isEmpty {
        print((L("结论：❌ ") + "\(errors.count)" + L(" 个问题需要修复 —— ") + "\(errors.joined(separator: L("；")))"))
    } else if !warns.isEmpty {
        print((L("结论：⚠️  ") + "\(warns.count)" + L(" 项提示（不影响基本使用）")))
    } else {
        print(L("结论：✅ 一切正常"))
    }
    print((L("日志：") + "\(logPath)"))
    return errors.isEmpty ? 0 : 1
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
        if runProbe("com.lidkeep.bar") {
            print(L("检测到菜单栏 App（LidKeep）已注册为常驻服务。"))
            print(L("两者功能完全重叠，同时运行会互相抢占状态。"))
            print(L("→ 建议：直接使用菜单栏 App，无需安装本 CLI 服务。"))
            print(L("→ 如确实要改用 CLI 服务，请先在菜单栏设置中关闭「登录时启动」。"))
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
            print((L("常驻服务已启动 pid=") + "\(pid)"))
            print(L("  热键 ⌃⌥⌘B 直接开关；也可用 lidkeep off / on"))
            print((L("  开机自启，日志: ") + "\(serviceLog)"))
        } else {
            let plistBody: String
            if L10n.isEN {
                plistBody = """
                plist written: \(plistFile)
                but this environment cannot talk to launchd (common when invoked from a sandbox or automation).

                Run this manually in Terminal:
                  lidkeep service install

                Temporary resident mode (no launchd, lost after reboot):
                  nohup lidkeep daemon --service >/dev/null 2>&1 &
                """
            } else {
                plistBody = """
                plist 已写入: \(plistFile)
                但当前环境无法与 launchd 通信（被沙箱或自动化环境调用时常见）。

                请在「终端」里手动执行:
                  lidkeep service install

                临时常驻（不依赖 launchd，重启后失效）:
                  nohup lidkeep daemon --service >/dev/null 2>&1 &
                """
            }
            print(plistBody)
        }
    case "uninstall":
        sh("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        sh("/bin/launchctl", ["unload", plistFile])
        try? fm.removeItem(atPath: plistFile)
        try? fm.removeItem(atPath: serviceFile)
        print(L("常驻服务已卸载"))
    case "status":
        if let pid = servicePid() {
            print((L("常驻服务: 运行中 pid=") + "\(pid)" + L("，") + "\(fm.fileExists(atPath: stateFile) ? L("当前黑屏中") : L("当前正常显示"))"))
        } else {
            print(L("常驻服务: 未运行（用 `lidkeep service install` 启用）"))
        }
    default:
        print(L("用法: lidkeep service install | uninstall | status"))
    }

// MARK: - 防睡眠

case "nosleep-daemon":
    var wantSystem = false
    var nsTimeout: TimeInterval? = nil
    var i = 2
    while i < args.count {
        if args[i] == "--system" { wantSystem = true; i += 1 }
        else if args[i] == "--timeout", i + 1 < args.count { nsTimeout = Double(args[i + 1]); i += 2 }
        else { i += 1 }
    }
    runNosleepDaemon(timeout: nsTimeout, wantSystem: wantSystem)

case "nosleep":
    let sub = args.count > 2 ? args[2] : "status"
    switch sub {
    case "on":
        recoverStaleNosleep()
        if let pid = nosleepPid() {
            print((L("防睡眠已在运行 pid=") + "\(pid)" + L("（用 `lidkeep nosleep off` 关闭）")))
            exit(0)
        }
        var wantSystem = false
        var nsTimeout: TimeInterval? = nil
        var i = 3
        while i < args.count {
            if args[i] == "--system" { wantSystem = true; i += 1 }
            else if args[i] == "--timeout", i + 1 < args.count { nsTimeout = Double(args[i + 1]); i += 2 }
            else { i += 1 }
        }
        // 电量下限对防睡眠同样强制生效：合盖 + 电池 + 不睡是最容易耗尽电量的组合
        let cfg = loadConfig()
        if cfg.batteryFloor > 0 {
            let b = batteryStatus()
            if b.onBattery && b.discharging && b.percent <= cfg.batteryFloor {
                let m = (L("电量 ") + "\(b.percent)" + L("% 低于下限 ") + "\(cfg.batteryFloor)" + L("%，已取消开启防睡眠（避免耗尽电池）"))
                FileHandle.standardError.write((m + "\n").data(using: .utf8)!)
                log(m); notify(m)
                exit(1)
            }
        }
        if wantSystem && !helperInstalled() {
            print(L("提示：未安装提权助手，系统级防睡眠（电池 / 合盖）不可用。"))
            print(L("      本次按 Level 1 开启——仅在接电源时有效。"))
            print(L("      一键安装：`lidkeep nosleep setup`（会弹系统密码框）"))
            wantSystem = false
        }
        if let (pid, info) = spawnNosleepDaemon(wantSystem: wantSystem, timeout: nsTimeout) {
            print((L("防睡眠已开启 pid=") + "\(pid)"))
            print((L("  层级: ") + "\(info.level == "system" ? L("系统级（含电池与合盖）") : L("进程级（仅电源适配器）"))"))
            let b = batteryStatus()
            print((L("  电源: ") + "\(b.onBattery ? (L("电池 ") + "\(b.percent)" + "%") : L("电源适配器"))"))
            if let t = nsTimeout { print((L("  时长: ") + "\(Int(t))" + L(" 秒后自动停止"))) }
            print(L("  关闭: lidkeep nosleep off"))
        } else {
            print((L("已启动但未确认，请查看 ") + "\(logPath)"))
            exit(1)
        }

    case "setup":
        // 一键到位：装助手 → 开关屏联动 → 立即开启系统级防睡眠。每一步幂等，可重复执行。
        print(L("LidKeep 一键防睡眠"))
        if helperInstalled(), !helperOutdated() {
            print(L("① 提权助手已安装，跳过"))
        } else {
            print(helperOutdated()
                  ? L("① 提权助手版本过旧，重新安装（macOS 将弹出密码框）…")
                  : L("① 安装提权助手（macOS 将弹出密码框）…"))
            let (ok, out) = runAsAdmin(installHelperScript(NSUserName()))
            guard ok else {
                print((L("   安装失败: ") + "\(out)"))
                print(L("   提示：取消密码框会中止安装，可重新运行本命令。"))
                exit(1)
            }
            if helperOutdated() {
                print(L("   ⚠️ 助手安装后校验未通过（缺少持有者记账字段），安装可能未真正生效，请重新执行"))
                exit(1)
            }
            print(L("   完成（电池与合盖现已可防睡眠）"))
        }
        var sc = loadConfig()
        if sc.autoNosleep {
            print(L("② 关屏联动防睡眠：已开启"))
        } else {
            sc.autoNosleep = true
            saveConfig(sc)
            print(L("② 已开启「关屏时联动防睡眠」，恢复显示时自动复位"))
        }
        if servicePid() != nil {
            print(L("③ 常驻服务运行中：防睡眠将随黑屏自动联动，也可在菜单栏单独开关"))
        } else if nosleepPid() != nil {
            print(L("③ 防睡眠守护已在运行"))
        } else {
            var skipForBattery = false
            if sc.batteryFloor > 0 {
                let b = batteryStatus()
                skipForBattery = b.onBattery && b.discharging && b.percent <= sc.batteryFloor
                if skipForBattery {
                    print((L("③ 电量 ") + "\(b.percent)" + L("% 低于下限 ") + "\(sc.batteryFloor)" + L("%，跳过立即开启（黑屏联动在接电后仍会生效）")))
                }
            }
            if !skipForBattery {
                print(L("③ 立即开启系统级防睡眠…"))
                if let (pid, info) = spawnNosleepDaemon(wantSystem: true, timeout: nil) {
                    print((L("   已开启 pid=") + "\(pid)" + L("，层级: ") + "\(info.level == "system" ? L("系统级（含电池与合盖）") : L("进程级（仅电源适配器）"))"))
                } else {
                    print((L("   启动未确认，请查看 ") + "\(logPath)"))
                }
            }
        }
        print(L("✅ 一键配置完成。查看状态: lidkeep nosleep status"))

    case "off":
        // 无论守护是否在跑，「off」都表达「不再需要防睡眠」——持久标志必须一起清
        clearLidAwake()
        guard let pid = nosleepPid() else {
            // 守护进程没了但全局开关可能还开着——这是必须补救的残留态
            recoverStaleNosleep()
            print(L("防睡眠未在运行"))
            exit(0)
        }
        try? fm.removeItem(atPath: nosleepStateFile)
        kill(pid, SIGTERM)
        let gone = waitUntil(timeout: 5.0) { nosleepPid() == nil }
        print(gone ? L("防睡眠已关闭") : (L("已发送停止指令（5s 内未确认，请查看 ") + "\(logPath)" + L("）")))
        if !gone { exit(1) }

    case "status":
        let b = batteryStatus()
        let helper = helperInstalled()
        print((L("防睡眠: ") + "\(nosleepPid() != nil ? L("已开启") : L("未开启"))"))
        print((L("  合盖模式: ") + "\(loadConfig().lidAwake ? L("开（重启后自动恢复）") : L("关"))" + L("（菜单栏 App 可一键开关）")))
        if loadConfig().lidAwake, nosleepPid() != nil {
            let lid = SMCLid()
            if lid.open(), let closed = lid.lidClosed() {
                print((L("  内屏: ") + "\(closed ? L("已合盖（已自动熄灭）") : L("开盖"))" + L("，SMC 合盖检测正常")))
                lid.close()
            } else {
                print(L("  ⚠️ SMC 合盖检测不可用，合盖自动熄屏已禁用（台式机/虚拟机属正常）"))
            }
        }
        if let info = nosleepInfo() {
            let mins = Int(Date().timeIntervalSince(info.since) / 60)
            print((L("  层级: ") + "\(info.level == "system" ? L("系统级（含电池与合盖）") : L("进程级（仅电源适配器）"))"))
            print((L("  已持续: ") + "\(mins / 60)" + L(" 小时 ") + "\(mins % 60)" + L(" 分钟")))
        }
        let pwrText2 = b.onBattery ? (L("电池 ") + "\(b.percent)" + "%" + (b.discharging ? L("（放电中）") : "")) : L("电源适配器")
        print(L("  电源: ") + pwrText2)
        print((L("  提权助手: ") + "\(helper ? L("已安装") : L("未安装（电池 / 合盖防睡眠不可用）"))"))
        if helper {
            print((L("  系统级开关: ") + "\(systemSleepDisabled() ? L("开启（系统不会睡眠）") : L("关闭"))"))
        }
        if nosleepPid() == nil && helper && systemSleepDisabled() {
            if let app = thirdPartySleepHolder() {
                print((L("  ℹ️ 系统级开关由远控软件 ") + "\(app)" + L(" 持有（保持远程可用），与本程序共存，无需处理")))
            } else {
                print(L("  ⚠️ 检测到残留：守护进程不在，但系统级开关仍开启 —— 执行 `lidkeep nosleep off` 复位"))
            }
        }

    case "detect":
        // 只读探测，不改任何状态
        guard helperInstalled() else { print(L("提权助手未安装")); exit(1) }
        print(helperExec("detect") ?? L("探测失败（sudo 免密授权可能失效，重新安装助手可修复）"))

    case "install-helper":
        // --dry-run：把将要交给 root 执行的脚本完整打印出来供审计。
        // 提权操作必须可被用户检视，这是此类工具可信度的基础。
        if args.contains("--dry-run") {
            print(installHelperScript(NSUserName()))
            exit(0)
        }
        // 旧版助手缺少持有者记账，必须允许覆盖安装，否则用户永远升不了级
        if helperInstalled(), !args.contains("--force") {
            print(L("提权助手已安装，无需重复操作（加 --force 可覆盖安装 / 升级）"))
            exit(0)
        }
        print((L("将安装一个仅允许「") + "\(NSUserName())" + L("」以 root 执行 ") + "\(helperPath)"))
        print(L("（四个固定参数：on / off / status / detect）的授权条目。"))
        print(L("macOS 会弹出密码框，请输入你的登录密码。"))
        let (ok, out) = runAsAdmin(installHelperScript(NSUserName()))
        print(ok ? L("安装完成") : (L("安装失败: ") + "\(out)"))
        if ok {
            if let d = helperExec("detect") { print((L("disablesleep 支持情况: ") + "\(d)")) }
            // 装后校验：提权链路（密码框 + root 脚本）环节多，必须回读真实结果，
            // 不能让「命令成功但助手没装上」的静默失败溜过去
            if helperOutdated() {
                print(L("⚠️ 助手安装后校验未通过（缺少持有者记账字段），安装可能未真正生效，请重新执行"))
                exit(1)
            }
            if !systemSleepDisabled() { print(L("当前系统级防睡眠: 关闭（用 `lidkeep nosleep on --system` 开启）")) }
        }
        exit(ok ? 0 : 1)

    case "uninstall-helper":
        if !helperInstalled() { print(L("提权助手未安装")); exit(0) }
        // 先关掉正在运行的防睡眠，再卸载（顺序反了就再也无法复位）
        if let pid = nosleepPid() { kill(pid, SIGTERM); _ = waitUntil(timeout: 5.0) { nosleepPid() == nil } }
        let (ok, out) = runAsAdmin(uninstallHelperScript())
        try? fm.removeItem(atPath: nosleepPidFile)
        try? fm.removeItem(atPath: nosleepStateFile)
        print(ok ? L("已卸载提权助手，并已复位系统睡眠设置") : (L("卸载失败: ") + "\(out)"))
        exit(ok ? 0 : 1)

    case "write-assets":
        // 把内嵌资产导出到目录，供人工审计与 CI 一致性校验
        let dir = args.count > 3 ? args[3] : "."
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        do {
            try helperScript.write(toFile: dir + "/com.lidkeep.pmset", atomically: true, encoding: .utf8)
            try resetPlist.write(toFile: dir + "/com.lidkeep.nosleep.reset.plist", atomically: true, encoding: .utf8)
            print((L("已写出资产到 ") + "\(dir)"))
        } catch { print((L("写出失败: ") + "\(error)")); exit(1) }

    default:
        let nosleepHelp: String
        if L10n.isEN {
            nosleepHelp = """
            Usage: lidkeep nosleep <subcommand>
              setup                         All-in-one: install helper + link to blanking + start anti-sleep
              on [--system] [--timeout S]   Enable anti-sleep (--system covers battery and closed lid; needs the helper)
              off                           Disable anti-sleep and reset the system-level setting
              status                        Show level, battery and helper state
              install-helper                Install the privileged helper (one system password prompt, single script)
              uninstall-helper              Remove the helper and reset system sleep settings
            """
        } else {
            nosleepHelp = """
            用法: lidkeep nosleep <子命令>
              setup                         一键到位：装助手 + 开关屏联动 + 立即防睡眠
              on [--system] [--timeout 秒]   开启防睡眠（--system 覆盖电池与合盖，需先装助手）
              off                           关闭防睡眠，并复位系统级设置
              status                        查看层级、电量、助手安装状态
              install-helper                安装提权助手（弹系统密码框，仅授权单个脚本）
              uninstall-helper              卸载助手并复位系统睡眠设置
            """
        }
        print(nosleepHelp)
    }

case "config":
    var c = loadConfig()
    var i = 2
    while i < args.count {
        if args[i] == "--key", i + 1 < args.count {
            guard let k = Int64(args[i + 1]), (0...127).contains(k) else {
                print((L("错误：--key 需要 0-127 的虚拟键码，收到: ") + "\(args[i + 1])")); exit(1)
            }
            c.keyCode = k; i += 2
        }
        else if args[i] == "--timeout", i + 1 < args.count {
            guard let t = Double(args[i + 1]), t >= 0 else {
                print((L("错误：--timeout 需要非负秒数（0 = 不启用兜底），收到: ") + "\(args[i + 1])")); exit(1)
            }
            c.timeout = t; i += 2
        }
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
            if v == "original" || v == "auto" {
                c.restoreFixed = nil
            } else if let f = Float(v), (0...1).contains(f) {
                c.restoreFixed = f
            } else {
                print((L("错误：--restore 需要 original（关屏前亮度）或 0.0-1.0 的数值，收到: ") + "\(args[i + 1])"))
                exit(1)
            }
            i += 2
        }
        else if args[i] == "--battery", i + 1 < args.count {
            if let v = Int(args[i + 1]), (0...100).contains(v) {
                c.batteryFloor = v
            } else {
                print((L("错误：--battery 需要 0-100 的整数（0 = 不限制），收到: ") + "\(args[i + 1])")); exit(1)
            }
            i += 2
        }
        else if args[i] == "--battery-action", i + 1 < args.count {
            if let v = Int(args[i + 1]), (0...2).contains(v) {
                c.batteryAction = v
            } else {
                print((L("错误：--battery-action 需要 0 / 1 / 2（0=恢复屏幕，1=恢复并撤销防睡眠，2=只提醒），收到: ") + "\(args[i + 1])")); exit(1)
            }
            i += 2
        }
        else if args[i] == "--hotkey", i + 1 < args.count {
            let v = args[i + 1].lowercased()
            guard ["on", "off", "true", "false"].contains(v) else {
                print((L("错误：--hotkey 需要 on / off，收到: ") + "\(args[i + 1])")); exit(1)
            }
            c.hotkeyEnabled = (v == "on" || v == "true")
            i += 2
        }
        else if args[i] == "--auto-nosleep" { c.autoNosleep = true; i += 1 }
        else if args[i] == "--lang", i + 1 < args.count {
            let v = args[i + 1].lowercased()
            guard ["auto", "zh", "en"].contains(v) else {
                print((L("错误：--lang 需要 auto（跟随系统）/ zh / en，收到: ") + "\(args[i + 1])")); exit(1)
            }
            c.lang = v; i += 2
        }
        else if args[i] == "--no-auto-nosleep" { c.autoNosleep = false; i += 1 }
        else if args[i] == "--reset" { c = Config(); i += 1 }
        else { i += 1 }
    }
    // 热键必须带至少一个修饰键：Carbon RegisterEventHotKey 对无修饰键组合必定注册失败，
    // 存下来只会让热键静默失效（与菜单栏 App 的约束保持一致）。
    if args.count > 2 && c.modFlags == 0 {
        print(L("错误：全局热键必须包含至少一个修饰键，否则系统无法注册（会静默失效）。"))
        print(L("示例: lidkeep config --mods cmd,shift --key 0"))
        exit(1)
    }
    if args.count > 2 { saveConfig(c); print((L("配置已保存: ") + "\(configFile)")) }
    var m = ""
    if c.modFlags & MOD_CTRL  != 0 { m += "⌃" }
    if c.modFlags & MOD_ALT   != 0 { m += "⌥" }
    if c.modFlags & MOD_SHIFT != 0 { m += "⇧" }
    if c.modFlags & MOD_CMD   != 0 { m += "⌘" }
    print(L("  热键: ") + "\(m)\(keyName(c.keyCode))   (keyCode \(c.keyCode), mods \(c.modFlags))")
    print((L("  一次性模式超时: ") + "\(Int(c.timeout))" + L(" 秒（") + "\(String(format: "%.1f", c.timeout / 3600))" + L(" 小时，0 = 不限）")))
    print((L("  恢复亮度: ") + "\(c.restoreFixed.map { String(format: L("固定 %.0f%%"), $0 * 100) } ?? L("进入黑屏前的亮度"))"))
    print((L("  电量下限: ") + "\(c.batteryFloor > 0 ? ("\(c.batteryFloor)" + L("%（电池供电且放电时，低于此值拒绝关屏并自动恢复）")) : L("不限制"))"))
    let actName = c.batteryAction == 1 ? L("恢复屏幕并撤销防睡眠（回到原本的电池行为）")
                : c.batteryAction == 2 ? L("只提醒，不自动干预")
                : L("恢复屏幕，继续防睡眠")
    print((L("  电量触底动作: ") + "\(actName)"))
    print((L("  全局热键: ") + "\(c.hotkeyEnabled ? L("启用") : L("停用（只能从菜单栏点击）"))"))
    print((L("  关屏联动防睡眠: ") + "\(c.autoNosleep ? L("开（黑屏期间阻止系统睡眠，恢复显示时自动复位）") : L("关"))"))
    let langName = c.lang == "auto" ? L("跟随系统") : (c.lang == "zh" ? L("中文") : L("英文"))
    print((L("  界面语言: ") + "\(langName)" + L("（--lang auto/zh/en）")))
    print(L("  修改: lidkeep config --key 11 --mods ctrl,alt,cmd --timeout 43200 --battery 20 --restore original --auto-nosleep"))

case "off":
    if let pid = servicePid() {                      // 常驻模式：命令文件 + 信号双通道
        try? fm.removeItem(atPath: rejectFile)        // 先清掉上一次的拒绝记录
        try? "off".write(toFile: commandFile, atomically: true, encoding: .utf8)
        kill(pid, SIGUSR1)                            // 菜单栏 App 会忽略信号、只认命令文件
        // 轮询等待：要么进入黑屏（stateFile），要么被拒绝（rejectFile）
        let ok = waitUntil(timeout: 3.0) { fm.fileExists(atPath: stateFile) || fm.fileExists(atPath: rejectFile) }
        if let reason = rejectReason() {
            FileHandle.standardError.write((L("未能关屏：") + "\(reason)" + "\n").data(using: .utf8)!)
            exit(1)
        }
        print(ok
              ? (L("已进入黑屏（常驻服务 pid=") + "\(pid)" + L("）恢复: 热键或 lidkeep on"))
              : (L("已发送进入黑屏指令（3s 内未确认，请查看 ") + "\(logPath)" + L("）")))
        exit(0)
    }
    if let r = daemonRunning() { print((L("已在黑屏模式 (pid ") + "\(r.pid)" + L(")，原亮度 ") + "\(r.brightness)")); exit(0) }
    var extra: [String] = []                          // 一次性模式
    var i = 2
    while i < args.count { extra.append(args[i]); i += 1 }
    exit(startOneShotDaemon(extra: extra))

case "on":
    if let pid = servicePid() {
        try? "on".write(toFile: commandFile, atomically: true, encoding: .utf8)
        kill(pid, SIGUSR2)
        let ok = waitUntil(timeout: 3.0) { !fm.fileExists(atPath: stateFile) }
        print(ok ? L("已恢复显示") : (L("恢复指令已发送（3s 内仍在黑屏，请查看 ") + "\(logPath)" + L("）")))
        exit(0)
    }
    guard let r = daemonRunning() else { print(L("当前不在黑屏模式")); exit(0) }
    kill(r.pid, SIGTERM)
    _ = waitUntil(timeout: 3.0) { daemonRunning() == nil }
    print((L("已恢复显示，亮度 ") + "\(r.brightness)" + L("，当前实际亮度 ") + "\(readBrightness())"))

case "status":
    let cfg = loadConfig()
    let b = batteryStatus()
    let battText = b.onBattery
        ? (L("电池 ") + "\(b.percent)" + "%" + "\(b.discharging ? L("（放电中）") : "")")
        : L("已接电源")
    if !dsAvailable { print(L("⚠️  亮度接口不可用（DisplayServices 缺失），关屏功能将无法工作")) }
    if let pid = servicePid() {
        print((L("常驻服务运行中 pid=") + "\(pid)" + L("，") + "\(fm.fileExists(atPath: stateFile) ? L("黑屏中") : L("正常显示"))" + L("，当前亮度 ") + "\(readBrightness())"))
    } else if let r = daemonRunning() {
        print((L("一次性模式黑屏中 pid=") + "\(r.pid)" + L(" 待恢复亮度=") + "\(r.brightness)" + L(" 当前亮度 ") + "\(readBrightness())"))
    } else {
        print((L("正常模式（无常驻服务），当前亮度 ") + "\(readBrightness())"))
    }
    print((L("电源: ") + "\(battText)" + L("，电量下限 ") + "\(cfg.batteryFloor > 0 ? "\(cfg.batteryFloor)%" : L("不限"))"))

case "version":
    print("lidkeep \(LK_VERSION) (\(LK_COMMIT))")
    print("  macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    print((L("  二进制: ") + "\(exePath)"))
    print((L("  状态目录: ") + "\(base)"))

case "doctor":
    exit(runDoctor())

case "toggle":
    // 一条命令切换，便于绑定到快捷键工具 / 远程脚本，不必先判断当前状态
    if let pid = servicePid() {
        let before = fm.fileExists(atPath: stateFile)
        try? fm.removeItem(atPath: rejectFile)
        try? "toggle".write(toFile: commandFile, atomically: true, encoding: .utf8)
        kill(pid, SIGUSR1)                            // 菜单栏 App 认命令文件，信号仅用于唤醒
        let changed = waitUntil(timeout: 3.0) {
            fm.fileExists(atPath: stateFile) != before || fm.fileExists(atPath: rejectFile)
        }
        if let reason = rejectReason() {
            FileHandle.standardError.write((L("未能切换：") + "\(reason)" + "\n").data(using: .utf8)!)
            exit(1)
        }
        print(changed
              ? (fm.fileExists(atPath: stateFile) ? (L("已进入黑屏（常驻服务 pid=") + "\(pid)" + L("）")) : L("已恢复显示"))
              : (L("已发送切换指令（3s 内未确认，请查看 ") + "\(logPath)" + L("）")))
        exit(0)
    }
    if let r = daemonRunning() {
        kill(r.pid, SIGTERM)
        _ = waitUntil(timeout: 3.0) { daemonRunning() == nil }
        print((L("已恢复显示，亮度 ") + "\(r.brightness)"))
        exit(0)
    }
    exit(startOneShotDaemon(extra: []))

case "bright":
    if args.count > 2 {
        // 显式校验而不是默默 clamp：越界值说明用户搞错了单位（例如当成了百分比），
        // 静默改写成极值会让「设成 1.0 结果全黑」这类困惑无法追溯。
        guard let v = Float(args[2]) else {
            FileHandle.standardError.write((L("错误：亮度需要 0.0-1.0 的数值，收到: ") + "\(args[2])" + "\n").data(using: .utf8)!)
            exit(1)
        }
        guard (0...1).contains(v) else {
            FileHandle.standardError.write((L("错误：亮度必须在 0.0-1.0 之间，收到: ") + "\(args[2])" + "\n").data(using: .utf8)!)
            exit(1)
        }
        if setBrightness(v) { print((L("亮度 -> ") + "\(v)")) }
        else {
            FileHandle.standardError.write(L("设置亮度失败：亮度接口不可用或被系统拒绝（当前 macOS 可能已移除 DisplayServices）\n").data(using: .utf8)!)
            exit(1)
        }
    } else {
        let v = readBrightness()
        if v < 0 { print(L("读取亮度失败：亮度接口不可用")); exit(1) }
        print((L("当前亮度 ") + "\(v)"))
    }

default:
    let helpBody: String
    if L10n.isEN {
        helpBody = """
        lidkeep — turn the display off without putting the Mac to sleep.

          Recommended: the menu bar app (LidKeep.app), with a zero-permission hotkey. See the README.

        CLI usage:
          lidkeep service install             Install the resident service (launches at login, hotkey works)
          lidkeep service uninstall           Remove the resident service
          lidkeep off / on / toggle           Blank / restore / toggle
          lidkeep status                      Show state (including power source and battery)
          lidkeep doctor                      Full self-check: blanking, display control, processes, leftovers
          lidkeep version                     Print the version
          lidkeep config --key 11             View or change the hotkey, timeout, battery floor and interface language
          lidkeep bright [0.0-1.0]            Read or write brightness directly

          Without the resident service: lidkeep off [--timeout SECONDS] [--no-timeout]

        Anti-sleep (prevents system sleep; independent of blanking):
          lidkeep nosleep on                  Enable (process level: AC power only)
          lidkeep nosleep on --system         Enable (system level: covers battery and closed lid; needs the helper)
          lidkeep nosleep on --timeout 3600   Stop automatically after a duration
          lidkeep nosleep off / status        Disable / show level, battery and helper state
          lidkeep nosleep install-helper      Install the privileged helper (one system password prompt)
          lidkeep nosleep uninstall-helper    Remove the helper and reset system sleep settings

        Why the system level needs a helper: per its man page, caffeinate -s only works on AC power,
        so battery and closed-lid cases need pmset disablesleep, which requires root.
        The helper grants a single root:wheel script with four fixed arguments, and is never installed by default.

        Lid blackout: while anti-sleep runs, the daemon watches the SMC lid switch and turns the built-in
        display off automatically (external displays are untouched); brightness is restored when the lid
        opens, and also when the daemon stops — never leaving a black screen behind.

        Default hotkey: ⌃⌥⌘B (B = keyCode 11). Change it: lidkeep config --key 11 --mods ctrl,alt,cmd
        Hotkeys use the system-level Carbon path and need no permissions; if another app owns the combo it is logged.
        Without a hotkey you can still use: lidkeep on (including over SSH) / one-shot mode with a 12 h fallback
        Battery guard: blanking is refused below 20% on battery, and restored if it drops below while blanked (disable: config --battery 0)
        """
    } else {
        helpBody = """
        lidkeep —— 关屏但不睡眠（显示器熄灭，系统保持唤醒，远程可正常操控）

          推荐方式：菜单栏 App（LidKeep.app），热键零授权。见项目 README。

        CLI 用法:
          lidkeep service install            安装常驻服务（开机自启，热键直接开关）
          lidkeep service uninstall          卸载常驻服务
          lidkeep off / on / toggle          进入 / 退出 / 切换黑屏
          lidkeep status                     查看状态（含电源与电量）
          lidkeep doctor                     综合自检：关屏能力、显示器可控性、进程、残留
          lidkeep version                    查看版本
          lidkeep config --key 11            查看/修改热键、超时、电量下限、界面语言
          lidkeep bright [0.0-1.0]           直接读写亮度

          不用常驻服务时: lidkeep off [--timeout 秒] [--no-timeout]

        防睡眠（阻止系统睡眠，与关屏相互独立）:
          lidkeep nosleep on                 开启（进程级：仅在接电源时有效）
          lidkeep nosleep on --system        开启（系统级：覆盖电池供电与合盖，需助手）
          lidkeep nosleep on --timeout 3600  指定时长后自动停止
          lidkeep nosleep off / status       关闭 / 查看层级、电量、助手状态
          lidkeep nosleep install-helper     安装提权助手（弹系统密码框）
          lidkeep nosleep uninstall-helper   卸载助手并复位系统睡眠设置

        为什么系统级需要助手: caffeinate -s 的断言按 man page 明写「仅 AC 电源有效」，
        所以电池供电与合盖这两种场景，进程级断言无解，只能用 pmset disablesleep（需 root）。
        助手只授权单个 root:wheel 脚本的四个固定参数，且默认不安装。

        合盖熄屏: 防睡眠运行期间，守护进程经 SMC 检测合盖并自动熄灭内屏（外接屏不受
        影响），开盖自动恢复亮度；守护停止时也会恢复，不留黑屏残局。

        默认热键: ⌃⌥⌘B (B=keyCode 11)，修改: lidkeep config --key 11 --mods ctrl,alt,cmd
        热键走系统级全局热键（Carbon），不需要任何授权；若组合被其他 App 占用会写入日志。
        未注册热键时仍可用: lidkeep on（含远程 SSH）/ 一次性模式 12 小时超时兜底
        电量保护: 默认低于 20% 且使用电池时拒绝关屏，黑屏中跌破则自动恢复（config --battery 0 关闭）
        """
    }
    print(helpBody)
}
