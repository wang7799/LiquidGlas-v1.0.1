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
| 找不到滑条时的保底浮层 | `showFallbackHUD` | 开 |
| 百分比字号 | `percentageFontSize` | 12 (9~24) |

> 改动只在源码。GitHub Release 里的 deb 需要重新编译的 `LGPercentageDisplay.dylib`（由 CI 产出）合进 payload 才会带上本功能，见下方「Build from Source」。

### v1.0.3 修复：百分比不显示

- 窗口枚举改为 `UIWindowScene.windows` + `keyWindow` + 旧 `windows` 去重 —— iOS 15+ 的控制中心常挂在 scene 上，旧的 `UIApplication.windows` 拿不到它的视图。
- 亮度/音量变化通知到达时立即重新扫描视图树（拖动滑条必然触发），不再等定时器。
- 放宽滑条识别：类名继承链、无障碍标签、父视图链、尺寸启发式。
- 完全找不到滑条时，在最上层窗口显示 1.2 秒的「音量/亮度 xx%」浮层作为保底；看到浮层即说明模块已被注入。
- 日志前缀 `[LiquidGlas]`，可用 `idevicesyslog` / `oslog` 查看 `loaded, windows=...`、`found volume slider: ...`、`fallback HUD: ...`。

**安装后必须 respring（或 ldrestart）**，dylib 的 constructor 只在进程加载时执行一次。

### v1.0.5 性能与可见性

- 去掉 0.5 秒整棵视图树轮询，改为事件驱动 + **2 秒轻量心跳**；扫描用 `class_getName` + `strcasestr` 做 C 字符串匹配，不再为每个视图分配 `NSString`、不再对无关视图做 KVC 异常探测；扫描深度 12、节点预算 3000、事件扫描 1 秒节流。
- 浮层从 `UIVisualEffectView`（实时模糊）换成普通半透明 `UIView`，去掉持续 GPU 模糊开销 —— 这是发热的主要来源之一。
- 控制中心可见期间**常驻显示**「音量 xx% / 亮度 xx%」浮层（8 秒生命周期，控制中心可见时持续延长），不再依赖识别私有滑条类名或先拖动滑条；识别到滑条时仍额外叠加数字。
- 保留 respring 后的「LiquidGlas 已加载 ✓」横幅，用于判断注入是否成功。日志前缀 `[LiquidGlas]`。

### v1.0.6 修复真正的根因 + 彩色图标

v1.0.2~1.0.5 的代码其实**从未在正确的进程里执行**：filter plist 只注入 `com.apple.springboard` / `SpringBoard`，而 iOS 17+ 的控制中心滑条属于独立的 `com.apple.controlcenter` 进程；constructor 里还有一道 bundle 判断把它挡掉。这版：

- filter plist 与 `AxsLiquidGlas.plist` 同时注入 `com.apple.springboard` + `com.apple.controlcenter`；模块不再按 bundle id 自我拦截（只跳过 chronod / WidgetRenderer / ClockAngel 这类扩展进程）。
- 用 `NSClassFromString` + `class_replaceMethod` 事件驱动 hook `CCUIContinuousSliderView` 的 `layoutSubviews` / `setValue:`，取代整棵视图树轮询；1 Hz 的 `dispatch_source` 只做有预算的类名发现，且在主队列。
- 数值以 `AVAudioSession.outputVolume` / `UIScreen.brightness` 为准，私有 `value` 只作 `@try` 保护的回退，并用 `maximumValue` 区分 0..1 与 0..100 量程。
- **彩色图标**：`LGGlyphScore` 在滑条子树里定位 glyph，`colorizeSliderIcons` 控制染色，私有颜色 setter 全部 `respondsToSelector` + `@try` 保护；`UIView + masksToBounds` 的填充层被排除，轨道/填充永不上色，避免鬼影描边。
- 领域模型：`LGSliderDescriptor` 表 + `LGPercentageController` 单一状态所有者（NSMapTable），新增第三种滑条只需加一行表项和一个设置单元。

新增设置：`colorizeSliderIcons`（默认开）、`sliderIconColor`（`#RRGGBB`，留空则用系统绿/蓝）。日志 `[LiquidGlas]`。

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