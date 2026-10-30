# PowerBar — MacBook fan control & power monitor

[中文说明](README.zh-CN.md)

A tiny menu bar app for Apple Silicon MacBooks that shows **real-time power draw, CPU/GPU temperature and fan speed**, and lets you **run the fans faster than Apple's default curve** for better cooling.

- No Dock icon, ~30 MB memory, near-zero CPU
- Reading power, temperature and fans needs no admin rights
- UI follows your system language (Chinese or English)

## Features

**Menu bar:** `⚡︎ 35.6W  72°C` (system power, hottest CPU sensor)

**Menu:**
- System power, power source (adapter / battery), battery charge/discharge power, battery level
- CPU temperature (max / average over all performance and efficiency core sensors)
- GPU temperature (max / average)
- Fan speeds and who controls them (system or PowerBar)
- Average and peak power since launch, reset statistics
- Refresh interval: 2 / 5 / 10 / 30 s or manual only (⌘R refreshes)
- Launch at login

**Fan modes:**

| Mode | Behavior |
|---|---|
| Automatic | Apple's default fan control |
| Temperature curve | Fans start ramping up at 35°C CPU and reach full speed at 70°C |
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

## Enabling fan control

Changing fan speed requires root. The first time, open **Fan Mode → Install Fan Control Helper…** and enter your admin password once.

This installs a small helper at `/Library/PrivilegedHelperTools/powerbar-fan` (owned by root, setuid). It accepts only two commands — `auto` and `set <rpm>` — and clamps the speed to the fan's own min/max range. Source: [helper/main.swift](helper/main.swift).

To remove it:

```bash
sudo rm /Library/PrivilegedHelperTools/powerbar-fan
```

## Notes

- Power data comes from the battery controller's telemetry (`AppleSmartBattery`), which macOS updates only every ~20–30 seconds.
- Temperatures and fans are read from the SMC (`Tp*`/`Te*` keys for CPU cores, `Tg*` for GPU).
- Faster fans lower temperatures by a few degrees, especially under sustained load, at the cost of noise and some extra fan wear.
- Use at your own risk. The helper never sets fans below their minimum speed.

## Project layout

| File | Purpose |
|---|---|
| `main.swift` | Menu bar app |
| `smc.swift`, `smc.h` | SMC read/write (temperatures, fans) |
| `helper/main.swift` | Root fan control helper |
| `build.sh` | Builds `PowerBar.app` and installs it to `/Applications` |

## License

[GPL-3.0](LICENSE)
