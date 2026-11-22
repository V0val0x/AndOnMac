## Summary

<!-- Describe what this PR changes and why. -->

## Related Issue

<!-- Closes #... -->

## Type of Change

- [ ] Bug fix (non-breaking change fixing an issue)
- [ ] New feature / enhancement
- [ ] Performance or 120Hz Metal rendering improvement
- [ ] Security / Privacy hardening
- [ ] Documentation / Community / CI update

## Verification Checklist

- [ ] Ran `swift build && swift test` (all XCTest suites pass)
- [ ] Verified `./scripts/build_app.sh` succeeds (if app bundle or resources changed)
- [ ] Verified `android-daemon/src` parity & `shadow_graph.json` compatibility with `DroidPath` (if daemon or graph code changed)
- [ ] Confirmed no PII (real passwords, card PANs, OTPs, personal accounts) in tests or Seed Graph data
- [ ] Updated `README.md`, `README_RU.md`, and `docs/FEATURES*.md` if user-facing behavior changed
