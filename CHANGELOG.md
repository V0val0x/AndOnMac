# Changelog

All notable changes to **AndOnMac** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.5.0] - 2026-11-22

### Added
- **Cross-Device Zero-PII Android Settings Seed Graph (`SeedGraphCatalog`) & Seed-to-Real Hydration:** Pre-populates new graphs with 20 canonical `com.android.settings` screens and 19 deterministic edges (EN/RU + Pixel/AOSP/OneUI/HyperOS/OxygenOS semantic aliases, zero coordinates, zero PII) that automatically hydrate into exact device hashes, selectors, and coordinates on first live traversal (opt-out via `DROIDPATH_DISABLE_SEED_GRAPH=1`). 100% bit-exact `shadow_graph.json` interoperability with cross-platform Rust `DroidPath v2.2.0`.
- **Release SHA-256 Integrity Manifest (`checksums.txt`):** `scripts/create_dmg.sh` and GitHub Actions release workflow now generate and publish `checksums.txt` alongside `AndOnMac.dmg`.
- **Repository Security & Release Hygiene:** Added `SECURITY.md` and `CHANGELOG.md`.

### Security
- **Strict RFC 6454 Loopback HTTP/SSE Hardening:** Enforced exact loopback `Origin` and `Host` validation plus `Content-Length` enforcement on `MCPHTTPServer` (`127.0.0.1:8765`).

## [2.4.1] - 2026-11-21

### Fixed
- Synced `android-daemon` resync/input fixes with `DroidPath v2.1.1`.
- Fixed Swift cancellation and keycode parity across `AndroidMCPTools` and `ShadowGraphBridge`.

## [2.4.0] - 2026-11-21

### Added
- Native `UiAutomation` input injection over daemon TCP `:27189` with zero-fling 120Hz swipes and `adb` fallback.
- Unified 2.0s 1x presentation showcase GIF across documentation.

## [2.3.0] - 2026-11-19

### Added
- `android_explore_and_click` dynamic cold-start discovery, `auto_explore: true`, Luhn `<CARD>` and `<OTP>` PII scrubbing, `Back-to-Root` drift recovery, `Smart Scroll-to-Selector`, `consecutiveFailures` edge decay, and 3-color 120Hz Agentic HUD.

## [2.2.0] - 2026-11-15

### Added
- Persistent A* Symbolic UI Router (`AndroidShadowGraphKit`) and headless Kotlin Shadow DOM daemon (`android-daemon.jar`).

## [2.0.0] - 2026-11-13

### Added
- Native macOS SwiftUI, VideoToolbox, and Metal 120Hz Android mirroring pipeline, QR/Bonjour Wi-Fi pairing, Continuity, Apple Vision OCR, SQLite FTS5 Recall, Device Frames & Ambilight, Photo Drawer, File Manager, and built-in MCP server.
