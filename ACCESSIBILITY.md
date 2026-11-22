# Accessibility Statement — AndOnMac

**AndOnMac** is designed to make Android mirroring, screen recall, and AI-assisted device control accessible on macOS using native SwiftUI/AppKit controls alongside semantic Android Accessibility inspection.

## Accessibility Design & Commitments

- **Native macOS UI Controls:** Menus, settings, Recall Search (`Cmd+Shift+F`), Visual-to-MCP Capture Studio (`Cmd+Shift+M`), file browser (`Cmd+5`), and media drawer (`Cmd+4`) use standard macOS SwiftUI and AppKit components compatible with **VoiceOver**, **Full Keyboard Access**, and **High Contrast** / **Increase Contrast** appearances.
- **Full Keyboard Navigation & Shortcuts:** Core Android navigation and utility actions are exposed via standard macOS keyboard shortcuts (`Cmd+1` Home, `Cmd+2` App Switcher, `Cmd+3` Notifications, `Cmd+Backspace` / `Esc` Back, `Cmd+Shift+X` Vision OCR, `Cmd+Shift+F` Recall Search, `Cmd+Shift+M` Macro Studio, `Cmd+0`/`+`/`-` scaling) without requiring trackpad gestures.
- **Vision OCR & Semantic Shadow DOM Access:** For unselectable visual text inside the video mirror, `Cmd+Shift+X` runs on-device Apple Vision OCR to extract selectable text, while `android_get_ui_tree` / `android_explore_and_click` query Android's live `AccessibilityNodeInfo` semantic tree directly.
- **Non-Color-Only Agentic HUD Telemetry:** The 3-color **Agentic HUD** (**Red** autonomous execution, **Yellow** awaiting confirmation, **Blue** awaiting biometrics/`FLAG_SECURE`) pairs color indicators with descriptive overlay banners/tooltips and explicit MCP JSON states (`requires_confirmation`, `secure_screen_active`).

## Supported Environments

- **macOS Host:** macOS 14.0 (Sonoma) or newer on Apple Silicon and Intel Macs
- **Android Device:** Android 8.0+ (API 26+) with USB or Wireless ADB debugging

## Known Limitations

- The live `scrcpy` video surface (`MetalVideoRenderer`) renders pixel frames decoded from Android and does not expose native macOS VoiceOver child elements for Android UI widgets; users relying on assistive text access can use `Cmd+Shift+X` (Apple Vision OCR) or the structured Shadow DOM MCP tools (`android_get_ui_tree`).
- Android screens marked with `FLAG_SECURE` prevent visual capture and pause Shadow DOM inspection until unlocked on the physical device.

## Reporting Accessibility Barriers

If you encounter VoiceOver, keyboard focus, contrast, or workflow barriers in AndOnMac, please file an issue via our [Bug Report template](https://github.com/V0val0x/AndOnMac/issues/new/choose) describing your macOS version, assistive technology, and reproduction steps.
