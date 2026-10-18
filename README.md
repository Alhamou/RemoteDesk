# RemoteDesk

Personal Mac-to-Mac remote desktop. Share one Mac's screen (host) and control it from another Mac (client) over the local network.

- **Host**: ScreenCaptureKit capture → VideoToolbox H.264 → length-prefixed TCP stream.
- **Client**: decodes H.264, displays it, forwards mouse/keyboard/scroll/clipboard events.

Built as a plain Swift package (no Xcode project required). macOS 14+.

## Requirements

- macOS 14 or newer on both Macs.
- Swift toolchain (Xcode or Command Line Tools) to build.
- Both Macs on the same local network (Bonjour discovery, or `--connect host:port`).
- Host needs **Screen Recording** permission (and **Accessibility** for input injection).
  - `Scripts`/`--test-pattern` mode runs TCC-free for automated testing.

## Build

```sh
swift build -c release
```

Build a launchable app bundle (ad-hoc signed):

```sh
./scripts/make-app.sh          # produces build/RemoteDesk.app
```

## Run

### Host (the Mac being controlled)

```sh
.build/release/RemoteDesk --host
```

or launch `build/RemoteDesk.app` and click **Share This Mac**.

### Client (the Mac you sit at)

```sh
.build/release/RemoteDesk --client --connect mac-mini.local
```

or launch the app and click **Connect to a Mac** (leave the field empty to browse via Bonjour).

#### Full-screen input capture

Entering full screen (green button or `Ctrl+Cmd+F`) automatically enables
**Capture All Input**: keyboard events — including system-grabbed shortcuts
like `Cmd+Tab`, `Cmd+Space`, Mission Control keys — are intercepted before
macOS acts on them and forwarded to the host, and trackpad gesture events
(Spaces swipes) are blocked locally. Three/four-finger swipes are decoded
from the raw gesture stream and re-fired on the host as their keyboard
equivalents, so they switch the **remote** Mac's desktops:

| Gesture on client | Action on host |
| --- | --- |
| 3/4-finger swipe left / right | `Ctrl+←` / `Ctrl+→` — switch space |
| 3/4-finger swipe up / down | `Ctrl+↑` (Mission Control) / `Ctrl+↓` (App Exposé) |

The gesture field mapping was verified with `--gesture-probe` (logs raw
type-29 events to stdout and `/tmp/rd-gesture-probe.log`); if swipes stop
registering after a macOS update, re-run the probe and adjust the fields
in `InputGrabber.handleSwipeGesture`.

| Shortcut | Action |
| --- | --- |
| `Ctrl+Opt+Cmd+G` | Toggle capture (auto-on in full screen, auto-off on exit) |
| `Ctrl+Opt+Cmd+Q` | Disconnect |

Capture requires the **client** Mac to also grant Accessibility
(System Settings → Privacy & Security → Accessibility). Without it, the
first full screen / toggle attempt shows the native permission prompt and
an inline hint; the permission applies live once granted. If the RemoteDesk
window loses key status while capture is on, keys pass through locally as
a safety valve.

## CLI Flags

| Flag | Default | Meaning |
| --- | --- | --- |
| `--host` | | Run as host |
| `--client` | | Run as client |
| `--self-test` | | Run codec/protocol self-test and exit |
| `--port N` | `8790` | TCP port (host listen / client connect) |
| `--test-pattern` | | Host streams a synthetic pattern instead of the screen (no TCC) |
| `--no-ui` | | Headless mode (`--headless` is an alias) |
| `--expect-frames N` | | Headless client exits 0 after N decoded frames |
| `--connect H[:P]` | | Connect directly instead of Bonjour; default port 8790 |
| `--browse` | | Force Bonjour discovery |
| `--timeout S` | `30` | Headless client overall timeout |
| `--max-dim N` | `2560` | Host: cap the longest captured dimension |
| `--fps N` | `60` | Capture frame rate (1–120) |
| `--bitrate N` | `8000000` | Encoder average bitrate, bits/s |
| `--name S` | host name | Name advertised over Bonjour |
| `--size WxH` | `1280x720` | Test-pattern size |
| `--verbose` | | Debug logging on stderr |
| `--gesture-probe N` | | Debug: log raw trackpad gesture events for N seconds |
| `--help` | | Usage and exit |

Parse errors print usage to stderr and exit with code 2.

## Permissions

1. **Screen Recording** — required for real capture on the host.
   System Settings → Privacy & Security → Screen Recording.
2. **Accessibility (host)** — required for the host to inject mouse/keyboard events.
   System Settings → Privacy & Security → Accessibility.
3. **Accessibility (client)** — required on the client Mac for full-screen
   input capture (`Ctrl+Opt+Cmd+G`). Same pane; optional otherwise.

The host triggers the native macOS permission prompts directly on first share — RemoteDesk shows no permission popups of its own. Missing permissions are reported as inline status text, and the host window's Permissions button opens the relevant System Settings pane. Screen Recording additionally requires quitting and reopening RemoteDesk after it is granted. Rebuilding the bundle re-signs it with a new ad-hoc signature and macOS may require re-approval — keep the app path stable.

The macOS firewall may ask to allow incoming connections; accept it.

## Testing

Self-test (codec + protocol, no permissions needed):

```sh
.build/debug/RemoteDesk --self-test
```

End-to-end test (test-pattern host + headless client over loopback):

```sh
./scripts/e2e-test.sh
```

Real-capture testing between the two Macs is manual: run the host on the Mac mini, grant Screen Recording/Accessibility, then connect from the MacBook Pro.

## Limitations (v1)

- No authentication or encryption — plaintext, trusted LAN only.
- Primary display only; no audio.
- Clipboard sync is text-only, capped at 1 MB.
- Trackpad gestures are re-fired as keyboard equivalents during input capture
  (swipe = Ctrl+arrows); raw gesture forwarding is not supported by the protocol.
- Gesture decoding uses private CGEvent fields (mapped empirically); verify with
  `--gesture-probe` after major macOS updates.
- Key forwarding assumes the same keyboard layout on both Macs.

## Troubleshooting

- **"Screen capture permission required"** — grant Screen Recording and relaunch the app.
- **Input does nothing on the controlled Mac** — grant Accessibility on the host.
- **Client cannot find the host** — use `--connect <host>:<port>`; check the firewall.
- **`swift build` fails under Command Line Tools** — install Xcode or update CLT; the SDK must provide ScreenCaptureKit and VideoToolbox APIs used here.
