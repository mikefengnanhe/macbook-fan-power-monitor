// SMC 读写：温度、风扇（读取无需 root，写入需要 root）
import Foundation
import IOKit

/// 界面语言：系统首选语言为中文时显示中文，否则英文。
/// root 组件由 app 通过环境变量 POWERBAR_LANG 告知语言。
let isChinese: Bool = {
    if let l = ProcessInfo.processInfo.environment["POWERBAR_LANG"] { return l == "zh" }
    return Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
}()
func L(_ zh: String, _ en: String) -> String { isChinese ? zh : en }

func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
func fourCCString(_ v: UInt32) -> String {
    String(bytes: [24, 16, 8, 0].map { UInt8((v >> $0) & 0xff) }, encoding: .ascii) ?? "????"
}

final class SMC {
    private var conn: io_connect_t = 0

    init?() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        guard IOServiceOpen(svc, mach_task_self_, 0, &conn) == KERN_SUCCESS else { return nil }
    }
    deinit { IOServiceClose(conn) }

    private func call(_ input: inout SMCParam) -> SMCParam? {
        var out = SMCParam()
        var size = MemoryLayout<SMCParam>.stride
        let r = IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<SMCParam>.stride, &out, &size)
        return (r == KERN_SUCCESS && out.result == 0) ? out : nil
    }

    func keyInfo(_ key: UInt32) -> SMCKeyInfo? {
        var p = SMCParam(); p.key = key; p.data8 = 9
        return call(&p)?.keyInfo
    }

    /// 返回 (类型, 原始字节)
    func read(_ key: String) -> (String, [UInt8])? { read(fourCC(key)) }
    func read(_ key: UInt32) -> (String, [UInt8])? {
        guard let info = keyInfo(key) else { return nil }
        var p = SMCParam(); p.key = key; p.keyInfo.dataSize = info.dataSize; p.data8 = 5
        guard let out = call(&p) else { return nil }
        let bytes = withUnsafeBytes(of: out.bytes) { Array($0.prefix(Int(info.dataSize))) }
        return (fourCCString(info.dataType), bytes)
    }

    func write(_ key: String, _ bytes: [UInt8]) -> Bool {
        guard let info = keyInfo(fourCC(key)), Int(info.dataSize) == bytes.count else { return false }
        var p = SMCParam(); p.key = fourCC(key); p.keyInfo.dataSize = info.dataSize; p.data8 = 6
        withUnsafeMutableBytes(of: &p.bytes) { for (i, b) in bytes.enumerated() { $0[i] = b } }
        return call(&p) != nil
    }

    /// 把常见数值类型解码成 Double
    func number(_ key: String) -> Double? {
        guard let (type, b) = read(key) else { return nil }
        switch type {
        case "flt " where b.count == 4: return Double(b.withUnsafeBytes { $0.load(as: Float.self) })
        case "ui8 " where b.count == 1: return Double(b[0])
        case "ui16" where b.count == 2: return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        case "ui32" where b.count == 4: return Double(b.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        case "fpe2" where b.count == 2: return Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4
        case "sp78" where b.count == 2: return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256
        default: return nil
        }
    }

    func allKeys() -> [String] {
        guard let n = number("#KEY") else { return [] }
        return (0..<UInt32(n)).compactMap { i in
            var p = SMCParam(); p.data8 = 8; p.data32 = i
            return call(&p).map { fourCCString($0.key) }
        }
    }

    func writeFloat(_ key: String, _ v: Float) -> Bool {
        write(key, withUnsafeBytes(of: v) { Array($0) })
    }
}
