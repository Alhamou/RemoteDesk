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
        event.flags = CGEventFlags(rawValue: flags)
        event.post(tap: .cghidEventTap)
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
        return CGPoint(x: bounds.origin.x + nx * bounds.width, y: bounds.origin.y + ny * bounds.height)
    }

    private static func clampWheel(_ value: Float) -> Int {
        guard value.isFinite else { return 0 }
        return Int(min(max(value, -100000), 100000).rounded())
    }
}
