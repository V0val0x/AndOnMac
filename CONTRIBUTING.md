# Contributing to AndOnMac

Thank you for helping improve **AndOnMac**! Whether you are refining the 120Hz Metal/VideoToolbox pipeline, enhancing Vision OCR & Screen Memory, or improving the embedded DroidPath A* MCP server, your contributions are welcome.

Please review our [Code of Conduct](./CODE_OF_CONDUCT.md) and [Security Policy](./SECURITY.md) before opening an issue or Pull Request.

---

## Development Environment & Prerequisites

- **macOS:** `macOS 14+` (Sonoma or newer)
- **Toolchain:** Xcode 15.3+ / Swift 5.9+ (Swift 6 concurrency checks supported)
- **Runtime tools:** `adb` (`android-platform-tools`) and `scrcpy` (`brew install scrcpy android-platform-tools`)
- **JDK 17 & Android SDK:** Required **only** if modifying or rebuilding `android-daemon/`

---

## Building & Running Tests

Run the full build and test suite locally before submitting a Pull Request:

```bash
# 1. Build Swift package & run full XCTest suite (AndOnMacTests + AndroidShadowGraphKitTests)
swift build
swift test

# 2. Build standalone app bundle (.app)
./scripts/build_app.sh

# 3. Rebuild Kotlin headless daemon & single-DEX JAR (if android-daemon/ changed)
./android-daemon/scripts/build-dex.sh

# 4. Validate DMG packaging script syntax (if scripts/ changed)
bash -n scripts/create_dmg.sh
```

---

## Critical Architectural Invariants

1. **Cross-Repo `DroidPath` Parity:**
   - `android-daemon/src` MUST stay identical to [DroidPath](https://github.com/V0val0x/DroidPath) (`diff -rq AndOnMac/android-daemon/src DroidPath/android-daemon/src` empty).
   - `shadow_graph.json` format (64-bit FNV-1a hashes in `ScreenLayoutHasher`, camelCase fields, alternating-array `spanningChildren`, ISO-8601 UTC seconds, uppercase UUIDs, and `SeedGraphCatalog` anchors) MUST remain 100% compatible with Rust `droidpath-core`.
2. **Privacy & Security Boundaries:**
   - Never persist raw passwords, Luhn-valid payment card PANs, or 2FA/OTP codes (mask/redact before disk storage).
   - Keep embedded HTTP/SSE MCP listeners strictly bound to `127.0.0.1` with RFC 6454 `Origin`/`Host` validation and optional Bearer token enforcement.
   - Reject ADB serial/endpoint/flag injection and path-traversal deletions on protected Android paths.
3. **120Hz Main-Thread Discipline:** Keep video decoding (`HEVC`/`H.264`), SQLite FTS5 indexing, Vision OCR, and TCP daemon I/O off the main thread.

---

## Pull Request Workflow

1. **Fork** the repository and create a topic branch from `main` (e.g., `fix/metal-frame-resize` or `feat/mcp-seed-aliases`).
2. **Add unit tests** covering regressions or new features (`Tests/AndOnMacTests/` or `Tests/AndroidShadowGraphKitTests/`).
3. **Update docs** (`README.md`, `README_RU.md`, `docs/FEATURES.md`, `docs/FEATURES_RU.md`) when adding shortcuts, tools, or user-visible capabilities.
4. **Submit the PR** using the [Pull Request Template](./.github/PULL_REQUEST_TEMPLATE.md) and confirm GitHub Actions CI passes (`Build & Test (macOS)`).

---

## Reporting Bugs & Suggesting Features

- For security vulnerabilities or PII leaks, please **do not** file a public issue — report privately via [GitHub Security Advisories](https://github.com/V0val0x/AndOnMac/security/advisories/new) (see [SECURITY.md](./SECURITY.md)).
- For bugs and feature requests, use our [Issue Templates](https://github.com/V0val0x/AndOnMac/issues/new/choose).
