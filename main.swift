// PowerBar：菜单栏功耗 / 温度 / 风扇监测（Apple Silicon MacBook），界面跟随系统语言显示中文或英文
// 功耗读 AppleSmartBattery 电源遥测，温度和风扇读 SMC，均无需 sudo；
// 调节风扇和充电上限需要 root，通过安装到 /Library/PrivilegedHelperTools 的 powerbar-fan 完成。
import Cocoa
import IOKit
import IOKit.pwr_mgt
import ServiceManagement

struct Reading {
    var system: Double = 0   // 整机功耗 W
    var adapter: Double = 0  // 电源输入 W
    var battery: Double = 0  // 电池功率 W，正=充电，负=放电
    var onAC = false
    var percent = 0
}

func readPower() -> Reading? {
    let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard svc != 0 else { return nil }
    defer { IOObjectRelease(svc) }
    var props: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let d = props?.takeRetainedValue() as? [String: Any] else { return nil }

    func num(_ v: Any?) -> Double { (v as? NSNumber).map { Double($0.int64Value) } ?? 0 }
    var r = Reading()
    let t = d["PowerTelemetryData"] as? [String: Any] ?? [:]
    r.system = num(t["SystemLoad"]) / 1000
    r.adapter = num(t["SystemPowerIn"]) / 1000
    r.battery = num(d["Voltage"]) * num(d["InstantAmperage"]) / 1_000_000
    r.onAC = (d["ExternalConnected"] as? Bool) ?? false
    r.percent = Int(num(d["CurrentCapacity"]))
    return r
}

/// 一组温度传感器的最高值与平均值
struct TempGroup {
    let keys: [String]
    func read(_ smc: SMC) -> (max: Double, avg: Double)? {
        let v = keys.compactMap { smc.number($0) }.filter { $0 > 10 && $0 < 130 }
        guard !v.isEmpty else { return nil }
        return (v.max()!, v.reduce(0, +) / Double(v.count))
    }
}

enum FanMode: Equatable {
    case auto              // 系统自动
    case curve(Double, Double)  // 按 CPU 温度加速：低点°C 起离开最低速，高点°C 满速
    case fixed(Double)     // 固定转速

    var key: String {
        switch self {
        case .auto: "auto"
        case .curve(let lo, let hi): "curve:\(Int(lo))-\(Int(hi))"
        case .fixed(let r): "fixed:\(Int(r))"
        }
    }
    init(key: String) {
        if key == "curve" { self = .curve(35, 70) }  // 兼容 1.0 保存的设置
        else if key.hasPrefix("curve:") {
            let p = key.dropFirst(6).split(separator: "-").compactMap { Double($0) }
            self = p.count == 2 && p[1] > p[0] ? .curve(p[0], p[1]) : .auto
        }
        else if key.hasPrefix("fixed:"), let r = Double(key.dropFirst(6)) { self = .fixed(r) }
        else { self = .auto }
    }
}

/// 内建屏幕亮度：通过系统私有框架 DisplayServices 读写，无需 root
enum Brightness {
    typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    typealias SetFn = @convention(c) (UInt32, Float) -> Int32
    static let lib = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    static let getFn = lib.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: GetFn.self) }
    static let setFn = lib.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: SetFn.self) }

    static var display: CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16), n: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &n)
        return ids.prefix(Int(n)).first { CGDisplayIsBuiltin($0) != 0 }
    }
    static func get() -> Float? {
        guard let d = display, let getFn else { return nil }
        var v: Float = 0
        return getFn(d, &v) == 0 ? v : nil
    }
    static func set(_ v: Float) -> Bool {
        guard let d = display, let setFn else { return false }
        return setFn(d, min(max(v, 0), 1)) == 0
    }
}

/// 外接显示器亮度：通过 DDC/CI（VCP 0x10）经 IOAVService 读写，无需 root；不支持 DDC 的显示器自动跳过
enum ExternalBrightness {
    typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    typealias I2CFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    static let lib = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
    static let create = lib.flatMap { dlsym($0, "IOAVServiceCreateWithService") }.map { unsafeBitCast($0, to: CreateFn.self) }
    static let readI2C = lib.flatMap { dlsym($0, "IOAVServiceReadI2C") }.map { unsafeBitCast($0, to: I2CFn.self) }
    static let writeI2C = lib.flatMap { dlsym($0, "IOAVServiceWriteI2C") }.map { unsafeBitCast($0, to: I2CFn.self) }

    /// 当前连接的所有外接显示器的 AV 服务
    static var services: [CFTypeRef] {
        guard let create else { return [] }
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &it) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(it) }
        var out: [CFTypeRef] = []
        while case let s = IOIteratorNext(it), s != 0 {
            defer { IOObjectRelease(s) }
            let loc = IORegistryEntryCreateCFProperty(s, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            if loc == "External", let av = create(kCFAllocatorDefault, s)?.takeRetainedValue() { out.append(av) }
        }
        return out
    }

    /// DDC 包：地址 0x51 开头，末尾是与目标地址 0x6E 一起计算的异或校验
    static func send(_ av: CFTypeRef, _ body: [UInt8]) -> Bool {
        guard let writeI2C else { return false }
        var pkt = body + [body.reduce(0x6E ^ 0x51, ^)]
        return writeI2C(av, 0x37, 0x51, &pkt, UInt32(pkt.count)) == kIOReturnSuccess
    }

    /// 读取 (当前值, 最大值)
    static func read(_ av: CFTypeRef) -> (cur: Int, max: Int)? {
        guard let readI2C else { return nil }
        for _ in 0..<3 {  // DDC 偶尔丢包，重试几次
            guard send(av, [0x82, 0x01, 0x10]) else { continue }
            usleep(40_000)
            var b = [UInt8](repeating: 0, count: 12)
            if readI2C(av, 0x37, 0x51, &b, 12) == kIOReturnSuccess, b[2] == 0x02, b[3] == 0, b[4] == 0x10 {
                let mx = Int(b[6]) << 8 | Int(b[7])
                if mx > 0 { return (Int(b[8]) << 8 | Int(b[9]), mx) }
            }
        }
        return nil
    }

    /// 第一台可读的外接显示器的亮度（0~1）
    static func get() -> Float? {
        for av in services { if let r = read(av) { return Float(r.cur) / Float(r.max) } }
        return nil
    }

    /// 把所有外接显示器设到 v（0~1），返回成功的台数
    @discardableResult
    static func set(_ v: Float) -> Int {
        services.filter { av in
            let mx = read(av)?.max ?? 100
            let val = Int((min(max(v, 0), 1) * Float(mx)).rounded())
            return send(av, [0x84, 0x03, 0x10, UInt8(val >> 8), UInt8(val & 0xff)])
        }.count
    }
}

let helperPath = "/Library/PrivilegedHelperTools/powerbar-fan"
/// 温度曲线预设：名称、起始温度、满速温度
let curves: [(zh: String, en: String, lo: Double, hi: Double)] = [
    ("日常", "Everyday", 40, 90),
    ("温和", "Gentle", 50, 85),
    ("均衡", "Balanced", 40, 75),
    ("激进", "Aggressive", 35, 70),
    ("极限", "Extreme", 25, 60),
]

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let systemLine = NSMenuItem(), sourceLine = NSMenuItem(), batteryLine = NSMenuItem()
    let cpuLine = NSMenuItem(), gpuLine = NSMenuItem(), fanLine = NSMenuItem()
    let statsLine = NSMenuItem(), timeLine = NSMenuItem()
    let fanMenu = NSMenu(), installItem = NSMenuItem()
    let brightnessMenu = NSMenu(), brightnessItem = NSMenuItem()
    let chargeMenu = NSMenu(), chargeItem = NSMenuItem(), fullItem = NSMenuItem(), chargeInstallItem = NSMenuItem()
    var timer: Timer?, fanTimer: Timer?, chargeTimer: Timer?
    /// 充电上限百分比，0 表示关闭（系统默认充到 100%）
    var chargeLimit = UserDefaults.standard.object(forKey: "chargeLimit") as? Int ?? 80
    /// 临时充满一次，拔掉电源后自动恢复上限
    var fullOnce = UserDefaults.standard.bool(forKey: "fullOnce")
    var lastOnAC: Bool?
    var sleepAssertion: IOPMAssertionID = 0
    var interval: TimeInterval = UserDefaults.standard.object(forKey: "interval") as? Double ?? 5
    var fanMode = FanMode(key: UserDefaults.standard.string(forKey: "fanMode") ?? "auto")
    var total = 0.0, count = 0, peak = 0.0
    var lastTarget: Double?
    let intervals: [(String, TimeInterval)] = [(L("2 秒", "2 sec"), 2), (L("5 秒", "5 sec"), 5), (L("10 秒", "10 sec"), 10),
                                                    (L("30 秒", "30 sec"), 30), (L("仅手动", "Manual only"), 0)]

    let smc = SMC()
    var cpu = TempGroup(keys: []), gpu = TempGroup(keys: [])
    var fanCount = 0, fanMin = 0.0, fanMax = 0.0

    var helperInstalled: Bool {
        guard let a = try? FileManager.default.attributesOfItem(atPath: helperPath) else { return false }
        return (a[.ownerAccountID] as? Int) == 0 && ((a[.posixPermissions] as? Int ?? 0) & 0o4000) != 0
    }
    /// 已安装的组件与 app 自带的一致（旧版组件不支持充电控制）
    var helperCurrent: Bool {
        guard helperInstalled, let src = Bundle.main.path(forResource: "powerbar-fan", ofType: nil) else { return false }
        return FileManager.default.contentsEqual(atPath: src, andPath: helperPath)
    }
    /// SMC 当前是否暂停了充电（读取无需 root）
    var chargingPaused: Bool {
        guard let smc else { return false }
        if let (_, b) = smc.read("CHTE") { return b.first == 1 }
        return smc.read("CH0B")?.1.first == 2
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        if let smc {
            // 启动时扫描一次 SMC 键：Tp*/Te* 为 CPU 性能/能效核心，Tg* 为 GPU
            let keys = smc.allKeys().filter { smc.read($0)?.0 == "flt " }
            cpu = TempGroup(keys: keys.filter { $0.hasPrefix("Tp") || $0.hasPrefix("Te") })
            gpu = TempGroup(keys: keys.filter { $0.hasPrefix("Tg") })
            fanCount = Int(smc.number("FNum") ?? 0)
            fanMin = smc.number("F0Mn") ?? 0
            fanMax = smc.number("F0Mx") ?? 0
        }

        for l in [systemLine, sourceLine, batteryLine, cpuLine, gpuLine, fanLine, statsLine, timeLine] {
            l.isEnabled = false
        }
        [systemLine, sourceLine, batteryLine].forEach(menu.addItem)
        if smc?.read("CHTE") != nil || smc?.read("CH0B") != nil {
            fullItem.title = L("充满到 100%（拔掉电源后恢复上限）", "Charge to 100% (limit resumes after unplugging)")
            fullItem.action = #selector(toggleFullOnce); fullItem.target = self
            menu.addItem(fullItem)
            menu.addItem(chargeItem)
            menu.setSubmenu(chargeMenu, for: chargeItem)
            buildChargeMenu()
        }
        menu.addItem(.separator())
        [cpuLine, gpuLine, fanLine].forEach(menu.addItem)
        if fanCount > 0 {
            buildFanMenu()
            let f = menu.addItem(withTitle: L("风扇模式", "Fan Mode"), action: nil, keyEquivalent: "")
            menu.setSubmenu(fanMenu, for: f)
        }
        if Brightness.get() != nil || !ExternalBrightness.services.isEmpty {
            menu.addItem(.separator())
            for pct in [20, 50, 70, 100] {
                let i = brightnessMenu.addItem(withTitle: "\(pct)%", action: #selector(setBrightness(_:)), keyEquivalent: "")
                i.target = self; i.tag = pct
            }
            brightnessMenu.delegate = self
            menu.addItem(brightnessItem)
            menu.setSubmenu(brightnessMenu, for: brightnessItem)
            // 亮度 0% 单独放在一级菜单，一键关暗屏幕
            let off = menu.addItem(withTitle: L("屏幕亮度调到 0%", "Set Brightness to 0%"),
                                   action: #selector(setBrightness(_:)), keyEquivalent: "")
            off.target = self; off.tag = 0
            updateBrightness()
        }
        menu.addItem(.separator())
        [statsLine, timeLine].forEach(menu.addItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: L("立即刷新", "Refresh Now"), action: #selector(refresh), keyEquivalent: "r").target = self
        menu.addItem(withTitle: L("重置统计", "Reset Statistics"), action: #selector(resetStats), keyEquivalent: "").target = self

        let sub = NSMenu()
        for (name, sec) in intervals {
            let i = sub.addItem(withTitle: name, action: #selector(setInterval(_:)), keyEquivalent: "")
            i.target = self; i.tag = Int(sec); i.state = sec == interval ? .on : .off
        }
        let subItem = menu.addItem(withTitle: L("自动刷新", "Auto Refresh"), action: nil, keyEquivalent: "")
        menu.setSubmenu(sub, for: subItem)

        let login = menu.addItem(withTitle: L("开机自动启动", "Launch at Login"), action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: L("退出", "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu

        if fanMode != .auto && !helperInstalled { fanMode = .auto }
        refresh()
        startTimer()
        applyFanMode()
        chargeTick()
        chargeTimer = makeTimer(20) { [weak self] in self?.chargeTick() }

        // 睡眠唤醒后 SMC 可能恢复自动，重新应用一次
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.lastTarget = nil; self?.applyFanMode(); self?.chargeTick()
        }
    }

    func applicationWillTerminate(_ n: Notification) {
        if fanMode != .auto { _ = runHelper(["auto"]) }  // 退出时把风扇交还给系统
        if chargingPaused { _ = runHelper(["charge", "on"]) }  // 退出时恢复充电，避免一直不充
        setPreventSleep(false)
    }

    // MARK: 刷新

    func startTimer() {
        timer?.invalidate(); timer = nil
        guard interval > 0 else { return }
        timer = makeTimer(interval) { [weak self] in self?.refresh() }
    }

    func makeTimer(_ sec: TimeInterval, _ block: @escaping () -> Void) -> Timer {
        let t = Timer(timeInterval: sec, repeats: true) { _ in block() }
        t.tolerance = sec * 0.2   // 允许系统合并唤醒，更省电
        RunLoop.main.add(t, forMode: .common)  // 菜单展开时也继续刷新
        return t
    }

    @objc func refresh() {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        timeLine.title = L("更新于 \(f.string(from: Date()))（功耗数据约 20~30 秒刷新一次）",
                          "Updated \(f.string(from: Date())) (power data refreshes every ~20–30 s)")

        var title = "⚡︎ --"
        if let r = readPower() {
            total += r.system; count += 1; peak = max(peak, r.system)
            title = String(format: "⚡︎ %.1fW", r.system)
            systemLine.title = String(format: L("整机功耗：%.2f W", "System power: %.2f W"), r.system)
            sourceLine.title = r.onAC ? String(format: L("供电：电源适配器 %.2f W", "Source: power adapter %.2f W"), r.adapter)
                                    : L("供电：电池", "Source: battery")
            batteryLine.title = String(format: L("电池：%+.2f W（%@），电量 %d%%", "Battery: %+.2f W (%@), %d%%"), r.battery,
                                       r.battery > 0.05 ? L("充电", "charging") : r.battery < -0.05 ? L("放电", "discharging") : L("空闲", "idle"),
                                       r.percent)
            statsLine.title = String(format: L("平均 %.2f W · 峰值 %.2f W（%d 次采样）", "Average %.2f W · Peak %.2f W (%d samples)"), total / Double(count), peak, count)
        }

        if let smc, let c = cpu.read(smc) {
            title += String(format: "  %.0f°C", c.max)
            cpuLine.title = String(format: L("CPU 温度：最高 %.1f°C · 平均 %.1f°C", "CPU temp: max %.1f°C · avg %.1f°C"), c.max, c.avg)
        } else { cpuLine.title = L("CPU 温度：不可用", "CPU temp: unavailable") }
        if let smc, let g = gpu.read(smc) {
            gpuLine.title = String(format: L("GPU 温度：最高 %.1f°C · 平均 %.1f°C", "GPU temp: max %.1f°C · avg %.1f°C"), g.max, g.avg)
        } else { gpuLine.title = L("GPU 温度：不可用", "GPU temp: unavailable") }
        updateFanLine()
        if let r = readPower(), chargeItem.menu != nil {
            title += "  \(r.percent)%" + (chargingPaused ? "⏸︎" : r.battery > 0.05 ? "↑" : "")
        }
        item.button?.title = title
    }

    @objc func resetStats() { total = 0; count = 0; peak = 0; refresh() }

    @objc func setInterval(_ s: NSMenuItem) {
        interval = TimeInterval(s.tag)
        UserDefaults.standard.set(interval, forKey: "interval")
        s.menu?.items.forEach { $0.state = $0 == s ? .on : .off }
        startTimer()
    }

    // MARK: 充电上限

    func buildChargeMenu() {
        chargeMenu.removeAllItems()
        let ok = helperCurrent
        for pct in [70, 80, 90, 0] {
            let name = pct == 0 ? L("关闭（系统默认，充到 100%）", "Off (system default, charge to 100%)")
                                : pct == 80 ? L("80%（推荐）", "80% (recommended)") : "\(pct)%"
            let i = chargeMenu.addItem(withTitle: name, action: #selector(chooseChargeLimit(_:)), keyEquivalent: "")
            i.target = self; i.tag = pct
            i.state = pct == chargeLimit ? .on : .off
            i.isEnabled = ok || pct == 0
        }
        if !ok {
            chargeMenu.addItem(.separator())
            chargeInstallItem.title = helperInstalled ? L("更新控制组件以支持充电上限（需要管理员密码）…", "Update Helper for Charge Limit (admin password required)…")
                                                      : L("安装控制组件（需要管理员密码）…", "Install Helper (admin password required)…")
            chargeInstallItem.action = #selector(installHelper); chargeInstallItem.target = self
            chargeMenu.addItem(chargeInstallItem)
        }
        chargeItem.title = chargeLimit == 0 ? L("充电上限：关闭", "Charge Limit: Off")
                                            : L("充电上限：\(chargeLimit)%", "Charge Limit: \(chargeLimit)%")
        fullItem.state = fullOnce ? .on : .off
        fullItem.isEnabled = ok && chargeLimit > 0
    }

    @objc func chooseChargeLimit(_ s: NSMenuItem) {
        chargeLimit = s.tag
        UserDefaults.standard.set(chargeLimit, forKey: "chargeLimit")
        buildChargeMenu(); chargeTick(); refresh()
    }

    @objc func toggleFullOnce() {
        fullOnce.toggle()
        UserDefaults.standard.set(fullOnce, forKey: "fullOnce")
        buildChargeMenu(); chargeTick(); refresh()
    }

    /// 每 20 秒检查一次：到达上限暂停充电，低于上限 3% 恢复充电（避免频繁切换）
    func chargeTick() {
        guard chargeItem.menu != nil, let r = readPower() else { return }
        if lastOnAC == true && !r.onAC && fullOnce {  // 拔掉电源，临时充满结束
            fullOnce = false; UserDefaults.standard.set(false, forKey: "fullOnce"); buildChargeMenu()
        }
        lastOnAC = r.onAC
        guard helperCurrent else { setPreventSleep(false); return }

        let paused = chargingPaused
        var pause = paused
        if chargeLimit == 0 || fullOnce { pause = false }
        else if r.percent >= chargeLimit { pause = true }
        else if r.percent <= chargeLimit - 3 { pause = false }
        if pause != paused, let err = runHelper(["charge", pause ? "off" : "on"]) {
            chargeLimit = 0; UserDefaults.standard.set(0, forKey: "chargeLimit"); buildChargeMenu()
            alert(L("设置充电失败，已关闭充电上限", "Failed to control charging; charge limit turned off"), err)
            pause = false
        }
        // 插着电往上限充时阻止系统睡眠，否则合盖睡眠期间会一路充到 100%
        setPreventSleep(r.onAC && !pause && chargeLimit > 0 && !fullOnce)
    }

    func setPreventSleep(_ on: Bool) {
        if on && sleepAssertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "PowerBar: charging to limit" as CFString, &sleepAssertion)
        } else if !on && sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion); sleepAssertion = 0
        }
    }

    // MARK: 屏幕亮度

    func menuNeedsUpdate(_ m: NSMenu) { updateBrightness() }  // 打开时读取当前亮度（可能被键盘调过）

    func updateBrightness() {
        guard let v = Brightness.get() ?? ExternalBrightness.get() else { return }
        let pct = Int((v * 100).rounded())
        brightnessItem.title = L("屏幕亮度：\(pct)%", "Display Brightness: \(pct)%")
        brightnessItem.toolTip = L("同时调节内建屏幕和外接显示器", "Adjusts the built-in and external displays together")
        brightnessMenu.items.forEach { $0.state = abs($0.tag - pct) <= 1 ? .on : .off }
    }

    @objc func setBrightness(_ s: NSMenuItem) {
        let v = Float(s.tag) / 100
        let builtin = Brightness.display != nil && Brightness.set(v)
        let external = ExternalBrightness.set(v)  // 没有外接显示器或不支持 DDC 时为 0，直接跳过
        if !builtin && external == 0 {
            alert(L("调节亮度失败", "Failed to set brightness"), L("没有可调节亮度的屏幕", "No display with adjustable brightness"))
        }
        updateBrightness()
    }

    // MARK: 风扇

    func updateFanLine() {
        guard let smc, fanCount > 0 else { fanLine.title = L("风扇：无", "Fans: none"); return }
        let rpms = (0..<fanCount).map { String(format: "%.0f", smc.number("F\($0)Ac") ?? 0) }
        let manual = (smc.number("F0Md") ?? 0) != 0
        let rpm = rpms.joined(separator: " / ")
        fanLine.title = manual ? L("风扇：\(rpm) RPM（PowerBar 控制）", "Fans: \(rpm) RPM (PowerBar control)")
                               : L("风扇：\(rpm) RPM（系统自动）", "Fans: \(rpm) RPM (system auto)")
    }

    func buildFanMenu() {
        fanMenu.removeAllItems()
        var modes: [(String, FanMode)] = [
            (L("自动（系统默认）", "Automatic (system default)"), .auto)]
        for c in curves {
            modes.append((L("\(c.zh)曲线（\(Int(c.lo))°C 起加速，\(Int(c.hi))°C 满速）",
                            "\(c.en) curve (ramp from \(Int(c.lo))°C, full speed at \(Int(c.hi))°C)"), .curve(c.lo, c.hi)))
        }
        for r in [3000.0, 4000, 5000] where r > fanMin && r < fanMax {
            modes.append((L("固定 \(Int(r)) RPM", "Fixed \(Int(r)) RPM"), .fixed(r)))
        }
        modes.append((L("最大 \(Int(fanMax)) RPM", "Maximum \(Int(fanMax)) RPM"), .fixed(fanMax)))
        for (name, mode) in modes {
            let i = fanMenu.addItem(withTitle: name, action: #selector(chooseFanMode(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = mode.key
            i.state = mode == fanMode ? .on : .off
            i.isEnabled = helperInstalled || mode == .auto
        }
        if !helperInstalled {
            fanMenu.addItem(.separator())
            installItem.title = L("安装风扇控制组件（需要管理员密码）…", "Install Fan Control Helper (admin password required)…")
            installItem.action = #selector(installHelper); installItem.target = self
            fanMenu.addItem(installItem)
        }
    }

    @objc func chooseFanMode(_ s: NSMenuItem) {
        fanMode = FanMode(key: s.representedObject as? String ?? "auto")
        UserDefaults.standard.set(fanMode.key, forKey: "fanMode")
        lastTarget = nil
        applyFanMode()
        buildFanMenu()
    }

    /// 应用当前风扇模式；非自动模式下每 3 秒检查一次（曲线跟随温度，固定模式防止被系统改回）
    func applyFanMode() {
        fanTimer?.invalidate(); fanTimer = nil
        if fanMode == .auto {
            if lastTarget != nil || (smc?.number("F0Md") ?? 0) != 0 { _ = runHelper(["auto"]) }
            lastTarget = nil
        } else {
            fanTick()
            fanTimer = makeTimer(3) { [weak self] in self?.fanTick() }
        }
        updateFanLine()
    }

    func fanTick() {
        guard let smc else { return }
        let target: Double
        switch fanMode {
        case .auto: return
        case .fixed(let r): target = r
        case .curve(let lo, let hi):
            let t = cpu.read(smc)?.max ?? hi
            let k = min(max((t - lo) / (hi - lo), 0), 1)
            target = ((fanMin + k * (fanMax - fanMin)) / 100).rounded() * 100 // 按 100 RPM 取整
        }
        // 目标变化不大且 SMC 仍在手动模式时不重复调用，减少开销
        if let last = lastTarget, abs(last - target) < 150, (smc.number("F0Md") ?? 0) != 0 { return }
        if let err = runHelper(["set", String(Int(target))]) {
            fanMode = .auto; UserDefaults.standard.set("auto", forKey: "fanMode")
            fanTimer?.invalidate(); fanTimer = nil; lastTarget = nil
            buildFanMenu()
            alert(L("设置风扇失败，已恢复自动", "Failed to set fans; switched back to automatic"), err)
            return
        }
        lastTarget = target
    }

    /// 运行 root 组件，成功返回 nil，失败返回错误信息
    func runHelper(_ args: [String]) -> String? {
        guard helperInstalled else { return L("风扇控制组件未安装", "Fan control helper is not installed") }
        let p = Process(), err = Pipe()
        p.executableURL = URL(fileURLWithPath: helperPath)
        p.arguments = args
        p.standardError = err
        p.environment = ["POWERBAR_LANG": isChinese ? "zh" : "en"]
        do { try p.run() } catch { return error.localizedDescription }
        p.waitUntilExit()
        if p.terminationStatus == 0 { return nil }
        return String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? L("未知错误", "Unknown error")
    }

    @objc func installHelper() {
        guard let src = Bundle.main.path(forResource: "powerbar-fan", ofType: nil) else {
            alert(L("找不到组件", "Helper not found"),
                  L("请用 build.sh 重新编译安装 PowerBar", "Please rebuild and reinstall PowerBar with build.sh")); return
        }
        let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let cmd = "mkdir -p /Library/PrivilegedHelperTools && cp \(q(src)) \(helperPath) && " +
                  "chown root:wheel \(helperPath) && chmod 4755 \(helperPath)"
        let script = "do shell script \"\(cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        var e: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&e)
        if let e, (e[NSAppleScript.errorNumber] as? Int) != -128 {
            alert(L("安装失败", "Installation failed"), e[NSAppleScript.errorMessage] as? String ?? "\(e)")
        }
        buildFanMenu()
        if chargeItem.menu != nil { buildChargeMenu(); chargeTick(); refresh() }
    }

    func alert(_ title: String, _ text: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    @objc func toggleLogin(_ s: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            alert(L("设置开机启动失败", "Failed to change Launch at Login"), error.localizedDescription)
        }
        s.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // 只在菜单栏显示，不占 Dock
app.run()
