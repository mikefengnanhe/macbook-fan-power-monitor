// powerbar-fan：以 root 运行的风扇控制组件，只接受下面几种命令
//   powerbar-fan auto        所有风扇恢复系统自动控制
//   powerbar-fan set <rpm>   所有风扇固定到指定转速（自动限制在最小~最大之间）
//   powerbar-fan charge on   允许电池充电
//   powerbar-fan charge off  暂停电池充电（电源仍然给整机供电）
import Foundation

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

let args = CommandLine.arguments
guard let smc = SMC() else { fail(L("无法连接 SMC", "Cannot connect to SMC")) }

// 充电控制：新固件用 CHTE（ui32，1=暂停），旧固件用 CH0B/CH0C（02=暂停）
if args.count == 3, args[1] == "charge", ["on", "off"].contains(args[2]) {
    let off = args[2] == "off"
    let ok = smc.read("CHTE") != nil ? smc.write("CHTE", [off ? 1 : 0, 0, 0, 0])
                                     : smc.write("CH0B", [off ? 2 : 0]) && smc.write("CH0C", [off ? 2 : 0])
    if !ok { fail(L("设置充电状态失败（需要 root）", "Failed to set charging state (root required)")) }
    exit(0)
}
let fans = Int(smc.number("FNum") ?? 0)
guard fans > 0 else { fail(L("没有找到风扇", "No fans found")) }

switch (args.count, args.count > 1 ? args[1] : "") {
case (2, "auto"):
    for i in 0..<fans where !smc.write("F\(i)Md", [0]) {
        fail(L("风扇 \(i) 恢复自动失败", "Failed to return fan \(i) to automatic"))
    }
case (3, "set"):
    guard let rpm = Double(args[2]), rpm.isFinite else { fail(L("转速无效", "Invalid RPM")) }
    for i in 0..<fans {
        let lo = smc.number("F\(i)Mn") ?? 0, hi = smc.number("F\(i)Mx") ?? 0
        guard hi > lo else { fail(L("读取风扇 \(i) 转速范围失败", "Failed to read RPM range of fan \(i)")) }
        let target = Float(min(max(rpm, lo), hi))
        guard smc.write("F\(i)Md", [1]) else {
            fail(L("风扇 \(i) 切换手动模式失败（需要 root）", "Failed to switch fan \(i) to manual mode (root required)"))
        }
        guard smc.writeFloat("F\(i)Tg", target) else {
            fail(L("风扇 \(i) 设置转速失败", "Failed to set speed of fan \(i)"))
        }
    }
default:
    fail(L("用法：powerbar-fan auto | set <rpm> | charge on|off", "Usage: powerbar-fan auto | set <rpm> | charge on|off"))
}
