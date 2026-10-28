import Foundation
import CoreGraphics

final class InputInjector {
    private var lastLocation = CGEvent(source: nil)?.location ?? .zero

    func mouseMoved(x: Float, y: Float, flags: UInt64) {
        guard let point = screenPoint(x: x, y: y) else { return }
        lastLocation = point
        guard let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else { return }
        event.flags = CGEventFlags(rawValue: flags)
        event.post(tap: .cghidEventTap)
    }

    func mouseButton(button: UInt8, down: Bool, flags: UInt64) {
        let type: CGEventType
        let cgButton: CGMouseButton
        switch button {
        case 0:
            type = down ? .leftMouseDown : .leftMouseUp
            cgButton = .left
        case 1:
            type = down ? .rightMouseDown : .rightMouseUp
            cgButton = .right
        default:
            type = down ? .otherMouseDown : .otherMouseUp
            cgButton = .center
        }
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: lastLocation, mouseButton: cgButton) else { return }
        if button > 2 {
            // Side buttons (back / forward, Mission Control mappings…) keep
            // their real number so the host's own button settings apply.
            event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
        }
        event.flags = CGEventFlags(rawValue: flags)
        event.post(tap: .cghidEventTap)
    }

    /// kCGEventGesture / kCGSEventDockControl — private event types that
    /// carry trackpad gestures (Spaces swipes, Mission Control, App Exposé,
    /// pinches). Referenced numerically on purpose.
    static let gestureEventTypes: Set<UInt32> = [29, 30]

    /// Replays a raw gesture event captured on the client, so the host's
    /// Dock and apps react as if its own trackpad had been used. Anything
    /// that does not decode to a gesture event type is dropped.
    func gesture(eventData: [UInt8]) {
        let data = Data(eventData) as CFData
        guard let event = CGEvent(withDataAllocator: kCFAllocatorDefault, data: data),
              Self.gestureEventTypes.contains(event.type.rawValue) else { return }
        // The captured location is in the client's screen space.
        event.location = lastLocation
        event.post(tap: .cgSessionEventTap)
    }

    func scroll(dx: Float, dy: Float, flags: UInt64) {
        let wheel1 = Int32(Self.clampWheel(dy))
        let wheel2 = Int32(Self.clampWheel(dx))
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: wheel1, wheel2: wheel2, wheel3: 0) else { return }
        event.flags = CGEventFlags(rawValue: flags)
        event.post(tap: .cghidEventTap)
    }

    func key(keyCode: UInt16, down: Bool, flags: UInt64) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: down) else { return }
        event.flags = CGEventFlags(rawValue: flags)
        event.post(tap: .cghidEventTap)
    }

    private func screenPoint(x: Float, y: Float) -> CGPoint? {
        guard x.isFinite, y.isFinite else { return nil }
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let nx = CGFloat(min(max(x, 0), 1))
        let ny = CGFloat(min(max(y, 0), 1))
        // 1.0 lands on the last pixel row / column (where the Dock and hot
        // corners trigger), never on a neighbouring display.
        return CGPoint(
            x: min(bounds.origin.x + nx * bounds.width, bounds.maxX - 1),
            y: min(bounds.origin.y + ny * bounds.height, bounds.maxY - 1)
        )
    }

    private static func clampWheel(_ value: Float) -> Int {
        guard value.isFinite else { return 0 }
        return Int(min(max(value, -100000), 100000).rounded())
    }
}
