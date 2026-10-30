# PowerBar — 苹果笔记本风扇控制与功耗监测

[English](README.md)

一个很小的菜单栏 app，适用于 Apple Silicon 的 MacBook。它能**实时显示整机功耗、CPU/GPU 温度和风扇转速**，还能**让风扇转得比苹果默认更快**，散热更好。

- 不占 Dock，内存约 30 MB，CPU 占用接近 0
- 读取功耗、温度和风扇不需要管理员权限
- 界面跟随系统语言显示中文或英文

## 功能

**菜单栏：** `⚡︎ 35.6W  72°C`（整机功耗、CPU 最高温度）

**菜单：**
- 整机功耗、供电来源（电源适配器 / 电池）、电池充放电功率、电量
- CPU 温度（汇总所有性能核和能效核传感器，显示最高值和平均值）
- GPU 温度（最高值和平均值）
- 风扇转速，以及当前是系统还是 PowerBar 在控制
- 启动以来的平均功耗和峰值，可重置统计
- 刷新间隔：2 / 5 / 10 / 30 秒或仅手动（⌘R 立即刷新）
- 开机自动启动

**风扇模式：**

| 模式 | 说明 |
|---|---|
| 自动 | 苹果默认的风扇控制 |
| 温度加速曲线 | CPU 到 35°C 开始加速，70°C 时满速 |
| 固定 3000 / 4000 / 5000 RPM | 风扇保持固定转速 |
| 最大 | 风扇最高转速 |

退出 PowerBar 时，风扇会交还给系统控制。睡眠唤醒后会重新应用所选模式。

## 系统要求

- Apple Silicon（M1 及以后）的 MacBook，已在 M2 Pro 上测试
- macOS 13 Ventura 或更新版本

不支持 Intel Mac（它们的 SMC 传感器键不同）。

## 安装

### 方式一：下载

1. 在 [Releases](../../releases/latest) 下载 `PowerBar.zip` 并解压。
2. 把 `PowerBar.app` 拖到“应用程序”文件夹。
3. 这个 app 没有经过苹果公证，第一次打开会被系统拦截。任选一种方法：
   - 先打开一次，然后到 **系统设置 → 隐私与安全性**，点 **仍要打开**；或者
   - 在终端运行：
     ```bash
     xattr -dr com.apple.quarantine /Applications/PowerBar.app
     ```

### 方式二：从源码编译

需要 Xcode 或命令行工具（`xcode-select --install`）。

```bash
git clone https://github.com/mikefengnanhe/macbook-fan-power-monitor.git
cd macbook-fan-power-monitor
./build.sh
open /Applications/PowerBar.app
```

## 开启风扇控制

调节风扇转速需要 root 权限。第一次使用时，点 **风扇模式 → 安装风扇控制组件…**，输入一次管理员密码即可。

这会在 `/Library/PrivilegedHelperTools/powerbar-fan` 安装一个小组件（属主 root，带 setuid）。它只接受两种命令：`auto` 和 `set <转速>`，并且会把转速限制在风扇自身的最小到最大范围内。源码见 [helper/main.swift](helper/main.swift)。

卸载组件：

```bash
sudo rm /Library/PrivilegedHelperTools/powerbar-fan
```

## 说明

- 功耗数据来自电池控制器的遥测（`AppleSmartBattery`），系统大约每 20~30 秒才更新一次。
- 温度和风扇从 SMC 读取（`Tp*`/`Te*` 为 CPU 核心，`Tg*` 为 GPU）。
- 风扇转快通常能让温度低几度，持续高负载时更明显；代价是噪音更大，风扇磨损也会多一点。
- 使用风险自负。组件不会把风扇设到低于最低转速。

## 文件结构

| 文件 | 用途 |
|---|---|
| `main.swift` | 菜单栏 app |
| `smc.swift`、`smc.h` | SMC 读写（温度、风扇） |
| `helper/main.swift` | root 风扇控制组件 |
| `build.sh` | 编译 `PowerBar.app` 并安装到“应用程序” |

## 许可证

[GPL-3.0](LICENSE)
