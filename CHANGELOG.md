# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- Release builds are signed with a stable certificate (when the `MACOS_CERT_P12_BASE64` / `MACOS_CERT_PASSWORD` secrets are set), so macOS keeps RemoteDesk's Accessibility and Screen Recording permissions across updates instead of asking again after each one.
- The app bundle is built in `build/RemoteDesk.noindex/` so the build copy does not show up in Spotlight next to the installed app.

## [1.1.0] - 2026-10-28

### Added
- **Fit Remote to This Screen**: the client tells the host which display it is on; the host switches its resolution to the closest-matching mode (aspect ratio first) so full screen fills edge to edge, and restores the original resolution when the client leaves (or if RemoteDesk quits). Toggle: *Window → Match Remote Resolution to This Screen* (on by default).
- **Trackpad gestures in full screen**: Spaces swipes, Mission Control, App Exposé and pinches are forwarded raw and replayed on the host, following this Mac's trackpad settings.
- **Full-screen edges**: the local Dock never appears in full screen — the bottom and side edges belong to the remote Mac; only the top edge reveals the local menu bar and window buttons (exit full screen / close).

### Changed
- The stream is captured at the host display's real pixel resolution (sharp on Retina clients), capped by `--max-dim` and by the client's screen size.
- Windowed mode keeps the remote screen's aspect ratio (no black bars).
- Mouse side buttons (back / forward) are forwarded with their real button number instead of as a middle click.

### Fixed
- Removed the implicit 0.25 s cross-fade on every decoded frame (lower display latency).
- The pointer can reach the remote's very last pixel row/column, so its Dock and hot corners trigger from the client.

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
