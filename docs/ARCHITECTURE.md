# RemoteDesk Architecture

This document outlines the architecture, data flow, wire protocol, and concurrency model of RemoteDesk — a lightweight, native Mac-to-Mac remote desktop application built entirely with Swift, ScreenCaptureKit, VideoToolbox, and Network.framework.

---

## 1. System Overview

RemoteDesk operates as a peer-to-peer system over a trusted local area network (LAN):
- **Host (Server)**: Captures screen frames via Apple's ScreenCaptureKit, hardware-encodes them to H.264 via VideoToolbox, and streams them over a custom TCP socket. It receives input events (mouse, keyboard, scroll) and injects them into the macOS event stream via `CGEvent`.
- **Client (Viewer)**: Connects to the host (via Bonjour or direct IP:port), hardware-decodes H.264 NAL units via VideoToolbox, renders frames directly onto a hardware-accelerated `CALayer`, and captures local user input (including system shortcuts during full-screen capture) to forward to the host.

```
       +-------------------------------------------------------------+
       |                         HOST MAC                            |
       |                                                             |
       |  [ScreenCaptureKit]                                         |
       |          │ CVPixelBuffer (BGRA)                             |
       |          ▼                                                  |
       |  [VideoToolbox Encoder] (H.264 Hardware Compression)        |
       |          │ AVCC NAL units + SPS/PPS                         |
       |          ▼                                                  |
       |  [HostController] ──── [NWListener] (TCP 8790 / mDNS)       |
       |          ▲                      │                           |
       |          │                      │                           |
       |  [InputInjector] ◄──────────────┤ (Framed Input Messages)   |
       |  (CGEvent Injection)            │                           |
       |                                 │                           |
       |  [ClipboardSync] ◄──────────────┘                           |
       |  (NSPasteboard)                                             |
       +--------------------------------─┬───────────────────────────+
                                         │ TCP (Plaintext Stream)
                                         ▼
       +--------------------------------─┴───────────────────────────+
       |                        CLIENT MAC                           |
       |                                                             |
       |  [NWConnection / NWBrowser]                                 |
       |          │ Length-prefixed Frames                           |
       |          ▼                                                  |
       |  [ClientController] ──► [VideoDecoder] (VTDecompression)    |
       |          │                     │ CVPixelBuffer              |
       |          │                     ▼                            |
       |          │               [RemoteView]                       |
       |          │               (CALayer.contents hardware render) |
       |          ▼                                                  |
       |  [InputGrabber] (Session Event Tap for Full-Screen)         |
       |          │ Forwarded Keystrokes & Mouse Coordinates         |
       |          ▼                                                  |
       |  [ClipboardSync] (NSPasteboard Polling & Injection)         |
       +-------------------------------------------------------------+
```

---

## 2. Video Pipeline

### Host Capture & Encoding
1. **ScreenCaptureKit (`SCStream`)**:
   - Captures primary display frames as BGRA `CVPixelBuffer`s.
   - Automatically drops duplicate/idle frames when screen content is static.
   - Constrains maximum resolution to `options.maxDimension` (default: 2560px) maintaining aspect ratio with even pixel boundaries for hardware encoder compatibility.
2. **VideoToolbox Compression (`VTCompressionSession`)**:
   - Profile: H.264 Baseline/Main, realtime mode (`kVTCompressionPropertyKey_RealTime = true`).
   - `AllowFrameReordering = false` (zero B-frames to eliminate display latency).
   - Generates AVCC-formatted 4-byte length-prefixed NAL units.
   - Periodic IDR keyframes forced at least every 2 seconds (`MaxKeyFrameIntervalDuration = 2.0`).
   - Extract SPS (Sequence Parameter Set) and PPS (Picture Parameter Set) on initialization and format changes, transmitted out-of-band via `videoConfig` packets.

### Client Decoding & Hardware Presentation
1. **VideoToolbox Decompression (`VTDecompressionSession`)**:
   - Reconstructed using SPS/PPS parameter sets received in `videoConfig`.
   - Incoming `videoFrame` AVCC payloads are wrapped into `CMBlockBuffer` and `CMSampleBuffer` instances with presentation timestamps.
   - Output requested as 32-bit BGRA `IOSurface`-backed pixel buffers.
2. **Direct Layer Presentation (`CALayer`)**:
   - The decoded `CVPixelBuffer` is assigned directly to `remoteView.layer?.contents`.
   - macOS QuartzCompositor and Metal compositor render the `IOSurface` directly without extra memory copies or CPU-bound color conversions.

---

## 3. Wire Protocol Specification (v1)

### Framing
All communication over TCP uses binary length-prefixed frames:

```
+───────────────────────────────+───────────+──────────────────────────+
|  Length (4 bytes, Big-Endian) | Type (1B) | Payload (Length - 1 B)   |
+───────────────────────────────+───────────+──────────────────────────+
```

- **Length**: Total frame length including the 1-byte message type and payload (capped at 64 MB; invalid lengths terminate connection).
- **Strings**: UTF-8 encoded, prefixed by a 4-byte big-endian length (capped at 1 MB).
- **Coordinates**: Mouse coordinates are normalized floats `[0.0, 1.0]` relative to top-left of the display area.

### Message Catalog

| ID | Type | Direction | Payload Structure |
|:---|:-----|:----------|:------------------|
| `1` | `hello` | Client → Host | `UInt16` version (`1`) + `String` clientName |
| `2` | `helloAck` | Host → Client | `UInt8` status (`0=OK`) + `UInt32` width + `UInt32` height + `String` hostName |
| `3` | `videoConfig` | Host → Client | `UInt32` count + `[UInt32 length + bytes]` per parameter set (SPS/PPS) |
| `4` | `videoFrame` | Host → Client | `UInt8` flags (`bit 0`: keyframe) + `UInt64` timestampMicros + `[UInt8]` AVCC data |
| `5` | `mouseMove` | Client → Host | `Float32` x + `Float32` y + `UInt64` modifierFlags |
| `6` | `mouseButton` | Client → Host | `UInt8` button (`0=left, 1=right, 2=other`) + `UInt8` down + `UInt64` flags |
| `7` | `scroll` | Client → Host | `Float32` dx + `Float32` dy + `UInt64` modifierFlags |
| `8` | `key` | Client → Host | `UInt16` keyCode + `UInt8` down + `UInt64` modifierFlags |
| `9` | `ping` | Both | `UInt64` timestampMicros |
| `10` | `pong` | Both | `UInt64` timestampMicros (echoed) |
| `11` | `requestKeyframe`| Client → Host | Empty payload |
| `12` | `clipboard` | Both | `UInt8` kind (`0=plain text`) + `String` text (≤ 1 MB) |
| `13` | `bye` | Both | Empty payload |
| `14` | `displayInfo` | Client → Host | `UInt8` flags (`bit 0`: match host resolution) + `UInt32` pointWidth + `UInt32` pointHeight + `UInt32` pixelWidth + `UInt32` pixelHeight |
| `15` | `gesture` | Client → Host | Raw `CGEvent` data (`CGEvent.data`, ≤ 64 KB) of a trackpad gesture (type 29) or Dock-control (type 30) event |

Messages `14` and `15` are additive: peers that don't know a message type skip it, so older hosts and clients keep working.

---

## 4. Concurrency & Queue Architecture

RemoteDesk uses Grand Central Dispatch (GCD) with strict queue confinement to prevent race conditions:

- **Host Serial Queue (`remotedesk.host`)**: Owns all host controller state, client connection tables, and network socket dispatch.
- **Encoder Serial Queue (`remotedesk.host.encoder`)**: Offloads VideoToolbox compression callbacks and feeds encoded packets back to `remotedesk.host`.
- **Client Serial Queue (`remotedesk.client`)**: Owns client networking, frame decoding, and outbound event dispatch.
- **Main Thread (`DispatchQueue.main`)**: Dedicated strictly to UI presentation, AppKit window lifecycle, and pasteboard polling timers.

### Congestion Control
To avoid buffer bloat over slow or congested Wi-Fi links:
- Tracks outbound `pendingBytes` per client via `NSLock`.
- **Throttle**: If `pendingBytes > 4 MB`, the host drops all non-keyframe delta packets for that client.
- **Hysteresis Recovery**: When `pendingBytes < 1 MB`, normal streaming resumes and a fresh keyframe is immediately requested from the encoder.

---

## 5. Input System & Capture Modes

### Normal Windowed Mode
In windowed mode, mouse clicks, movements, and standard keystrokes received by `RemoteView` are forwarded to the host as normalized coordinates and `NSEvent.keyCode` values.

### "Capture All Input" Mode (Full-Screen)
When entering full-screen mode (or via `Ctrl+Opt+Cmd+G`), RemoteDesk installs an active session `CGEventTap` (`.cgSessionEventTap` at `.headInsertEventTap`):
- Intercepts system shortcuts (`Cmd+Tab`, `Cmd+Space`, Mission Control keys) before macOS handles them locally.
- Forwards them directly to the host while swallowing local execution.
- Swallows local trackpad gestures (types 29 / 30) and forwards them raw; the host decodes them with `CGEvent(withDataAllocator:data:)`, accepts only gesture types, and replays them, so Spaces swipes / Mission Control act on the remote Mac.
- **Emergency Escape Hatches (never forwarded)**:
  - `Ctrl+Opt+Cmd+G`: Release input capture.
  - `Ctrl+Opt+Cmd+Q`: Disconnect session immediately.
  - Automatic release if RemoteDesk loses window focus.

---

### Full-Screen Presentation
The full-screen window uses `[.fullScreen, .autoHideMenuBar, .hideDock]`: the local Dock never appears, so the bottom and side edges reach the remote Mac; only the top edge reveals the local menu bar and title-bar buttons.

### Fitting the Remote Screen to the Client
After the first `helloAck` the client sends `displayInfo` (its screen size, minus the notch area). The host (`DisplayModeMatcher` + `DisplayFit`) switches its main display to the best-matching mode with `CGConfigureOption.forAppOnly` (macOS reverts it automatically if the app exits), restarts capture at the new size — never larger than the client's screen — and re-sends `helloAck` with the new dimensions. The original mode is restored when the last client disconnects.

## 6. Clipboard Synchronization

Bidirectional clipboard synchronization is handled by `ClipboardSync`:
- Polls `NSPasteboard.general.changeCount` every 500ms on the main thread.
- If a new string is detected (capped at 1 MB UTF-8), it is broadcast to the peer.
- Circular loop prevention: `suppressChangeCount` is set when applying incoming remote text, preventing echo broadcasts.
