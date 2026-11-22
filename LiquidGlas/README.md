# LiquidGlas - iOS Control Center Liquid Glass Effect

## ✨ Features

- 🌊 **Liquid Glass Effect** - Stunning glassmorphism on Control Center panel
- ⚙️ **Customizable Settings** - Adjust opacity, blur, gloss level, corner radius
- 🎨 **Color Tint Support** - Customize the glass color appearance
- 💎 **Smooth Animations** - Fluid transition effects
- 🔢 **Volume / Brightness Percentage** - Live percentage on Control Center sliders

## 📥 Installation

### Method 1: Cydia Saurik Repository

apt-get install liquidglas

### Method 2: Direct Installation

1. Download .deb package from GitHub Releases
2. Install using Cydia Impactor or Sileo
3. Reboot your device after installation

## ⚙️ Configuration Settings

| Setting | Description | Default Range |
|---------|-------------|---------------|
| Enable Liquid Glass | Turn on/off the glass effect | ON / OFF |
| Glass Opacity | Control transparency level | 0 - 100% |
| Glass Blur | Background blur intensity | 0 - 50px |
| Gloss Level | Reflection/glossy finish | 0 - 100% |
| Corner Radius | Rounded corner size | 0 - 100px |
| Color Tint | Custom glass color | #2563eb (Blue) |

## 🔢 音量 / 亮度百分比显示

控制中心音量、亮度滑条上会叠加实时百分比（`LGPercentageDisplay.m`）：

- 数值取自公开 API：`AVAudioSession.outputVolume` 与 `UIScreen.mainScreen.brightness`，拖动时即时刷新；读不到时回退到滑块自身的 `value`。
- 通过运行时类名识别 CC 滑块，不依赖私有头文件、不 hook 私有方法，兼容 iOS 15~18 的不同类名。
- 0.4s 低频刷新 + 系统通知即时刷新；控制中心不可见时几乎零开销，不会持续占 CPU。
- 竖条显示在顶部内嵌，横条显示在右侧；白色半粗体 + 轻阴影，不拦截触摸事件。

新增设置项（偏好域 `com.wang7799.liquidglas`）：

| 设置 | Key | 默认 |
| --- | --- | --- |
| 音量百分比 | `showVolumePercentage` | 开 |
| 亮度百分比 | `showBrightnessPercentage` | 开 |
| 百分比字号 | `percentageFontSize` | 12 (9~24) |

> 改动只在源码。GitHub Release 里的 deb 使用预编译 dylib，需要重新编译后替换 payload 才会带上本功能，见下方「Build from Source」。

## 🔄 Troubleshooting

### Effect not appearing?

1. Ensure Control Center is enabled in Settings
2. Reboot your device after installation
3. Check if the tweak loaded correctly via Cydia → Packages

### Visual glitches?

1. Update to the latest version
2. Clear Cache: rm -rf /var/cache/com.lqtg.LiquidGlass
3. Uninstall and reinstall the tweak

## 📦 Build from Source

需要 macOS + Theos（Windows 无法编译 iOS tweak，可用 GitHub Actions 的 macOS runner）：

```bash
make clean package THEOS_PACKAGE_SCHEME=rootless FINALPACKAGE=1   # 无根 /var/jb
make clean package THEOS_PACKAGE_SCHEME=roothide FINALPACKAGE=1   # 隐根，需 roothide/theos
```

`Makefile` 已把 `LGPercentageDisplay.m` 加入 `LiquidGlas_FILES`，并链接 `AVFoundation`。
编译产出的 `LiquidGlas.dylib` 需替换 deb payload 中对应 dylib 后重新打包（仓库根目录 `build_debs.py`）。

## 🔧 Technical Details

- Architecture: arm64 (iOS 14+)
- Framework Dependencies: UIKit, QuartzCore, Substrate
- Process Injection: ControlCenterSpringBoard
- Dynamic Libraries: LiquidGlass27.dylib, BGRenderServer.dylib, BGWidgetRenderer.dylib

## ⚠️ License

This project is licensed under the GPL-3.0 License - see LICENSE file for details.

---

Made with ❤️ by LQTG