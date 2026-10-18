# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-10-18

### Added
- **Hardware-Accelerated Screen Streaming**: Near-zero latency H.264 encoding and decoding powered natively by Apple's `ScreenCaptureKit` and `VideoToolbox`.
- **Low-Latency Transport**: Custom lightweight TCP streaming protocol with big-endian length-prefixed framing and congestion control with hysteresis throttling.
- **Input Forwarding & Injection**: High-precision mouse movement, left/right/middle clicks, pixel-accurate dual-axis scrolling, and virtual keyboard event injection via macOS `CGEvent`.
- **"Capture All Input" Mode**: Full-screen input grabbing that intercepts macOS system shortcuts (`Cmd+Tab`, `Cmd+Space`, Mission Control) and routes them directly to the remote Mac with built-in escape hatches (`Ctrl+Opt+Cmd+G` release, `Ctrl+Opt+Cmd+Q` disconnect).
- **On-Screen Desktop Navigation**: Edge buttons and forwarded `Ctrl+arrow` shortcuts to navigate Spaces on the host machine.
- **Bidirectional Clipboard Sync**: Real-time text synchronization between host and client with loop-detection and 1 MB payload limits.
- **Bonjour & Direct Connect**: Zero-configuration local discovery via Bonjour (`_remotedesk._tcp`) or explicit `--connect host:port` flag.
- **Automated Testing Suite**:
  - Offline codec and protocol verification suite via `--self-test`.
  - Automated headless loopback verification via `scripts/e2e-test.sh` using synthetic frames (`--test-pattern`) without requiring TCC permissions.
  - Comprehensive Swift unit test target covering protocol serialization, boundary checks, and framing reassembly.
- **Universal Binary Distribution**: Full native support for both Apple Silicon (`arm64`) and Intel (`x86_64`) Macs in a standalone `.app` bundle and styled DMG installer.
