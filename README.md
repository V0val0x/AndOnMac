# AndOnMac

A native SwiftUI, VideoToolbox & Metal macOS application for mirroring, controlling, and transferring media with your Android smartphone at **up to 120 FPS (ProMotion)** — with zero Electron bloat.

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](./LICENSE)
[![Platform: macOS 14+ / Android](https://img.shields.io/badge/Platform-macOS%2014%2B%20%7C%20Android-blue.svg)](https://github.com/V0val0x/AndOnMac)
[![GitHub Release](https://img.shields.io/github/v/release/V0val0x/AndOnMac?color=brightgreen)](https://github.com/V0val0x/AndOnMac/releases)
[![CI](https://github.com/V0val0x/AndOnMac/actions/workflows/ci.yml/badge.svg)](https://github.com/V0val0x/AndOnMac/actions/workflows/ci.yml)
[![Support on Ko-fi](https://img.shields.io/badge/Ko--fi-Support%20this%20project-ff5e5b?logo=ko-fi&logoColor=white)](https://ko-fi.com/kirillzaitsev)

**English** | [Русская версия (Russian)](README_RU.md) · [Full Feature Guide & Architecture](docs/FEATURES.md)

![AndOnMac Mirroring Demo](./assets/demo-mirroring.gif)

### Feature Demos

| Up to 120 FPS Mirroring & Gestures | Drag & Drop Photos to Mac Desktop (`Cmd+4`) | Universal Clipboard Sync (`macOS ↔ Android`) |
| :---: | :---: | :---: |
| ![Live Mirroring](./assets/demo-mirroring.gif) | ![Photo Transfer to Desktop](./assets/demo-photo-transfer.gif) | ![Universal Clipboard Sync](./assets/demo-clipboard-sync.gif) |

---

## Highlights

- **120Hz ProMotion Engine:** Hardware-accelerated `HEVC` (with `H.264` fallback), zero-copy `CAMetalLayer` + `120Hz CADisplayLink` rendering, adaptive bitrate, and a live Performance HUD.
- **Instant Connectivity & Isolation Bypass:** USB-C, Android 11+ QR-Code / Bonjour Wi-Fi pairing, silent USB-to-Wi-Fi handoff, and 1-click **Direct Hotspot / Bluetooth PAN** bypass on isolated public Wi-Fi.
- **Standalone App Windows & Menu Bar Control:** Search and launch any Android app (including system apps like YouTube & Chrome) into its own virtual macOS window (`Launch Android App`), plus 1-click toggles from the Menu Bar.
- **Photos (`Cmd+4`), File Manager (`Cmd+5`) & Continuity:** Drag-and-drop photos, APKs, and files bidirectionally, and sync Mac clipboard text & screenshots straight to Android.
- **On-Device AI, Vision OCR & Screen Memory:** Grab unselectable text via Apple Silicon Vision OCR (`Cmd+Shift+X`), search your opt-in screen history with **Recall** (`Cmd+Shift+F`, local SQLite FTS5), and connect Claude/Cursor via the built-in **MCP Server**.

> Deep dive into MCP configuration, security model, all shortcuts, and system architecture: [**docs/FEATURES.md**](docs/FEATURES.md).

---

## Why AndOnMac?

| Capability | **AndOnMac** | Android File Transfer | OpenMTP | MacDroid | KDE Connect |
| :--- | :---: | :---: | :---: | :---: | :---: |
| **Native macOS UI (SwiftUI / AppKit)** | Yes (Swift 6) | Legacy | Electron | Native (Paid) | Qt |
| **Up to 120 FPS Mirroring (VideoToolbox + Metal)** | Yes | No | No | No | No |
| **Trackpad Gestures, Audio & Clipboard Sync** | Yes | No | No | No | Partial |
| **Bidirectional Photo (`Cmd+4`) & File Manager (`Cmd+5`)** | Yes | Broken / Legacy | File browser only | Paid | File send |
| **Built-in MCP Server, Vision OCR & Screen Recall** | Yes | No | No | No | No |
| **USB, QR Wi-Fi Pairing & Hotspot/BT Bypass** | Yes | USB only | USB only | USB / Wi-Fi | Wi-Fi only |
| **Open-Source & Free (MIT)** | Yes | Proprietary | MIT | Proprietary | GPL |

---

## Installation & Quick Start

### Option 1: Homebrew Tap (Recommended — Zero Gatekeeper Hassle)
```bash
brew install --cask V0val0x/andonmac/andonmac
```
To update later: `brew upgrade --cask andonmac`.

### Option 2: GitHub Releases (`.dmg`)
1. Download the latest `AndOnMac.dmg` from [**GitHub Releases**](https://github.com/V0val0x/AndOnMac/releases).
2. Drag **AndOnMac.app** into `/Applications` and clear Gatekeeper once (since the app is free and not notarized with a paid Apple Developer ID):
   ```bash
   xattr -cr /Applications/AndOnMac.app
   ```
   *(Or via **System Settings → Privacy & Security → Open Anyway**.)*
3. Connect via USB-C (**USB Debugging** enabled) or pair wirelessly via **Settings → Developer Options → Wireless Debugging**.

### Option 3: Build from Source (macOS 14+, Swift 5.9+ / 6.x)
```bash
brew install scrcpy android-platform-tools
swift test
chmod +x scripts/*.sh && ./scripts/create_dmg.sh
```

---

## Essential Shortcuts

| Shortcut | Action |
| :--- | :--- |
| `Cmd + 1` / `Cmd + 2` / `Cmd + 3` | Home / App Switcher / Notification Shade |
| `Cmd + 4` / `Cmd + 5` | Photo Drawer / Android File Manager |
| `Cmd + Shift + X` / `Cmd + Shift + F` | Apple Vision Screen OCR / Recall Screen Memory |
| `Cmd + Shift + R` / `Cmd + W` | Reset ADB & USB / Stop Mirroring |

See the full shortcuts and gestures table in [**docs/FEATURES.md**](docs/FEATURES.md#keyboard-shortcuts--gestures).

---

## Support & License

[![Support on Ko-fi](https://img.shields.io/badge/Ko--fi-Leave%20a%20tip-ff5e5b?logo=ko-fi&logoColor=white)](https://ko-fi.com/kirillzaitsev)

MIT License © 2026 Kirill Zaitsev. See [LICENSE](./LICENSE).

Bundles components from [Genymobile/scrcpy](https://github.com/Genymobile/scrcpy) and **Android Platform Tools (`adb`)** under the Apache License 2.0 ([THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md)).
