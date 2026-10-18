import AppKit
import CoreVideo
import QuartzCore
import VideoToolbox

final class RemoteView: NSView {
    weak var controller: ClientController?
    var onDisconnectRequested: (() -> Void)?

    private let videoLayer = CALayer()
    private var trackingArea: NSTrackingArea?
    private var videoWidth: Int = 1280
    private var videoHeight: Int = 720

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        videoLayer.contentsGravity = .resizeAspect
        videoLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        videoLayer.frame = bounds
        layer?.addSublayer(videoLayer)
    }

    func setVideoDimensions(width: Int, height: Int) {
        videoWidth = max(1, width)
        videoHeight = max(1, height)
    }

    func display(imageBuffer: CVImageBuffer) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.videoLayer.contents = imageBuffer
        }
    }

    override func layout() {
        super.layout()
        videoLayer.frame = bounds
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool { true }

    private func flags(from event: NSEvent) -> UInt64 {
        UInt64(event.modifierFlags.rawValue)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let (x, y) = normalizedPoint(from: event.locationInWindow) else { return }
        controller?.sendMouseMove(x: x, y: y, flags: flags(from: event))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let (x, y) = normalizedPoint(from: event.locationInWindow) else { return }
        controller?.sendMouseMove(x: x, y: y, flags: flags(from: event))
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard let (x, y) = normalizedPoint(from: event.locationInWindow) else { return }
        controller?.sendMouseMove(x: x, y: y, flags: flags(from: event))
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard let (x, y) = normalizedPoint(from: event.locationInWindow) else { return }
        controller?.sendMouseMove(x: x, y: y, flags: flags(from: event))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let (x, y) = normalizedPoint(from: event.locationInWindow) else { return }
        let f = flags(from: event)
        controller?.sendMouseMove(x: x, y: y, flags: f)
        controller?.sendMouseButton(button: 0, down: true, flags: f)
    }

    override func mouseUp(with event: NSEvent) {
        guard let (x, y) = normalizedPoint(from: event.locationInWindow) else { return }
        let f = flags(from: event)
        controller?.sendMouseMove(x: x, y: y, flags: f)
        controller?.sendMouseButton(button: 0, down: false, flags: f)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let (x, y) = normalizedPoint(from: event.locationInWindow) else { return }
        let f = flags(from: event)
        controller?.sendMouseMove(x: x, y: y, flags: f)
        controller?.sendMouseButton(button: 1, down: true, flags: f)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let (x, y) = normalizedPoint(from: event.locationInWindow) else { return }
        let f = flags(from: event)
        controller?.sendMouseMove(x: x, y: y, flags: f)
        controller?.sendMouseButton(button: 1, down: false, flags: f)
    }

    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let (x, y) = normalizedPoint(from: event.locationInWindow) else { return }
        let f = flags(from: event)
        controller?.sendMouseMove(x: x, y: y, flags: f)
        let button = UInt8(min(event.buttonNumber, 2))
        controller?.sendMouseButton(button: button, down: true, flags: f)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let (x, y) = normalizedPoint(from: event.locationInWindow) else { return }
        let f = flags(from: event)
        controller?.sendMouseMove(x: x, y: y, flags: f)
        let button = UInt8(min(event.buttonNumber, 2))
        controller?.sendMouseButton(button: button, down: false, flags: f)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let (x, y) = normalizedPoint(from: event.locationInWindow) else { return }
        let f = flags(from: event)
        controller?.sendMouseMove(x: x, y: y, flags: f)
        let dx = Float(event.scrollingDeltaX)
        let dy = Float(event.scrollingDeltaY)
        controller?.sendScroll(dx: dx, dy: dy, flags: f)
    }

    override func keyDown(with event: NSEvent) {
        let fl = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Disconnect shortcut: Ctrl + Opt + Cmd + Q (Q keycode is 12)
        if fl == [.control, .option, .command] && event.keyCode == 12 {
            onDisconnectRequested?()
            return
        }
        controller?.sendKey(keyCode: event.keyCode, down: true, flags: flags(from: event))
    }

    override func keyUp(with event: NSEvent) {
        controller?.sendKey(keyCode: event.keyCode, down: false, flags: flags(from: event))
    }

    override func flagsChanged(with event: NSEvent) {
        let isDown: Bool
        switch event.keyCode {
        case 54, 55: // Command
            isDown = event.modifierFlags.contains(.command)
        case 56, 60: // Shift
            isDown = event.modifierFlags.contains(.shift)
        case 58, 61: // Option
            isDown = event.modifierFlags.contains(.option)
        case 59, 62: // Control
            isDown = event.modifierFlags.contains(.control)
        case 57:     // Caps Lock
            isDown = event.modifierFlags.contains(.capsLock)
        default:
            isDown = false
        }
        controller?.sendKey(keyCode: event.keyCode, down: isDown, flags: flags(from: event))
    }

    private func normalizedPoint(from locationInWindow: NSPoint) -> (Float, Float)? {
        let local = convert(locationInWindow, from: nil)
        guard bounds.width > 0, bounds.height > 0, videoWidth > 0, videoHeight > 0 else {
            return nil
        }
        let scale = min(bounds.width / CGFloat(videoWidth), bounds.height / CGFloat(videoHeight))
        let renderW = CGFloat(videoWidth) * scale
        let renderH = CGFloat(videoHeight) * scale
        let originX = (bounds.width - renderW) / 2.0
        let originY = (bounds.height - renderH) / 2.0

        let normX = (local.x - originX) / renderW
        let normY = (local.y - originY) / renderH
        let clampedX = Float(min(max(normX, 0.0), 1.0))
        let clampedY = Float(min(max(normY, 0.0), 1.0))
        return (clampedX, clampedY)
    }
}
