import AppKit
import CoreGraphics

/// Client-side "Capture All Input" mode.
///
/// While active, a session-level CGEventTap intercepts keyboard events
/// (keyDown / keyUp / flagsChanged) **before** macOS acts on them, forwards
/// them to the remote host, and swallows them locally. System-grabbed
/// shortcuts — Cmd+Tab, Cmd+Space, Mission Control keys… — therefore run on
/// the remote Mac instead of this one.
///
/// Trackpad gesture events (the swipes macOS uses to switch Spaces /
/// trigger Mission Control) are swallowed locally as well; they cannot be
/// forwarded with the current protocol — switch the remote's desktops via
/// the on-screen buttons in RemoteView or the forwarded keyboard
/// equivalents (Ctrl+←/→, Ctrl+↑…).
///
/// Two combos are reserved and never forwarded:
///   - Ctrl+Opt+Cmd+G — release input (end capture mode)
///   - Ctrl+Opt+Cmd+Q — disconnect
///
/// Requires the **client** Mac to grant RemoteDesk Accessibility
/// (System Settings → Privacy & Security → Accessibility). Applies live,
/// no relaunch needed.
final class InputGrabber {
    enum Reserved {
        case releaseInput
        case disconnect
    }

    /// Called on the main thread when a reserved combo is pressed while captured.
    var onReserved: ((Reserved) -> Void)?
    /// Capture only while this returns true (e.g. our window is key).
    var shouldCapture: (() -> Bool)?
    weak var controller: ClientController?

    private(set) var isActive = false

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// keyDown = 10, keyUp = 11, flagsChanged = 12; 29 is kCGEventGesture
    /// (private constant, referenced numerically on purpose).
    private static let eventMask: CGEventMask =
        (1 << CGEventType.keyDown.rawValue)
        | (1 << CGEventType.keyUp.rawValue)
        | (1 << CGEventType.flagsChanged.rawValue)
        | (1 << 29)

    private static let gestureType = CGEventType(rawValue: 29)

    /// Sticky modifier state bits that would break the reserved-combo match.
    private static let noiseRaw: UInt64 =
        CGEventFlags.maskAlphaShift.rawValue
        | CGEventFlags.maskNumericPad.rawValue
        | CGEventFlags.maskSecondaryFn.rawValue
    private static let reservedRaw: UInt64 =
        CGEventFlags.maskCommand.rawValue
        | CGEventFlags.maskControl.rawValue
        | CGEventFlags.maskAlternate.rawValue
    /// Device-independent modifier bits (NSEvent.deviceIndependentFlagsMask).
    private static let deviceIndependentRaw: UInt64 = 0xFFFF0000

    private static let releaseKeyCode: Int64 = 5    // "G"
    private static let disconnectKeyCode: Int64 = 12 // "Q"

    /// Creates the event tap. Returns false (without side effects) when the
    /// client has not been granted Accessibility.
    @discardableResult
    func start() -> Bool {
        guard !isActive else { return true }
        guard PermissionFlow.accessibilityGranted else {
            Log.warn("input capture requires Accessibility permission on the client")
            return false
        }
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passRetained(event) }
            let grabber = Unmanaged<InputGrabber>.fromOpaque(userInfo).takeUnretainedValue()
            return grabber.handleEvent(type: type, event: event)
        }
        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.eventMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.error("failed to create input-capture event tap")
            return false
        }
        tap = newTap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        runLoopSource = source
        CFRunLoopAddSource(RunLoop.main.getCFRunLoop(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        isActive = true
        Log.info("input capture ON (Ctrl+Opt+Cmd+G to release)")
        return true
    }

    func stop() {
        guard isActive else { return }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(RunLoop.main.getCFRunLoop(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        tap = nil
        isActive = false
        Log.info("input capture OFF")
    }

    // MARK: - Event handling (runs on the main run loop)

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The tap can get disabled by the system (timeout / secure input);
            // re-enable so capture never silently dies.
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)

        case .keyDown:
            guard isActive, shouldCapture?() ?? true else { return Unmanaged.passRetained(event) }
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let rawFlags = event.flags.rawValue
            let cleanFlags = rawFlags & Self.deviceIndependentRaw & ~Self.noiseRaw
            if cleanFlags == Self.reservedRaw {
                let reserved: Reserved?
                switch keyCode {
                case Self.releaseKeyCode: reserved = .releaseInput
                case Self.disconnectKeyCode: reserved = .disconnect
                default: reserved = nil
                }
                if let reserved {
                    onReserved?(reserved)
                    return nil
                }
            }
            controller?.sendKey(
                keyCode: UInt16(clamping: keyCode),
                down: true,
                flags: UInt64(rawFlags)
            )
            return nil

        case .keyUp:
            guard isActive, shouldCapture?() ?? true else { return Unmanaged.passRetained(event) }
            controller?.sendKey(
                keyCode: UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode)),
                down: false,
                flags: UInt64(event.flags.rawValue)
            )
            return nil

        case .flagsChanged:
            guard isActive, shouldCapture?() ?? true else { return Unmanaged.passRetained(event) }
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            // Mirror RemoteView.flagsChanged: only report actual down/up edges.
            let isDown: Bool
            switch keyCode {
            case 54, 55: isDown = flags.contains(.maskCommand)
            case 56, 60: isDown = flags.contains(.maskShift)
            case 58, 61: isDown = flags.contains(.maskAlternate)
            case 59, 62: isDown = flags.contains(.maskControl)
            case 57: isDown = flags.contains(.maskAlphaShift)
            default: isDown = false
            }
            controller?.sendKey(
                keyCode: UInt16(clamping: keyCode),
                down: isDown,
                flags: UInt64(flags.rawValue)
            )
            return nil

        default:
            // Trackpad gestures (Spaces swipes, Mission Control pinches…):
            // never forwarded, and never acted on locally while captured.
            // Switch the remote's desktops with the on-screen buttons in
            // RemoteView or the forwarded Ctrl+arrow keys instead.
            if type == Self.gestureType, isActive {
                return nil
            }
            return Unmanaged.passRetained(event)
        }
    }
}
