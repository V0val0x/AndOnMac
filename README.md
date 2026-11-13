# AndOnMac 📱⚡️💻

<p align="center">
  <img src="https://img.shields.io/badge/Platform-macOS%2014%2B-blue?style=for-the-badge&logo=apple" />
  <img src="https://img.shields.io/badge/Swift-6.0-orange?style=for-the-badge&logo=swift" />
  <img src="https://img.shields.io/badge/License-MIT-green?style=for-the-badge" />
  <img src="https://img.shields.io/github/v/release/V0val0x/AndOnMac?style=for-the-badge&color=brightgreen" />
</p>

**English** | [Русская версия (Russian)](README_RU.md)

> **Native open-source Apple iPhone Mirroring alternative for Android and Google Pixel on macOS.**

A modern native macOS application allowing you to mirror and interact with your Android smartphone with ultra-low latency, full trackpad and keyboard control, audio streaming, and bidirectional file transfers.

---

## ✨ Features

* 📱 **1-in-1 Apple iPhone Mirroring Design**: Photorealistic floating smartphone bezel with titanium curved edges, dynamic camera punch-hole, and native Home bar gestures — rendering live 60 FPS Android display embedded natively with Apple VideoToolbox.
* 🖼 **Bidirectional Photo & Media Transfer**: Pull recent camera photos and screenshots from your phone to Mac via drag-and-drop (`Cmd+4`), and drop images/videos from Mac into Android Gallery with automatic media indexing.
* ⚡️ **Zero-Friction Setup**:
  * **Method 1 (3-Second USB Setup)**: Plug in USB-C cable once, tap "Allow" on phone — Mac automatically promotes the device to Wi-Fi mode and remembers it permanently.
  * **Method 2 (Wireless Pairing Code)**: Connect wirelessly using Android 11+ Wireless Debugging with Apple Bonjour auto-discovery.
* 🔒 **Screen Off While Mirroring**: Keep phone physical display off to preserve battery life and privacy while working on your Mac.
* 🔊 **Audio Forwarding**: Stream internal Android system audio and video sound directly to your Mac speakers.
* 🔔 **macOS Notification Integration**: Push notifications from Android apps appear natively in macOS Notification Center.
* ⌨️ **Native Shortcuts & Gestures**: Swipe up on Home bar, smooth two-finger trackpad scrolling, universal clipboard (`Cmd+C`/`Cmd+V`), and keyboard shortcuts (`Cmd+1` Home, `Cmd+2` App Switcher, `Cmd+3` Notifications, `Cmd+4` Photos Drawer).
* 📁 **Drag & Drop Transfers**: Drag photos, APKs, and documents from Mac Finder directly onto your phone screen.

---

## 🚀 Quick Start

### Download Pre-built Installer
Download the latest release disk image: [**AndOnMac.dmg (Releases)**](https://github.com/V0val0x/AndOnMac/releases).  
Open `AndOnMac.dmg` and drag `AndOnMac.app` into your **Applications** folder.

```bash
# Optional Homebrew installation of CLI tools (also bundled inside app):
brew install scrcpy android-platform-tools
```

---

## 📶 Connection Methods

| Method | Instructions | Highlights |
| :--- | :--- | :--- |
| **🔌 Type-C Cable (Recommended)** | 1. Plug USB-C cable into Mac.<br>2. Tap "Allow" on phone display.<br>3. *Unplug cable anytime — wireless continuity stays active.* | **3 seconds**: Zero manual IP configuration, automatic TCP/IP Wi-Fi promotion. |
| **⚡️ Over Wi-Fi (Pairing PIN)** | 1. On phone: *Settings → Developer Options → Wireless Debugging → "Pair with pairing code"*.<br>2. On Mac: Phone is auto-discovered via Apple Bonjour.<br>3. Enter the 6-digit PIN. | **Wireless**: Seamless local mDNS discovery and auto-connect. |
| **🕒 Saved Devices** | Click "Connect" next to your previously paired phone in the Saved Devices tab. | **1-click**: Instant reconnect without re-entering PIN codes. |

---

## ⌨️ Keyboard Shortcuts (Apple Mirroring Shortcuts)

| Shortcut | Action |
| :--- | :--- |
| `Cmd + 1` / Swipe up on Home bar | Home Screen |
| `Cmd + 2` / Swipe up and hold | App Switcher (Recent Apps) |
| `Cmd + 3` | Notification Shade |
| `Cmd + 4` | Phone Photos & Screenshots Drawer (Drag & Drop to Mac) |
| `Cmd + Backspace` / `Esc` / Right-Click | Back |
| `Cmd + P` | Power / Lock / Wake Display |
| `Cmd + 0` / `Cmd + +` / `Cmd + -` | Window Scaling (100%, 125%, 75%) |

---

## 🛠 Architecture & Tech Stack

* **Frontend**: Swift 6.0, SwiftUI, AppKit (targeting macOS 14.0+ Sonoma & Sequoia).
* **Networking**: Apple `Network.framework` (Bonjour mDNS / NWBrowser for `_adb-tls-pairing._tcp` and `_adb-tls-connect._tcp`).
* **Streaming Engine**: [scrcpy](https://github.com/Genymobile/scrcpy) (H.264 / H.265 / Opus decoding).
* **CI/CD Pipeline**: Automated GitHub Actions workflow on Apple Silicon runners (`macos-15`).

---

## 📄 License

MIT License © 2026 Zaitcev Kirill.  
Screen mirroring core leverages open-source components from Genymobile scrcpy (Apache 2.0).
