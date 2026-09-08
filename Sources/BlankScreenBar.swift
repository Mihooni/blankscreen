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
let barPlist = home + "/Library/LaunchAgents/com.blankscreen.bar.plist"

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

    enum CodingKeys: String, CodingKey { case keyCode, modFlags, timeout, restoreFixed }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try c.decodeIfPresent(Int64.self, forKey: .keyCode) ?? 11
        modFlags = try c.decodeIfPresent(UInt64.self, forKey: .modFlags) ?? (MOD_CTRL | MOD_ALT | MOD_CMD)
        timeout = try c.decodeIfPresent(Double.self, forKey: .timeout) ?? 43200
        restoreFixed = try c.decodeIfPresent(Float.self, forKey: .restoreFixed)
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
    ("Space 空格", 49), ("Esc", 53), ("Return 回车", 36), ("Tab", 48)
]
func keyName(_ code: Int64) -> String { keyItems.first { $0.1 == code }?.0 ?? "keyCode \(code)" }
func modText(_ flags: UInt64) -> String {
    var s = ""
    if flags & MOD_CTRL  != 0 { s += "⌃" }
    if flags & MOD_ALT   != 0 { s += "⌥" }
    if flags & MOD_SHIFT != 0 { s += "⇧" }
    if flags & MOD_CMD   != 0 { s += "⌘" }
    return s.isEmpty ? "（无修饰键）" : s
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
    case noErr:                   return "已注册"
    case OSStatus(eventHotKeyExistsErr):      return "已被系统或其他 App 占用，请换一个组合"
    case OSStatus(eventHotKeyInvalidErr):     return "组合无效（全局热键需要至少一个修饰键）"
    default:                      return "注册失败（OSStatus \(st)）"
    }
}

// MARK: - 亮度读写（DisplayServices 私有框架）
let dsHandle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
typealias DSGet = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
typealias DSSet = @convention(c) (UInt32, Float) -> Int32

func readBrightness() -> Float {
    guard let h = dsHandle, let p = dlsym(h, "DisplayServicesGetBrightness") else { return -1 }
    let f = unsafeBitCast(p, to: DSGet.self)
    var v: Float = -1
    return f(CGMainDisplayID(), &v) == 0 ? v : -1
}
func setBrightness(_ v: Float) {
    guard let h = dsHandle, let p = dlsym(h, "DisplayServicesSetBrightness") else { return }
    _ = unsafeBitCast(p, to: DSSet.self)(CGMainDisplayID(), v)
}
func restoreBrightness(_ v: Float) { setBrightness(v); usleep(300_000); setBrightness(v) }

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
    var cmdTimer: Timer?
    var signalSources: [DispatchSourceSignal] = []
    var configMtime: Date? = nil
    var selfTesting = false
    var onStateChange: (() -> Void)?

    // MARK: 状态
    var isBlacked: Bool { fm.fileExists(atPath: stateFile) }

    func blackout() {
        guard !blacked else { return }
        let cur = max(readBrightness(), 0)
        saved = cur > 0.001 ? cur : saved
        try? String(saved).write(toFile: stateFile, atomically: true, encoding: .utf8)
        blacked = true
        let c = Process()
        c.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        c.arguments = ["-di"]
        try? c.run()
        caff = c
        setBrightness(0.0)
        let t = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            if self?.blacked == true { setBrightness(0.0) }
        }
        RunLoop.main.add(t, forMode: .common)
        pinTimer = t
        scheduleTimeout()
        blog("bar: 进入黑屏，原亮度 \(saved)")
        onStateChange?()
    }

    func restore() {
        guard blacked else { return }
        blacked = false
        pinTimer?.invalidate(); pinTimer = nil
        timeoutTimer?.invalidate(); timeoutTimer = nil
        let target = cfg.restoreFixed ?? saved
        blog("bar: 恢复显示 \(target)")
        restoreBrightness(target)
        caff?.terminate(); caff = nil
        try? fm.removeItem(atPath: stateFile)
        onStateChange?()
    }

    func toggle() { blacked ? restore() : blackout() }

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
            let which = out.contains("BlankScreenBar") ? "上一个 BlankScreenBar 实例" : "blankscreen daemon"
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
            if blacked { scheduleTimeout() }
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
    private var restorePop: NSPopUpButton!
    private var restoreSlider: NSSlider!
    private var restoreValueLabel: NSTextField!
    private var loginBtn: NSButton!
    private var permLabel: NSTextField!
    private var checkBtn: NSButton!

    private let timeoutChoices: [(String, Double)] = [
        ("不启用（一直保持黑屏）", 0),
        ("30 分钟", 1800), ("1 小时", 3600), ("2 小时", 7200),
        ("4 小时", 14400), ("8 小时", 28800), ("12 小时", 43200)
    ]

    func show() {
        if window == nil { window = build() }
        syncFromConfig()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 585),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "BlankScreen 设置"
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
        root.addArrangedSubview(section("恢复热键"))
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
        root.addArrangedSubview(row("按键", keyPop))

        hkLabel = NSTextField(labelWithString: "")
        hkLabel.font = .systemFont(ofSize: 12)
        hkLabel.textColor = .secondaryLabelColor
        root.addArrangedSubview(hkLabel)

        // —— 兜底超时
        root.addArrangedSubview(section("自动恢复兜底"))
        timeoutPop = NSPopUpButton(frame: .zero, pullsDown: false)
        timeoutPop.addItems(withTitles: timeoutChoices.map { $0.0 })
        timeoutPop.target = self; timeoutPop.action = #selector(onTimeoutChanged(_:))
        root.addArrangedSubview(row("黑屏后", timeoutPop))
        let tip = wrapLabel("热键失效时的安全网。设为「不启用」则一直保持黑屏，直到手动恢复或退出本程序。")
        root.addArrangedSubview(tip)

        // —— 恢复亮度
        root.addArrangedSubview(section("恢复后的亮度"))
        restorePop = NSPopUpButton(frame: .zero, pullsDown: false)
        restorePop.addItems(withTitles: ["恢复到关屏前的亮度", "固定为"])
        restorePop.target = self; restorePop.action = #selector(onRestoreModeChanged(_:))
        root.addArrangedSubview(row("策略", restorePop))

        let sliderRow = NSStackView(); sliderRow.orientation = .horizontal; sliderRow.spacing = 8
        restoreSlider = NSSlider(value: 50, minValue: 5, maxValue: 100, target: self, action: #selector(onSliderChanged(_:)))
        restoreSlider.widthAnchor.constraint(equalToConstant: 240).isActive = true
        restoreValueLabel = NSTextField(labelWithString: "50%")
        restoreValueLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true
        restoreValueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        sliderRow.addArrangedSubview(restoreSlider)
        sliderRow.addArrangedSubview(restoreValueLabel)
        root.addArrangedSubview(sliderRow)

        // —— 开机自启
        root.addArrangedSubview(section("启动"))
        loginBtn = NSButton(checkboxWithTitle: "登录时自动启动（菜单栏常驻）", target: self, action: #selector(onLoginToggled(_:)))
        root.addArrangedSubview(loginBtn)

        // —— 热键状态
        root.addArrangedSubview(section("热键状态"))
        permLabel = wrapLabel("")
        root.addArrangedSubview(permLabel)

        let btnRow = NSStackView(); btnRow.orientation = .horizontal; btnRow.spacing = 10
        checkBtn = NSButton(title: "运行自检", target: self, action: #selector(onCheck(_:)))
        btnRow.addArrangedSubview(checkBtn)
        root.addArrangedSubview(btnRow)

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
        hkLabel.stringValue = "当前: " + hotkeyText(cfg) + "　（设置即时生效）"
        timeoutPop.selectItem(at: timeoutChoices.firstIndex { $0.1 == cfg.timeout }
                              ?? timeoutChoices.firstIndex { $0.1 == 43200 }!)
        let fixed = cfg.restoreFixed
        restorePop.selectItem(at: fixed == nil ? 0 : 1)
        restoreSlider.isEnabled = fixed != nil
        restoreSlider.doubleValue = Double((fixed ?? 0.5) * 100)
        restoreValueLabel.stringValue = "\(Int(restoreSlider.doubleValue))%"
        loginBtn.state = isLoginItemEnabled() ? .on : .off
        refreshPerm()
    }
    private func refreshPerm() {
        let c = ctl.cfg
        permLabel.stringValue = ctl.hotkeyReady
            ? "\(hotkeyText(c))：✅ 已注册为系统全局热键。本程序走系统级热键链路，不需要「辅助功能 / 输入监控」授权，也不会因重装 App 而失效。"
            : "\(hotkeyText(c))：⚠️ \(carbonStatusText(ctl.lastHotkeyStatus))。请换一个组合（建议 ⇧⌘B 或 ⌃⌥⌘B）。"
    }

    // MARK: 事件
    @objc private func onHotkeyChanged(_ sender: Any?) {
        var flags: UInt64 = 0
        for (flag, b) in modBtns where b.state == .on { flags |= flag }
        // 系统全局热键必须带至少一个修饰键，否则 RegisterEventHotKey 会失败
        guard flags != 0 else {
            let a = NSAlert(); a.alertStyle = .warning
            a.messageText = "需要修饰键"
            a.informativeText = "系统级全局热键必须包含 ⌘ / ⌃ / ⌥ / ⇧ 中的至少一个，不能只用一个普通键。"
            a.addButton(withTitle: "好"); a.runModal()
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
        if ctl.blacked { ctl.scheduleTimeout() }
        hkLabel.stringValue = "当前: " + hotkeyText(cfg) + "　（设置即时生效）"
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
            a.messageText = "已写入配置，但未能注册到 launchd"
            a.informativeText = "请在「终端」中执行：\n\nlaunchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/\(barLabel).plist\n\n或在系统设置的「登录项」里手动添加 \(appPath)"
            a.addButton(withTitle: "好")
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
            b.toolTip = "BlankScreen —— 点击打开菜单"
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
                if let w = NSApp.windows.first(where: { $0.title == "BlankScreen 设置" }) {
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
        stateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        m.addItem(stateItem)
        m.addItem(.separator())
        toggleItem = NSMenuItem(title: "关闭显示器", action: #selector(toggle(_:)), keyEquivalent: "")
        toggleItem.target = self
        m.addItem(toggleItem)
        m.addItem(.separator())
        let set = NSMenuItem(title: "设置…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        set.target = self; m.addItem(set)
        let chk = NSMenuItem(title: "热键自检", action: #selector(checkHotkey(_:)), keyEquivalent: "")
        chk.target = self; m.addItem(chk)
        permItem = NSMenuItem(title: "", action: #selector(openAuthorizeFromMenu(_:)), keyEquivalent: "")
        permItem.target = self; m.addItem(permItem)
        m.addItem(.separator())
        loginItem = NSMenuItem(title: "登录时启动", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        loginItem.target = self; m.addItem(loginItem)
        let log = NSMenuItem(title: "打开日志", action: #selector(openLog(_:)), keyEquivalent: "")
        log.target = self; m.addItem(log)
        m.addItem(.separator())
        let q = NSMenuItem(title: "退出", action: #selector(quit(_:)), keyEquivalent: "q")
        q.target = self; m.addItem(q)
        return m
    }

    func refreshUI() {
        let blacked = ctl.blacked
        statusItem.button?.image = icon(blacked: blacked)
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.title = hotkeyUnavailable ? "⚠" : ""
        statusItem.button?.toolTip = hotkeyUnavailable
            ? "BlankScreen —— 快捷键未生效：\(carbonStatusText(ctl.lastHotkeyStatus))"
            : "BlankScreen —— 快捷键 \(hotkeyText(ctl.cfg))，点击打开菜单"
        stateItem.title = blacked ? "● 显示器已关闭（系统保持唤醒）" : "○ 显示正常"
        toggleItem.title = blacked ? "恢复显示  \(hotkeyText(ctl.cfg))" : "关闭显示器  \(hotkeyText(ctl.cfg))"
        loginItem?.state = isLoginItemEnabled() ? .on : .off
        if hotkeyUnavailable {
            permItem.title = "⚠️ 快捷键未生效 —— 点击排查"
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

    static func dumpView(_ v: NSView, depth: Int) {
        let pad = String(repeating: "  ", count: depth)
        blog("\(pad)\(type(of: v)) frame=\(v.frame)")
        for sub in v.subviews { dumpView(sub, depth: depth + 1) }
    }

    /// 菜单弹出前刷新状态（menuWillOpen 已负责重试热键监听）
    @objc func menuNeedsUpdate(_ menu: NSMenu) { refreshUI() }
    @objc private func toggle(_ sender: Any?) { ctl.toggle() }
    @objc private func openSettings(_ sender: Any?) {
        if settings == nil { settings = SettingsPanel() }
        settings?.show()
    }
    @objc func checkHotkey(_ sender: Any?) {
        ensureHotkey()
        guard ctl.hotkeyReady else {
            let a = NSAlert(); a.alertStyle = .warning
            a.messageText = "快捷键未生效"
            a.informativeText = "\(hotkeyText(ctl.cfg))：\(carbonStatusText(ctl.lastHotkeyStatus))。\n\n本程序使用系统级全局热键，不需要「辅助功能 / 输入监控」授权。若组合被其他 App 占用，请在设置里换一个。"
            a.addButton(withTitle: "好"); a.runModal(); return
        }
        statusItem.button?.title = "⏳"
        ctl.selfTest { [weak self] ok in
            DispatchQueue.main.async {
                self?.hotkeyUnavailable = !(self?.ctl.hotkeyReady ?? false)
                self?.refreshUI()
                let a = NSAlert()
                a.alertStyle = ok ? .informational : .warning
                a.messageText = ok ? "热键可用" : "热键未响应"
                a.informativeText = ok
                    ? "已确认系统把 \(hotkeyText(self?.ctl.cfg ?? Config())) 投递给了本程序，可直接开关显示。"
                    : "自检未收到 \(hotkeyText(self?.ctl.cfg ?? Config()))。\n\n可能原因：① 该组合被其他 App 抢先接管，换一个组合再试；② 本程序刚重装，系统热键表尚未刷新，退出重开一次。"
                a.addButton(withTitle: "好"); a.runModal()
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
                a.messageText = "已写入配置，但未能注册 launchd"
                a.informativeText = "请在终端执行：\nlaunchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/\(barLabel).plist"
                a.addButton(withTitle: "好"); a.runModal()
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
        a.messageText = "快捷键未生效"
        a.informativeText = """
        \(hotkeyText(ctl.cfg))：\(carbonStatusText(ctl.lastHotkeyStatus))

        本程序使用系统级全局热键（Carbon），不需要「辅助功能 / 输入监控」授权。
        未生效通常是这三种情况：
        1. 组合被其他 App 占用 —— 在设置里换一个，例如 ⇧⌘B、⌃⌥⌘B；
        2. 组合没带修饰键 —— 系统要求 ⌘ / ⌃ / ⌥ / ⇧ 至少一个；
        3. App 刚重装，系统热键表未刷新 —— 退出本程序重开一次。
        """
        a.addButton(withTitle: "打开设置")
        a.addButton(withTitle: "好")
        if a.runModal() == .alertFirstButtonReturn { openSettings(nil) }
    }
}

// MARK: - 入口
let app = NSApplication.shared
app.setActivationPolicy(.accessory)          // 不显示 Dock 图标
let delegate = AppDelegate()
app.delegate = delegate
app.run()
