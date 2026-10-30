// powerbar-fan：以 root 运行的风扇控制组件，只接受下面几种命令
//   powerbar-fan auto        所有风扇恢复系统自动控制
//   powerbar-fan set <rpm>   所有风扇固定到指定转速（自动限制在最小~最大之间）
import Foundation

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

let args = CommandLine.arguments
guard let smc = SMC() else { fail(L("无法连接 SMC", "Cannot connect to SMC")) }
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
    fail(L("用法：powerbar-fan auto | set <rpm>", "Usage: powerbar-fan auto | set <rpm>"))
}
