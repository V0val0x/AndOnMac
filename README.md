# AndOnMac

A native SwiftUI & VideoToolbox macOS application for mirroring, controlling, and transferring media with your Android smartphone at 60 FPS — with zero Electron bloat.

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](./LICENSE)
[![Platform: macOS 14+ / Android](https://img.shields.io/badge/Platform-macOS%2014%2B%20%7C%20Android-blue.svg)](https://github.com/V0val0x/AndOnMac)
[![GitHub Release](https://img.shields.io/github/v/release/V0val0x/AndOnMac?color=brightgreen)](https://github.com/V0val0x/AndOnMac/releases)
[![CI](https://github.com/V0val0x/AndOnMac/actions/workflows/ci.yml/badge.svg)](https://github.com/V0val0x/AndOnMac/actions/workflows/ci.yml)
[![Support on Ko-fi](https://img.shields.io/badge/Ko--fi-Support%20this%20project-ff5e5b?logo=ko-fi&logoColor=white)](https://ko-fi.com/kirillzaitsev)

**English** | [Русская версия (Russian)](README_RU.md)

![AndOnMac Mirroring Demo](./assets/demo-mirroring.gif)

### Feature Demos

| 60 FPS Mirroring & Shortcuts | Drag & Drop Photos to Mac Desktop (`Cmd+4`) | Universal Clipboard Sync (`macOS ↔ Android`) |
| :---: | :---: | :---: |
| ![Live Mirroring](./assets/demo-mirroring.gif) | ![Photo Transfer to Desktop](./assets/demo-photo-transfer.gif) | ![Universal Clipboard Sync](./assets/demo-clipboard-sync.gif) |

---

## Why AndOnMac?

| Capability | **AndOnMac** | Android File Transfer | OpenMTP | MacDroid | KDE Connect |
| :--- | :---: | :---: | :---: | :---: | :---: |
| **Native macOS UI (SwiftUI / AppKit)** | Yes (Swift 6) | Legacy | Electron | Native (Paid) | Qt |
| **Live 60 FPS Screen Mirroring (VideoToolbox)** | Yes | No | No | No | No |
| **Full Trackpad, Scroll & Keyboard Control** | Yes | No | No | No | Partial |
| **Bidirectional Photo & File Drag-and-Drop** | Yes (`Cmd+4`) | Broken / Legacy | File browser only | Paid | File send |
| **Device Audio Forwarding to Mac** | Yes | No | No | No | No |
| **macOS ↔ Android Keyboard Layout Sync** | Yes | No | No | No | No |
| **macOS Notification Center Integration** | Yes | No | No | No | Yes |
| **USB & Wireless Debugging (Bonjour mDNS)** | Yes | USB only | USB only | USB / Wi-Fi | Wi-Fi only |
| **Open-Source & Free (MIT)** | Yes | Proprietary | MIT | Proprietary | GPL |

---

## Features Implemented in This Codebase

- **Hardware-Accelerated 60 FPS Mirroring (`ScrcpyClient` + VideoToolbox):** Streams raw H.264 Annex-B frames from `scrcpy-server` over local ADB-forwarded TCP sockets and decodes them directly via `VTDecompressionSession` inside a frameless `NSView` (`ScrcpyDisplayNSView`) — no separate SDL video window in your Dock.
- **Device-Matched Floating Chassis (`PhoneFrameStyle`):** Auto-detects connected hardware and adapts bezel geometry, materials, and centered camera punch-hole for **Google Pixel (8/9/10)**, **Samsung Galaxy S / S Ultra**, **Xiaomi**, **Nothing Phone**, and **OnePlus** (plus Minimal and Borderless modes).
- **Bidirectional Photo & Media Drawer (`Cmd+4`, `PhotoTransferService`):** Pulls recent Camera photos and Screenshots from `/sdcard/DCIM` and `/sdcard/Pictures` for drag-and-drop into macOS apps/Finder, and pushes dropped images/APKs/files straight to `/sdcard/Download/`.
- **Real-Time Keyboard Layout Sync (`KeyboardLanguageSyncService`):** Observes macOS `TISNotifySelectedKeyboardInputSourceChanged` and switches Android `selected_input_method_subtype` / sends `KEYCODE_LANGUAGE_SWITCH`, with **Send on Enter** (`Shift+Return` for newline) for messengers.
- **Audio Forwarding (`MirrorService`):** Routes internal Android audio to Mac speakers via a hidden background `scrcpy` audio helper (`SDL_MAC_BACKGROUND_APP=1`).
- **USB & Wireless ADB Discovery (`ADBService` + `DiscoveryService`):** Supports 1-click USB-C mirroring, Android 11+ Wireless Debugging PIN pairing via Bonjour (`_adb-tls-pairing._tcp` / `_adb-tls-connect._tcp`), `dumpsys adb` `tls_port` extraction over USB, and saved device history.
- **macOS Notification Center Bridge (`NotificationService`):** Listens on TCP port `58241` for companion JSON notifications and QR discovery payloads, posting native `UNUserNotificationCenter` banners.

---

## Keyboard Shortcuts

| Shortcut | Action |
| :--- | :--- |
| `Cmd + 1` / Swipe up on Home bar | Home Screen (`KEYCODE_HOME`) |
| `Cmd + 2` / Swipe up and hold | App Switcher (`KEYCODE_APP_SWITCH`) |
| `Cmd + 3` | Notification Shade (`KEYCODE_NOTIFICATION`) |
| `Cmd + 4` | Toggle Photo & Media Transfer Drawer |
| `Cmd + Backspace` / `Esc` / Right-Click | Back |
| `Cmd + P` | Power / Lock / Wake Screen |
| `Cmd + 0` / `Cmd + +` / `Cmd + -` | Window Scale (100% / 125% / 75%) |
| `Cmd + Shift + R` | Reset ADB & Recover USB |
| `Cmd + W` | Stop Mirroring / Close Window |

---

## Installation & Quick Start

### Option 1: Homebrew Tap (Recommended — Zero Gatekeeper Hassle)
Because **AndOnMac** is completely free and open-source, it is distributed without a \$99/year Apple Developer ID certificate. Installing via the official Homebrew Tap automatically clears macOS Gatekeeper quarantine so the app launches right away:

```bash
brew install --cask V0val0x/andonmac/andonmac
```

To update later:
```bash
brew upgrade --cask andonmac
```

### Option 2: GitHub Releases (`.dmg`)
1. Download the latest `AndOnMac.dmg` from [**GitHub Releases**](https://github.com/V0val0x/AndOnMac/releases).
2. Open `AndOnMac.dmg` and drag **AndOnMac.app** into `/Applications`.
3. **Bypass macOS Gatekeeper** (required once for apps without a paid Apple Developer signature):
   * **Via Terminal (fastest):**
     ```bash
     xattr -cr /Applications/AndOnMac.app
     ```
   * **Via System Settings (macOS Sequoia / Sonoma):** Try opening `AndOnMac`, click **Done**/**Cancel** on the warning, then open **System Settings → Privacy & Security → Open Anyway**.
4. Connect your Android phone via USB-C (with **USB Debugging** enabled) or pair wirelessly via **Settings → Developer Options → Wireless Debugging**.

### Option 3: Build from Source (macOS 14+, Swift 5.9+ / 6.x)
```bash
# 1. Install runtime tools (bundled automatically into the .app)
brew install scrcpy android-platform-tools

# 2. Run unit & integration tests
swift test

# 3. Build standalone dist/AndOnMac.app and dist/AndOnMac.dmg
chmod +x scripts/*.sh
./scripts/create_dmg.sh
```

---

## Security & ADB Privacy Model

AndOnMac communicates **100% locally** between your Mac and your Android device — zero cloud servers, zero analytics, zero telemetry:

* **Explicit Phone Authorization (RSA / TLS):** Both USB Debugging and Android 11+ Wireless Debugging (`_adb-tls-pairing._tcp` / `_adb-tls-connect._tcp`) require you to physically unlock your phone and approve your Mac's RSA fingerprint.
* **No Shell / Flag Injection:** Device serials and `host:port` endpoints are strictly validated before invoking `adb`, and subprocesses use argument arrays (`Process.arguments`) rather than shell interpolation.
* **Accidental Data-Loss & Traversal Protection:** Remote file operations reject `..` traversal, null bytes, and destructive deletions (`rm -rf`) on protected Android system and media roots (`/`, `/sdcard`, `/sdcard/DCIM`, `/sdcard/Download`, `/system`).
* **Bounded Memory & Local Listeners:** The local notification listener (`:58241`) rejects payloads over 64 KB and truncates untrusted text; the H.264 stream parser caps buffers at 16 MB; and the photo cache auto-prunes at 200 MB.

---

## Architecture Overview

AndOnMac avoids heavyweight cross-platform runtimes by pairing a native **SwiftUI / AppKit** frontend with direct **VideoToolbox** H.264 decoding and **ADB / Bonjour** system services:

```mermaid
flowchart LR
    subgraph macOS["AndOnMac (macOS 14+ / Swift 6)"]
        UI["SwiftUI / AppKit UI\nMainWindowView · PhoneMirrorFrameView\nPhotoTransferDrawerView · WirelessPairingView"]
        VideoView["ScrcpyDisplayNSView\nMouse, Trackpad, Keyboard & Drag-Drop"]
        Client["ScrcpyClient\nvideoQueue + controlQueue\nAnnex-B Parser + VideoToolbox"]
        Mirror["MirrorService\nSession Lifecycle & Audio Helper"]
        ADB["ADBService\nUSB/Wi-Fi ADB · dumpsys adb"]
        Bonjour["DiscoveryService\nNetServiceBrowser mDNS"]
        Lang["KeyboardLanguageSyncService\nCarbon TIS -> IME Subtype"]
        Notify["NotificationService\nNWListener :58241 -> UNUserNotificationCenter"]
        Photos["PhotoTransferService\nDCIM/Screenshots <-> Mac Cache"]
    end

    subgraph Android["Android Device"]
        ADBD["adbd Daemon\nUSB / TLS Wireless Debugging"]
        Server["scrcpy-server\nH.264 Video + Control Socket"]
        Audio["scrcpy Audio Stream"]
        IMM["InputMethodManager / MediaStore / Companion"]
    end

    UI <--> VideoView
    VideoView <--> Client
    Mirror --> Client
    Mirror --> Audio
    Client <-->|"adb forward TCP\n(dummy byte + H.264 + control)"| Server
    ADB <--> ADBD
    Bonjour -.->|"_adb-tls-pairing / _adb-tls-connect"| ADBD
    Lang -->|"ADB subtype / keycode 204"| IMM
    Photos <-->|"adb pull / adb push"| IMM
    IMM -->|"TCP :58241 JSON / HTTP"| Notify
```

### Key Engineering Decisions
- **Separate `videoQueue` & `controlQueue`:** Decouples blocking control-message reads from raw Annex-B NAL parsing so the H.264 stream never stalls, while synchronized `VTDecompressionSession` teardown prevents lifecycle crashes.
- **Embedded `scrcpy-server` + Hidden Audio Helper:** Renders video natively inside SwiftUI/AppKit (`CGImage` backed by VideoToolbox) and delegates audio forwarding to a headless `scrcpy --no-video --no-control --no-window` child process with `SDL_MAC_BACKGROUND_APP=1` so the Dock stays clean.
- **Resilient Wireless Debugging Discovery:** Combines macOS Bonjour (`NetServiceBrowser`) with lossy UTF-8 parsing of `adb shell dumpsys adb` to extract active `tls_port` values even when Android's `ABX` binary keystore header is present.

---

## Support

If AndOnMac saves you time or makes working between macOS and Android smoother, you can leave a voluntary tip to support ongoing maintenance and testing:

[![Support on Ko-fi](https://img.shields.io/badge/Ko--fi-Leave%20a%20tip-ff5e5b?logo=ko-fi&logoColor=white)](https://ko-fi.com/kirillzaitsev)

*Contributions via Ko-fi are purely voluntary tips and do not include support SLAs, custom development commitments, or charitable tax deductions.*

---

## License & Legal Notices

MIT License © 2026 Kirill Zaitsev. See [LICENSE](./LICENSE).  
Screen mirroring and ADB transport bundle components from [Genymobile/scrcpy](https://github.com/Genymobile/scrcpy) and **Android Platform Tools (`adb`)** under the **Apache License 2.0**. Full attributions and license texts are provided in [THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md) (also bundled inside `AndOnMac.app/Contents/Resources/`).

*AndOnMac is an independent open-source project and is not affiliated with, endorsed by, or sponsored by Apple Inc., Google LLC, Samsung Electronics, Xiaomi, Nothing Technology, or OnePlus. All product names and trademarks belong to their respective owners and are used strictly for compatibility identification.*
