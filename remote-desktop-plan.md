# RemoteDesk — Mac-to-Mac Remote Desktop: Implementation Plan

Status: draft v1 — 2026-10-18
Owner: personal project (hamou.de developer workspace)
Target: macOS 27 (26A434), arm64 both machines
Deliverable: `/Users/work/developer/RemoteDesk/` — a complete, buildable Swift package with CLI, tests and app bundle script.

---

## 0. Context & Goal

Personal-use Mac-to-Mac remote desktop: a Mac mini is the host (to be controlled),
a MacBook Pro is the client (used to program on the mini). Requirements:

- Screen sharing in near-real-time (H.264 hardware encode/decode).
- Remote input: mouse move/click/scroll, keyboard with modifier flags.
- Clipboard sync (text) in both directions.
- Bonjour discovery on the local network plus explicit `--connect host:port`.
- No third-party dependencies, no paid tools, no App Store.
- Buildable with Command Line Tools only (no full Xcode on this machine).

Out of scope for v1: audio, multiple displays, file transfer, encryption, NAT traversal.

---

## 1. Part 1 — Reverse-Engineering Analysis (evidence base)

The commercial reference implementation on this machine is Jump Desktop Connect
(`com.p5sys.jump.connect`, v10.15.44.0, build 168766464, sha256
`fa1ec93aa3a640f6327bae156f36dede283840b724bebd83028931ba6f4e5b85`), analyzed with REA
(no disassembler providers were available; evidence is strings, Mach-O metadata,
signature and framework inspection).

Key findings:

1. **Capture**: Jump uses ScreenCaptureKit on modern macOS —
   `SCStream`, `SCStreamOutput`, `stream:didOutputSampleBuffer:ofType:` — with a legacy
   `CGDisplayStream` path retained for older systems. This validates SCK as the capture API.
2. **Input**: the binary contains `CGEventTapCreate failed - accessibility permission
   required`, confirming CGEvent-based input injection and the Accessibility TCC dependency.
   No `CGEventPost` string appears (likely inlined/indirect), but CGEvent is the only
   sanctioned API family for this that matches the TCC message.
3. **Clipboard**: NSPasteboard provider strings are present; clipboard sync is a normal
   pasteboard-change-count polling pattern.
4. **Transport**: app ships its own WebRTC.framework (Google libwebrtc, ObjC API:
   `RTCPeerConnection`, `RTCVideoEncoderH264`, `RTCVideoDecoderH264`, `RTCMTL*Renderer`,
   `RTCDataChannel`), universal x86_64+arm64, 16,164,256 bytes, install name
   `@rpath/WebRTC.framework/WebRTC`, built against `DTSDKName=macosx14.0`.
   Codec symbol counts: H264 66, VP8 48, VP9 36, H265 20, AV1 12.
   JumpConnect also links `libaom 3.13.0` and `libdav1d 7.0.0` (AV1 software paths).
5. **VNC fallback**: strings `VNC Server` / `VNCPort=5900` show Jump also speaks RFB;
   this is a compatibility mode, not the primary protocol.
6. **App posture**: `LSUIElement=1` (menu-bar app), hardened runtime, team `2HCKV38EEC`,
   entitlements include `persistent-content-capture`, `usb.host-controller-interface`,
   `device.audio-input`; Sparkle auto-update; ATS exceptions for `amazonaws.com`
   (cloud relay). ObjC-only binary (77 objc classes, 445 dispatch implementations,
   0 `swift_*` symbols).

REA evidence IDs:
- Mach-O summary: `ev_04c60383abc7a13c0ca086502f3f13adb1beaca287ecd41caa3e8b14e68e7622`
  (parent evidence `ev_a5bce55402fdd804fb078f8d0b986c6d95921ab85f9f551e1ee450c3c971b9a0`).
- Code-signature inspection: `ev_eaa60b86f751c8e9f04bd73bea5a25be2e048fe1b32478674abbe4070b3ad063`.

Conclusion: Jump validates the SCK + CGEvent + NSPasteboard building blocks on this OS.
Its transport (libwebrtc + cloud relay) is not reproducible and not needed for a LAN tool.

---

## 2. Part 2 — Design Decisions

| Concern        | Decision                                   | Rationale |
|----------------|--------------------------------------------|-----------|
| Capture        | ScreenCaptureKit (`SCStream`)              | OS-blessed, matches Jump's modern path, screen-recording TCC |
| Codec          | VideoToolbox H.264 (HW)                    | Built into macOS, no deps, HW encode/decode on Apple Silicon |
| Transport      | Custom TCP with length-prefixed frames     | ~200 LOC, debuggable, LAN-reliable; no libwebrtc build |
| Discovery      | Bonjour `_remotedesk._tcp` + `--connect`   | Network.framework built-in; no config needed |
| Input          | CGEvent injection (mouse/scroll/key)       | Only sanctioned API; same keycodes as `NSEvent.keyCode` |
| Clipboard      | NSPasteboard changeCount polling 0.5 s     | Simple, robust; text-only in v1 |
| UI             | Programmatic AppKit (no storyboards)       | No Xcode GUI tooling available |
| Build          | SPM `swift build` + manual .app assembly   | Only CLT installed; ad-hoc codesign |

Rejected alternatives:
- **WebRTC transport**: Jump's WebRTC.framework is Google libwebrtc compiled for their
  app, not redistributable, huge, and integrating it without Xcode is a multi-week risk.
- **VNC (RFB)**: viable but the goal is a new tool with H.264 quality; VNC framebuffer
  encoding (RAW/Tight) would be a downgrade and reinvents client/server anyway.

Video pipeline (host):
`SCStream (BGRA CVPixelBuffer)` → `VTCompressionSession` (H.264, realtime,
`AllowFrameReordering=false`, AVCC 4-byte length-prefixed NAL units, keyframe ≤ 2 s)
→ framed `videoFrame` messages.

Video pipeline (client):
`videoConfig` (SPS/PPS) → `VTDecompressionSession` → `CVPixelBuffer` → `CALayer.contents`
(video layer, `resizeAspect`). Headless mode skips the layer and only counts frames.

---

## 3. Part 3 — Architecture & Data Flow

Components (all in `Sources/RemoteDesk/`):

```
HostController ── ScreenCapturer (SCK or TestPattern)
      │                │ CVPixelBuffer
      │                ▼
      │          VideoEncoder (VTCompressionSession)
      │                │ AVCC + SPS/PPS callbacks
      │                ▼
      │          PeerConnection ──── NWListener (TCP 8790, Bonjour _remotedesk._tcp)
      │                ▲                    │ bytes
      │          InputInjector ◄────────────┘ framed messages
      │          ClipboardSync (NSPasteboard poll)
      ▼
   AppDelegate / window status

ClientController ── NWBrowser / --connect ── PeerConnection
      │                                          │
      ▼                                          ▼
   RemoteView (CALayer.contents)          VideoDecoder (VTDecompressionSession)
      │ input events                             ▲
      └──────────────────────────────────────────┘ videoFrame / videoConfig
```

Concurrency model:
- All host state on one serial queue `remotedesk.host`; all client state on
  `remotedesk.client`. Encoder/decoder callbacks hop back to the owning queue.
- UI updates via `DispatchQueue.main.async`. Headless mode runs off `dispatchMain()`.
- Per-client send state (`PeerConnection`) is NSLock-guarded or queue-confined.

Congestion control (host → client):
- Track per-client `pendingBytes` (increment on send, decrement on `.contentProcessed`).
- If `pendingBytes > 4 MB`: skip non-keyframes for that client.
- If `pendingBytes < 1 MB` again: resume and request a fresh keyframe.
- Force keyframe on new client hello and after each resume.
- `videoConfig` (SPS/PPS) is cached and re-sent on hello and on encoder format change.

---

## 4. Part 4 — Wire Protocol (v1)

Framing (both directions, TCP):

```
[UInt32 big-endian length = payload.count + 1][UInt8 type][payload bytes]
```

- Max frame 64 MB; smaller violations close the connection.
- Strings: UTF-8, UInt32 length prefix, hard cap 1 MB.

Message types:

| #  | Name            | Direction | Payload |
|----|-----------------|-----------|---------|
| 1  | hello           | C → H     | UInt16 version(1) + string clientName |
| 2  | helloAck        | H → C     | UInt8 status(0=ok) + UInt32 width + UInt32 height + string hostName |
| 3  | videoConfig     | H → C     | UInt32 setCount + per set: UInt32 len + NAL bytes (SPS/PPS) |
| 4  | videoFrame      | H → C     | UInt8 flags (bit0 = keyframe) + UInt64 timestamp µs + AVCC payload |
| 5  | mouseMove       | C → H     | F32 x + F32 y + UInt64 flags |
| 6  | mouseButton     | C → H     | UInt8 button (0 L / 1 R / 2 other) + UInt8 down + UInt64 flags |
| 7  | scroll          | C → H     | F32 dx + F32 dy + UInt64 flags |
| 8  | key             | C → H     | UInt16 keyCode + UInt8 down + UInt64 flags |
| 9  | ping            | both      | UInt64 timestamp |
| 10 | pong            | both      | UInt64 timestamp (echo) |
| 11 | requestKeyframe | C → H     | (empty) |
| 12 | clipboard       | both      | UInt8 kind (0=text) + string (cap 1 MB) |
| 13 | bye             | both      | (empty) |

Coordinate convention: mouse x/y normalized 0..1 against the video frame,
origin top-left. Host maps to the main display's pixel bounds.

Modifier flags: raw `NSEvent.modifierFlags.rawValue` rides on every key/mouse/scroll
message (no synthetic flagsChanged events). Host applies them via `CGEvent.flags`.
Key codes: `NSEvent.keyCode` is the same virtual keycode CGEvent expects — forwarded
directly (layout-dependent; same keyboard layout expected on both Macs).

Timers / liveness:
- Host: hello expected within 10 s of connect, else close.
- Client: ping every 10 s; host echoes pong immediately (no timeout enforcement in v1).
- Encoder: keyframe at least every 2 s (`MaxKeyFrameInterval`, `MaxKeyFrameIntervalDuration=2`).

Error model: `ProtocolError { invalidLength, unknownType, truncated, badString, tooLarge, malformed }`.
`FrameDecoder` buffers arbitrary TCP chunks and splits complete frames.

---

## 5. Part 5 — Permissions (TCC)

| Permission | Needed by | When | Notes |
|------------|-----------|------|-------|
| Screen Recording | Host (real capture) | First SCK stream | Not needed with `--test-pattern` |
| Accessibility | Host (input injection) | First CGEvent post | Prompt via `AXIsProcessTrustedWithOptions` |
| Local Network / Bonjour | Both | First listener/browser | Firewall "allow incoming" prompt on host |

Deep links:
- `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`
- `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`

Constraints:
- TCC cannot be granted programmatically; the host UI shows an alert with the deep link.
- Ad-hoc signed builds: keep the .app at a stable path; rebuilding at the same path
  normally keeps grants, moving/re-signing may reset them.
- Consequence: real-capture GUI E2E is not automatable. `--test-pattern` (synthetic
  frames, no capture, no injection) makes the whole pipeline testable without TCC.
- The final acceptance test (Mac mini ↔ MacBook Pro over the LAN) is a manual step.

---

## 6. Part 6 — Project Layout

```
/Users/work/developer/RemoteDesk/
├── Package.swift                    swift-tools 6.0, .macOS(.v14), swiftLanguageMode(.v5)
├── README.md                        build/run/permissions/troubleshooting
├── Resources/
│   └── Info.plist                   bundle id local.remotedesk, Bonjour service, usage strings
├── scripts/
│   ├── make-app.sh                  release build + .app assembly + ad-hoc codesign
│   └── e2e-test.sh                  self-test + test-pattern host + headless client, expect 30 frames
└── Sources/RemoteDesk/
    ├── main.swift                   entry, RunMode switch, runApp/runHeadless
    ├── Options.swift                CLI parsing (exit 2 on usage error)
    ├── Log.swift                    stderr logging with levels + NSLock
    ├── Protocol.swift               framing, ByteReader/ByteWriter, message codecs
    ├── PeerConnection.swift         NWConnection wrapper: receive loop, send, pendingBytes
    ├── HostController.swift         listener, clients, pipeline wiring, congestion control
    ├── ClientController.swift       browse/connect, decode path, input send, headless result lines
    ├── ScreenCapturer.swift         SCStream wrapper (frame status filtering, onError)
    ├── TestPattern.swift            synthetic frames (CVPixelBufferPool + DispatchSourceTimer)
    ├── VideoEncoder.swift           VTCompressionSession → AVCC + SPS/PPS callbacks
    ├── VideoDecoder.swift           VTDecompressionSession, configure/decode/invalidate
    ├── InputInjector.swift          CGEvent mouse/scroll/key + accessibility prompt
    ├── RemoteView.swift             CALayer.contents view, letterbox mapping, key handling
    ├── ClipboardSync.swift          NSPasteboard changeCount polling both directions
    ├── AppDelegate.swift            window, launcher, host/client session lifecycle
    └── SelfTest.swift               protocol round-trips, framing splits, codec loop
```

Package.swift essentials:
- `// swift-tools-version: 6.0`
- `platforms: [.macOS(.v14)]`
- one executableTarget `RemoteDesk`, path `Sources/RemoteDesk`
- `swiftSettings: [.swiftLanguageMode(.v5)]` (avoids strict-concurrency churn)
- no external dependencies, no test target (SelfTest is a CLI mode)

Info.plist essentials:
- `CFBundleIdentifier = local.remotedesk`, `CFBundlePackageType = APPL`
- `NSPrincipalClass = NSApplication`, `LSMinimumSystemVersion = 14.0`
- `NSBonjourServices = [_remotedesk._tcp]`, `NSLocalNetworkUsageDescription`
- `NSSupportsAutomaticGraphicsSwitching = true`

---

## 7. Part 7 — Testability & Verification

1. `RemoteDesk --self-test` (no TCC, no network):
   - protocol round-trips for every message type (encode → parse → re-encode equality),
   - framing: reassembly across awkward 3-byte chunk splits,
   - codec loop: 5 solid-color 640×360 buffers → encoder → decoder → ≥ 2 decoded frames,
     dimension check 640×360. Prints `SELF-TEST: ALL PASS` or `FAIL:` lines (exit 1).
2. `scripts/e2e-test.sh` (no TCC, loopback):
   - `--host --test-pattern --no-ui --port 8799` in background,
   - wait for `HOST READY` on stderr,
   - `--client --connect 127.0.0.1:8799 --headless --no-ui --expect-frames 30 --timeout 20`,
   - client prints `RESULT: OK frames=N` and exits 0. Script prints `E2E: PASS`.
3. Manual acceptance (user, on the real pair):
   - `swift build -c release && scripts/make-app.sh`, open `RemoteDesk.app` on the mini,
     "Share This Mac", grant TCC prompts, run client on the MacBook Pro, connect by
     Bonjour name or `--connect mini.local:8790`; verify video, input, clipboard.
4. Headless result contract (used by scripts):
   - OK → stdout `RESULT: OK frames=N`, exit 0; timeout → exit 2; disconnect → exit 3.

---

## 8. Part 8 — Milestones & Status

| # | Milestone | Status |
|---|-----------|--------|
| 1 | REA analysis of reference app + design decisions | done (Part 1–2) |
| 2 | Plan document (this file) | done |
| 3 | Scaffold (Package.swift, Info.plist, README, scripts) | done |
| 4 | Protocol + PeerConnection + self-test transport portions | done |
| 5 | Video: encoder, decoder, TestPattern; codec self-test | done |
| 6 | Capture, input injection, clipboard | done |
| 7 | Host/Client controllers + congestion control | done |
| 8 | UI: RemoteView, AppDelegate launcher/session | done |
| 9 | `swift build` clean, self-test pass, e2e pass | done |
| 10 | .app bundle + codesign, final usage/permission report | done |

---

## 9. CLI Reference

```
RemoteDesk --host [--port N] [--test-pattern] [--no-ui] [--max-dim N] [--fps N] [--bitrate N] [--name S] [--size WxH]
RemoteDesk --client [--connect HOST[:PORT] | --browse] [--no-ui] [--headless] [--expect-frames N] [--timeout S]
RemoteDesk --self-test
```

| Flag | Default | Meaning |
|------|---------|---------|
| `--port` | 8790 | TCP port |
| `--test-pattern` | off | synthetic frames instead of capture (no TCC) |
| `--no-ui` / `--headless` | off | run without window; requires host or client mode |
| `--connect H[:P]` | — | direct connect (default port 8790; no IPv6 literal) |
| `--browse` | — | Bonjour browse for first `_remotedesk._tcp` host |
| `--expect-frames` | — | headless client: exit 0 after N decoded frames |
| `--timeout` | 30 | headless client overall timeout (s) |
| `--max-dim` | 2560 | cap longest capture dimension (aspect preserved, even) |
| `--fps` | 60 | capture/encode frame rate (1–120) |
| `--bitrate` | 8_000_000 | average bitrate bps (≥ 100000) |
| `--name` | hostName | advertised name |
| `--size WxH` | 1280x720 | test-pattern size |
| `--verbose` | off | DEBUG logs |
| `--help` | — | usage, exit 0 |

Parse errors print usage to stderr and exit 2.

---

## 10. Risks & Fallbacks

| Risk | Mitigation |
|------|------------|
| C-imported `...WithOutputHandler` VT signatures differ in Swift | verify at first `swift build`; fall back to callback+refCon pattern |
| `CFNumber`/`CFBoolean` bridging friction | build-iterate; use `unsafeBitCast` where needed |
| `layer.contents = CVPixelBuffer` requires IOSurface backing | decoder attrs request BGRA+IOSurface; UI falls back to CGImage if needed |
| Decoder rejects IOSurface attrs | fallback attempt with nil pixel-buffer attrs |
| `CMBlockBufferCopyDataBytes` pointer plumbing | `withUnsafeMutableBytes` + explicit base address; validated by self-test |
| SCK API naming drift on macOS 27 | use `SCStreamConfiguration` basics only; TestPattern keeps tests green regardless |
| TCC cannot be automated | test-pattern + headless E2E; manual real-capture checklist |
| Congestion re-keyframe storms on slow links | hysteresis 4 MB/1 MB + only keyframe on resume, not every frame |
| Keycode layout mismatch between machines | documented limitation; same layout assumed |

---

## 11. v1 Known Limitations

- No authentication or encryption — plaintext LAN traffic; trusted networks only.
- Single display (main display) only.
- No audio.
- No `Cmd+Tab` / `Cmd+Space` forwarding; `Cmd+Q` is intercepted locally
  (`Ctrl+Opt+Cmd+Q` = disconnect).
- Scroll direction may feel inverted on some clients (direct mapping of deltas).
- Key forwarding is layout-dependent (virtual keycodes, not characters).
- First run requires granting Screen Recording and Accessibility on the host and
  confirming the firewall prompt for incoming connections.
