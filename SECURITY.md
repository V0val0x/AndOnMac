# Security Policy

## Supported Versions

| Version | Supported |
| :--- | :---: |
| `2.5.x` | ✅ Active |
| `2.4.x` | ⚠️ Upgrade to `2.5.x` |
| `< 2.4.0` | ❌ Unsupported |

## Built-In Security & Privacy Guarantees

AndOnMac runs 100% locally on your Mac with zero cloud telemetry:

- **Zero-PII On-Device & On-Disk:**
  - `android-daemon` masks `isPassword` and sensitive editable fields to `***` on-device before transmitting over TCP `:27189`.
  - `ScreenLayoutHasher` and `SpatialGraphEngine` redact Luhn-validated payment card PANs (`<CARD>`) and contextual 2FA/OTP codes (`<OTP>`) prior to hashing or persisting `shadow_graph.json`.
  - The pre-populated Android Settings Seed Graph (`SeedGraphCatalog`) contains zero device identifiers, zero coordinates, and zero user data.
  - Apple Vision OCR and SQLite FTS5 Screen Recall execute strictly on-device.
- **Strict Loopback Network Surface (`127.0.0.1`):**
  - Both `android-daemon` (`127.0.0.1:27189` via `adb forward`) and AndOnMac's built-in HTTP/SSE MCP server (`127.0.0.1:8765`) bind exclusively to loopback.
  - The MCP HTTP/SSE server enforces RFC 6454 loopback `Origin` and `Host` validation (blocking DNS rebinding and CSRF), strict `Content-Length` enforcement, and optional Bearer token authentication.
- **Mandatory Human-in-the-Loop (HITL) & Biometric Safety Gates:**
  - Hazardous actions (payments, purchases, transfers, deletions, factory resets) halt with `status: "requires_confirmation"` and a Yellow HUD prompt until explicitly approved.
  - `FLAG_SECURE` and biometric screens immediately pause automation (`secure_screen_active`, Blue HUD) until unlocked on the physical device.
- **Verified Release Integrity:**
  - Every GitHub Release publishes `checksums.txt` with the SHA-256 digest of `AndOnMac.dmg` so users can verify downloads with `shasum -a 256 -c checksums.txt`.

## Reporting a Vulnerability

Please **do not** report security vulnerabilities in public GitHub issues.

1. Use **GitHub Private Vulnerability Reporting** via the repository's **Security → Advisories → Report a vulnerability** page:
   https://github.com/V0val0x/AndOnMac/security/advisories/new
2. Include macOS version, AndOnMac version, reproduction steps, and potential impact.
3. We aim to acknowledge reports within **72 hours** and coordinate disclosure once a fix and verified release are published.
