# AndOnMac

Native macOS app (SwiftUI, VideoToolbox, Metal) for mirroring, controlling, and exchanging files with Android at up to **120 FPS (ProMotion)**.

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](./LICENSE)
[![Platform: macOS 14+ / Android](https://img.shields.io/badge/Platform-macOS%2014%2B%20%7C%20Android-blue.svg)](https://github.com/V0val0x/AndOnMac)
[![GitHub Release](https://img.shields.io/github/v/release/V0val0x/AndOnMac?color=brightgreen)](https://github.com/V0val0x/AndOnMac/releases)
[![CI](https://github.com/V0val0x/AndOnMac/actions/workflows/ci.yml/badge.svg)](https://github.com/V0val0x/AndOnMac/actions/workflows/ci.yml)
[![Support on Ko-fi](https://img.shields.io/badge/Ko--fi-Support%20this%20project-ff5e5b?logo=ko-fi&logoColor=white)](https://ko-fi.com/kirillzaitsev)

**English** | [Русская версия](README_RU.md) · [Feature Guide & Architecture](docs/FEATURES.md)

| Persistent A* Symbolic UI Router ([DroidPath](https://github.com/V0val0x/DroidPath)) |
| :---: |
| ![Persistent A* Symbolic UI Router](./assets/demo-droidpath-presentation.gif) |

| 120 FPS Mirroring & Gestures | Device Frames & Ambilight | Photo Transfer (`Cmd+4`) | Clipboard Sync (`macOS ↔ Android`) |
| :---: | :---: | :---: | :---: |
| ![Live Mirroring](./assets/demo-mirroring.gif) | ![Device Frames & Ambilight](./assets/demo-frames-ambilight.gif) | ![Photo Transfer to Desktop](./assets/demo-photo-transfer.gif) | ![Universal Clipboard Sync](./assets/demo-clipboard-sync.gif) |

## Overview

- **120Hz Metal Pipeline:** Hardware-decoded `HEVC` (with `H.264` fallback), `CAMetalLayer` + `CADisplayLink` rendering, adaptive bitrate, audio forwarding, and a toggleable Performance HUD.
- **Connectivity:** USB-C, Android 11+ QR / Bonjour Wi-Fi pairing, automatic USB-to-Wi-Fi handoff, and 1-click Hotspot / Bluetooth PAN fallback on isolated networks.
- **App Windows & File Transfer:** Launch individual Android apps in separate macOS windows, drag and drop photos (`Cmd+4`), browse files (`Cmd+5`), and sync clipboard text and screenshots.
- **On-Device OCR & Recall:** Grab unselectable text with Apple Vision (`Cmd+Shift+X`) and search local screen history with SQLite FTS5 (`Cmd+Shift+F`).
- **Device Frames & Ambilight:** Vector bezels with camera cutouts for Pixel, Galaxy S, Nothing Phone, and OnePlus devices, paired with CoreImage edge lighting and trackpad gestures.
- **Agentic Routing & MCP ([DroidPath](https://github.com/V0val0x/DroidPath)):** Headless Kotlin `android-daemon` binds strictly to `127.0.0.1` loopback, masks `isPassword` fields to `"***"`, and streams Shadow DOM updates and `FLAG_SECURE` events over ADB TCP (`:27189`) into a persistent Spatial Graph (`shadow_graph.json`, normalized across clocks, dates, prices `<PRICE>`, `<ETA>`, `<WEIGHT>`, Luhn card numbers `<CARD>`, OTP codes `<OTP>`, decorative banners, and `systemui` overlays). `android_navigate_to_node` (with `auto_explore: true`) and `android_explore_and_click` run A* pathfinding and cold-start UI exploration locally with forward-skip, `Back-to-Root` task-stack drift recovery, `Smart Scroll-to-Selector`, `consecutiveFailures` edge decay/self-pruning, universal popup dismissal, Human-in-the-Loop confirmation (`requires_confirmation` / `confirmed: true`) for payment/destructive steps, `FLAG_SECURE` biometric handoff, a 3-color 120Hz Agentic HUD (**Red** autonomous, **Yellow** awaiting confirmation, **Blue** awaiting biometrics), Visual-to-MCP macros (`Cmd+Shift+M`), and bundled LLM onboarding rules (`.cursorrules`, `CLAUDE.md`, `GEMINI.md`, `docs/system_prompt.md`).

Details on MCP setup, security, shortcuts, and architecture: [docs/FEATURES.md](docs/FEATURES.md).

## Comparison with Alternatives

Existing solutions rely on stateless ADB bindings, adding 2–4 seconds of latency per action and forcing the LLM to micromanage the UI step by step. AndOnMac uses a persistent Directed Acyclic Graph (DAG) and A* routing on macOS, cutting latency to `<1s` per click and removing LLM overhead on known routes.

| Tool | UI & Automation Model | Latency / Action | LLM Overhead | Mirroring & HUD |
| :--- | :--- | :---: | :--- | :--- |
| **Mobile MCP / Maestro MCP / adbridge** | Stateless ADB / `uiautomator` wrappers | 2–4 s | LLM plans every tap/scroll | None |
| **Appium / CursorTouch** | WebDriver sessions or vision/coordinate loops | 2–5 s | Heavy screenshot / selector polling | External / VNC |
| **AndOnMac + DroidPath** | Persistent DAG + A* router + live Shadow DOM daemon | `<1s` / hop | `0` intermediate calls on known routes | 120Hz Metal + live HUD |

## Installation

### Homebrew (Recommended)
```bash
brew install --cask V0val0x/andonmac/andonmac
```
Update: `brew upgrade --cask andonmac`.

### `.dmg` Release
1. Download `AndOnMac.dmg` from [GitHub Releases](https://github.com/V0val0x/AndOnMac/releases).
2. Move **AndOnMac.app** to `/Applications` and clear Gatekeeper quarantine (the app is unsigned):
   ```bash
   xattr -cr /Applications/AndOnMac.app
   ```
3. Connect via USB-C (**USB Debugging**) or pair over Wi-Fi (**Wireless Debugging**).

### Build from Source (macOS 14+, Swift 5.9+)
```bash
brew install scrcpy android-platform-tools
swift test
chmod +x scripts/*.sh && ./scripts/create_dmg.sh
```

## Shortcuts

| Shortcut | Action |
| :--- | :--- |
| `Cmd + 1` / `Cmd + 2` / `Cmd + 3` | Home / App Switcher / Notification Shade |
| `Cmd + 4` / `Cmd + 5` | Photo Drawer / Android File Manager |
| `Cmd + Shift + X` / `Cmd + Shift + F` | Vision Screen OCR / Recall Screen History |
| `Cmd + Shift + R` / `Cmd + W` | Reset ADB & USB / Stop Mirroring |

Full shortcut and gesture reference: [docs/FEATURES.md](docs/FEATURES.md#keyboard-shortcuts--gestures).

## Ecosystem & Companion Packages

Cross-platform companion and standalone Swift packages (`macOS 14+`, MIT):

| Repository | Purpose | Platform / Integration |
| :--- | :--- | :--- |
| [**DroidPath**](https://github.com/V0val0x/DroidPath) | Cross-platform Rust A* UI router, Tauri v2 Desktop HUD, `npx droidpath` 1-click CLI & Kotlin Shadow DOM daemon (100% `shadow_graph.json` compatible with AndOnMac) | Windows · Linux · macOS (`npx droidpath` / Rust / Tauri v2) |
| [**MetalScrcpyKit**](https://github.com/V0val0x/MetalScrcpyKit) | VideoToolbox H.264/HEVC decoder, `CAMetalLayer` renderer & ABR engine | `.package(url: "https://github.com/V0val0x/MetalScrcpyKit.git", from: "1.0.0")` |
| [**ADBConnectKit**](https://github.com/V0val0x/ADBConnectKit) | Swift ADB SDK: USB, Wi-Fi QR pairing, Bonjour & Hotspot/BT PAN bypass | `.package(url: "https://github.com/V0val0x/ADBConnectKit.git", from: "1.0.0")` |
| [**AndroidMCPKit**](https://github.com/V0val0x/AndroidMCPKit) | MCP Server (`stdio` / SSE), Visual-to-MCP macros & `android-mcp` CLI | `.package(url: "https://github.com/V0val0x/AndroidMCPKit.git", from: "1.0.0")` |
| [**VisionScreenRecallKit**](https://github.com/V0val0x/VisionScreenRecallKit) | Apple Vision OCR, delta gating & SQLite FTS5 screen recall | `.package(url: "https://github.com/V0val0x/VisionScreenRecallKit.git", from: "1.0.0")` |

## License

[![Support on Ko-fi](https://img.shields.io/badge/Ko--fi-Leave%20a%20tip-ff5e5b?logo=ko-fi&logoColor=white)](https://ko-fi.com/kirillzaitsev)

MIT License © 2026 Kirill Zaitsev. See [LICENSE](./LICENSE).

Bundles components from [Genymobile/scrcpy](https://github.com/Genymobile/scrcpy) and Android Platform Tools (`adb`) under Apache 2.0 ([THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md)).
