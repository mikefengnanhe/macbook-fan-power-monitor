# PowerBar — MacBook fan control & power monitor

[中文说明](README.zh-CN.md)

A tiny menu bar app for Apple Silicon MacBooks that shows **real-time power draw, CPU/GPU temperature and fan speed**, lets you **run the fans faster than Apple's default curve** for better cooling, **caps battery charging at 80%** (charge to 100% only when you ask), and switches **display brightness** of the built-in and external displays together in one click.

- No Dock icon, ~30 MB memory, near-zero CPU
- Reading power, temperature and fans needs no admin rights
- UI follows your system language (Chinese or English)

## Features

**Menu bar:** `⚡︎ 35.6W  72°C  80%⏸︎` (system power, hottest CPU sensor, battery level; `⏸︎` = charging paused by PowerBar, `↑` = charging)

**Menu:**
- System power, power source (adapter / battery), battery charge/discharge power, battery level
- CPU temperature (max / average over all performance and efficiency core sensors)
- GPU temperature (max / average)
- Fan speeds and who controls them (system or PowerBar)
- Average and peak power since launch, reset statistics
- Refresh interval: 2 / 5 / 10 / 30 s or manual only (⌘R refreshes)
- Charge limit 70% / 80% / 90% / off, plus **Charge to 100%** for one charge (the limit comes back after you unplug)
- Display brightness presets: 0% / 20% / 50% / 70% / 100% in one click — built-in display and external monitors (DDC/CI) together
- Launch at login

**Fan modes:**

| Mode | Behavior |
|---|---|
| Automatic | Apple's default fan control |
| Everyday curve | Ramp from 40°C CPU, full speed at 90°C |
| Gentle curve | Ramp from 50°C CPU, full speed at 85°C — quiet, still cooler than default |
| Balanced curve | Ramp from 40°C, full speed at 75°C |
| Aggressive curve | Ramp from 35°C, full speed at 70°C |
| Extreme curve | Ramp from 25°C, full speed at 60°C — fans near maximum under almost any load |
| Fixed 3000 / 4000 / 5000 RPM | Fans held at a constant speed |
| Maximum | Fans at their maximum speed |

When PowerBar quits, fans are handed back to the system. After sleep/wake the selected mode is re-applied.

## Requirements

- MacBook with Apple Silicon (M1 or later). Tested on M2 Pro.
- macOS 13 Ventura or later

Intel Macs are not supported (they use different SMC sensor keys).

## Install

### Option 1: download

1. Download `PowerBar.zip` from [Releases](../../releases/latest) and unzip it.
2. Move `PowerBar.app` to `/Applications`.
3. The app is not notarized by Apple, so macOS blocks it the first time. Either:
   - Open it once, then go to **System Settings → Privacy & Security** and click **Open Anyway**, or
   - Run in Terminal:
     ```bash
     xattr -dr com.apple.quarantine /Applications/PowerBar.app
     ```

### Option 2: build from source

Requires Xcode or the Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/mikefengnanhe/macbook-fan-power-monitor.git
cd macbook-fan-power-monitor
./build.sh
open /Applications/PowerBar.app
```

## Enabling fan control and the charge limit

Changing fan speed and pausing charging require root. The first time, open **Fan Mode → Install Fan Control Helper…** (or **Charge Limit → Install Helper…**) and enter your admin password once. After upgrading PowerBar, **Charge Limit → Update Helper…** appears if the installed helper is older than the app.

This installs a small helper at `/Library/PrivilegedHelperTools/powerbar-fan` (owned by root, setuid). It accepts only these commands — `auto`, `set <rpm>` and `charge on|off` — and clamps fan speed to the fan's own min/max range. Source: [helper/main.swift](helper/main.swift).

To remove it:

```bash
sudo rm /Library/PrivilegedHelperTools/powerbar-fan
```

## Notes

- Power data comes from the battery controller's telemetry (`AppleSmartBattery`), which macOS updates only every ~20–30 seconds.
- Temperatures and fans are read from the SMC (`Tp*`/`Te*` keys for CPU cores, `Tg*` for GPU).
- Curves map the hottest CPU sensor linearly from the fan's minimum to maximum speed between the two temperatures; speeds are re-checked every 3 seconds.
- Apple Silicon only throttles at roughly 100°C+, so temperatures of 60–80°C under load are normal and safe.
- Faster fans lower temperatures by a few degrees, especially under sustained load, at the cost of noise and some extra fan wear.
- Charge limit: PowerBar checks every 20 s, pauses charging at the limit (SMC `CHTE`, or `CH0B`/`CH0C` on older firmware) and resumes 3% below it. The adapter keeps powering the Mac while charging is paused. While plugged in and charging up to the limit, PowerBar keeps the Mac from sleeping (the display still sleeps), otherwise it would charge to 100% overnight. Charging is re-enabled when PowerBar quits, so turn on Launch at Login.
- A battery already above the limit is not discharged; it drifts down on its own or when you unplug.
- Brightness of the built-in display uses the system's DisplayServices framework; external monitors are set over DDC/CI (VCP 0x10). Monitors without DDC support (and virtual displays) are skipped silently. 0% is the lowest backlight level and is very dark.
- Use at your own risk. The helper never sets fans below their minimum speed.

## Project layout

| File | Purpose |
|---|---|
| `main.swift` | Menu bar app |
| `smc.swift`, `smc.h` | SMC read/write (temperatures, fans, charging) |
| `helper/main.swift` | Root helper for fan control and charging |
| `build.sh` | Builds `PowerBar.app` and installs it to `/Applications` |

## License

[GPL-3.0](LICENSE)
