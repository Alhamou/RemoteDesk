# Contributing to RemoteDesk

Thank you for your interest in contributing to RemoteDesk! RemoteDesk is an open-source, zero-dependency Mac-to-Mac remote desktop tool built with native macOS frameworks.

---

## Development Prerequisites

- **Operating System**: macOS Sonoma (14.0) or newer (macOS 14+ is required for ScreenCaptureKit modern APIs).
- **Toolchain**: Swift 6.0 toolchain (included with Xcode 16+ or the Command Line Tools).
- **Hardware**: Apple Silicon (arm64) or Intel (x86_64) Mac.

No third-party packages, CocoaPods, or Carthage dependencies are required.

---

## Local Development Workflow

### 1. Clone the Repository
```bash
git clone https://github.com/Alhamou/RemoteDesk.git
cd RemoteDesk
```

### 2. Build the Executable
```bash
# Debug build
swift build

# Release build
swift build -c release
```

### 3. Run the Test Suites
RemoteDesk includes both unit tests and an automated end-to-end loopback test:

```bash
# Run unit tests (protocol encode/decode, framing, bounds)
swift test

# Run codec & protocol self-test
.build/debug/RemoteDesk --self-test

# Run end-to-end headless loopback test (runs without needing TCC permissions)
./scripts/e2e-test.sh
```

### 4. Build and Test the Application Bundle
```bash
./scripts/make-app.sh
open build/RemoteDesk.noindex/RemoteDesk.app
```

> [!NOTE]
> `make-app.sh` automatically signs the app with your local Apple Development certificate if available, preserving macOS TCC permissions (Screen Recording and Accessibility) across rebuilds.

---

## Release Signing

Pushing a `v*` tag runs `.github/workflows/release.yml`, which builds and publishes the DMG. To keep users' Accessibility and Screen Recording permissions across updates, every release must be signed with the same certificate. Ad-hoc signed builds get a new code identity each time, so macOS asks for the permissions again after every update and input capture (keyboard + trackpad gestures) stops working until they are re-granted.

The workflow signs with a certificate from two repository secrets (Settings → Secrets and variables → Actions):

| Secret | Value |
|:---|:---|
| `MACOS_CERT_P12_BASE64` | The signing certificate and its private key exported as `.p12`, base64-encoded |
| `MACOS_CERT_PASSWORD` | The password chosen when exporting the `.p12` |

To set them up from a Mac that has the certificate:

1. In **Keychain Access → My Certificates**, right-click the `Apple Development: …` (or `Developer ID Application: …`) certificate, choose **Export**, and save it as `cert.p12` with a password.
2. Upload it and its password, then delete the exported file:
   ```bash
   base64 -i cert.p12 | gh secret set MACOS_CERT_P12_BASE64
   gh secret set MACOS_CERT_PASSWORD
   rm cert.p12
   ```

Without these secrets the release still builds, ad-hoc signed, and the workflow logs a warning. When the certificate expires, export the renewed one and update both secrets. Local builds (`./scripts/make-app.sh`) sign with the same certificate when it is in your keychain, so local and released builds share their permissions.

---

## Code Guidelines & Philosophy

1. **Zero External Dependencies**: We intentionally do not use third-party libraries. All networking, encoding, decoding, capture, and UI logic relies solely on Apple's standard system frameworks (`ScreenCaptureKit`, `VideoToolbox`, `Network.framework`, `AppKit`).
2. **Swift Concurrency & Confinement**: Keep thread and queue boundaries clear. State mutability on the host is confined to `remotedesk.host`, and client state to `remotedesk.client`. UI updates must always run on the main thread.
3. **No Hidden Telemetry**: RemoteDesk is strictly peer-to-peer on the local network. No tracking, analytics, or external phone-home requests are permitted.
4. **Safety & Fallbacks**: Provide non-panicking error handling for malformed wire packets or unexpected network disconnections.

---

## Pull Request Guidelines

1. Create a feature branch: `git checkout -b feature/your-feature-name`.
2. Ensure `swift test` and `./scripts/e2e-test.sh` pass cleanly with zero failures.
3. Verify that your changes do not introduce new compiler warnings (`swift build -c release`).
4. Update `CHANGELOG.md` under `[Unreleased]` with a brief description of the change.
5. Submit a pull request referencing any relevant issue numbers.

Please adhere to the project's [Code of Conduct](CODE_OF_CONDUCT.md).
