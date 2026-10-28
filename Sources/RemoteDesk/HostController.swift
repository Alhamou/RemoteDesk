import AppKit
import CoreGraphics
import Foundation
import Network

final class HostController {
    let options: Options

    private let queue = DispatchQueue(label: "remotedesk.host")
    private let encoderQueue = DispatchQueue(label: "remotedesk.host.encoder")
    private let captureQueue = DispatchQueue(label: "remotedesk.host.capture")

    private var listener: NWListener!
    private var encoder: VideoEncoder?
    private var capturer: ScreenCapturer?
    private var testPattern: TestPattern?
    private var input: InputInjector?
    private var clipboard: ClipboardSync?
    private var videoConfigPayload: [UInt8]?
    private var peers: [UUID: PeerState] = [:]
    private var running = false
    private var width: Int
    private var height: Int
    /// The connected client's screen in pixels; the stream never exceeds it.
    private var fitWithin: (width: Int, height: Int)?
    /// Main-thread only.
    private let displayMatcher = DisplayModeMatcher()
    /// Lets the display settle after a mode switch before capture restarts.
    private static let modeSwitchSettleDelay = 0.6

    var onCaptureError: ((Error) -> Void)?
    /// Fired on the main thread when the first client says hello.
    var onClientConnected: ((_ name: String) -> Void)?
    /// Fired on the main thread when the last helloed client disconnects.
    var onClientDisconnected: (() -> Void)?

    private final class PeerState {
        let peer: PeerConnection
        var name: String?
        var helloed = false
        var congested = false
        var helloTimeout: DispatchWorkItem?

        init(peer: PeerConnection) {
            self.peer = peer
        }
    }

    init(options: Options) {
        self.options = options
        if options.useTestPattern {
            let size = options.testPatternSize ?? (width: 1280, height: 720)
            width = max(2, size.width & ~1)
            height = max(2, size.height & ~1)
        } else {
            let screen = NSScreen.main
            let scale = screen?.backingScaleFactor ?? 2
            var w = Int((screen?.frame.width ?? CGFloat(CGDisplayPixelsWide(CGMainDisplayID()))) * scale)
            var h = Int((screen?.frame.height ?? CGFloat(CGDisplayPixelsHigh(CGMainDisplayID()))) * scale)
            let maxDim = options.maxDimension
            if w > maxDim || h > maxDim {
                let ratio = Double(maxDim) / Double(max(w, h))
                w = Int(Double(w) * ratio)
                h = Int(Double(h) * ratio)
            }
            width = max(2, w & ~1)
            height = max(2, h & ~1)
        }
    }

    func start() {
        guard !running else { return }
        running = true

        encoder = makeEncoder()

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = true
        guard let port = NWEndpoint.Port(rawValue: options.port) else {
            Log.error("invalid port \(options.port)")
            exit(2)
        }
        do {
            listener = try NWListener(using: parameters, on: port)
        } catch {
            Log.error("failed to create listener: \(error)")
            exit(1)
        }
        listener.service = NWListener.Service(name: options.name, type: "_remotedesk._tcp")
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Log.info("listening on port \(self.options.port)")
                print("HOST READY")
                fflush(stdout)
            case .failed(let error):
                Log.error("listener failed: \(error)")
                if self.options.noUI {
                    exit(1)
                }
            case .cancelled:
                Log.info("listener cancelled")
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        if !options.noUI {
            let clipboard = ClipboardSync()
            clipboard.onLocalChange = { [weak self] text in
                guard let self else { return }
                self.queue.async {
                    self.broadcastClipboard(text)
                }
            }
            self.clipboard = clipboard
            clipboard.start()
        }

        if options.useTestPattern {
            startTestPattern()
        } else {
            if !options.noUI {
                input = InputInjector()
            }
            startCapture()
        }

        listener.start(queue: queue)
    }

    func stop() {
        queue.sync {
            guard running else { return }
            running = false
            listener.stateUpdateHandler = nil
            listener.newConnectionHandler = nil
            listener.cancel()
            for state in Array(peers.values) {
                state.helloTimeout?.cancel()
                state.helloTimeout = nil
                state.peer.close()
            }
            peers.removeAll()
            capturer?.stop()
            capturer = nil
            testPattern?.stop()
            testPattern = nil
            encoder?.invalidate()
            encoder = nil
            clipboard?.stop()
            clipboard = nil
            input = nil
            videoConfigPayload = nil
            fitWithin = nil
        }
        let matcher = displayMatcher
        if Thread.isMainThread {
            matcher.restore()
        } else {
            DispatchQueue.main.async { matcher.restore() }
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        guard running else {
            connection.cancel()
            return
        }
        let peer = PeerConnection(connection: connection, queue: queue)
        let state = PeerState(peer: peer)
        let id = peer.id
        peers[id] = state
        peer.onReady = { [weak self] in
            self?.peerReady(id)
        }
        peer.onFrame = { [weak self] frame in
            self?.handleFrame(frame, from: id)
        }
        peer.onClose = { [weak self] in
            self?.handlePeerClose(id)
        }
        peer.start()
    }

    private func peerReady(_ id: UUID) {
        sendHelloAck(to: id)
        let item = DispatchWorkItem { [weak self] in
            guard let self, let state = self.peers[id], !state.helloed else { return }
            Log.warn("client did not send hello in time")
            state.peer.close()
        }
        peers[id]?.helloTimeout = item
        queue.asyncAfter(deadline: .now() + 10, execute: item)
    }

    private func handlePeerClose(_ id: UUID) {
        guard let state = peers.removeValue(forKey: id) else { return }
        state.helloTimeout?.cancel()
        state.helloTimeout = nil
        Log.info("client \(state.name ?? id.uuidString) disconnected")
        if state.helloed, !peers.values.contains(where: { $0.helloed }) {
            applyClientDisplay(nil)
            DispatchQueue.main.async {
                self.onClientDisconnected?()
            }
        }
    }

    private func handleFrame(_ frame: RawFrame, from id: UUID) {
        guard let state = peers[id] else { return }
        if frame.type == MessageType.hello.rawValue {
            handleHello(frame, id: id)
            return
        }
        guard state.helloed, let type = MessageType(rawValue: frame.type) else { return }
        switch type {
        case .ping:
            do {
                let message = try Messages.parsePing(frame.payload)
                sendPong(to: id, timestampMicros: message.timestampMicros)
            } catch {
                Log.warn("bad ping from \(id.uuidString)")
            }
        case .requestKeyframe:
            encoder?.forceKeyframe()
        case .bye:
            state.peer.close()
        case .clipboard:
            do {
                let message = try Messages.parseClipboard(frame.payload)
                if message.kind == 0 {
                    clipboard?.applyRemote(message.text)
                }
            } catch {
                Log.warn("bad clipboard from \(id.uuidString)")
            }
        case .mouseMove:
            do {
                let message = try Messages.parseMouseMove(frame.payload)
                input?.mouseMoved(x: message.x, y: message.y, flags: message.flags)
            } catch {
                Log.warn("bad mouse move from \(id.uuidString)")
            }
        case .mouseButton:
            do {
                let message = try Messages.parseMouseButton(frame.payload)
                input?.mouseButton(button: message.button, down: message.down, flags: message.flags)
            } catch {
                Log.warn("bad mouse button from \(id.uuidString)")
            }
        case .scroll:
            do {
                let message = try Messages.parseScroll(frame.payload)
                input?.scroll(dx: message.dx, dy: message.dy, flags: message.flags)
            } catch {
                Log.warn("bad scroll from \(id.uuidString)")
            }
        case .key:
            do {
                let message = try Messages.parseKey(frame.payload)
                input?.key(keyCode: message.keyCode, down: message.down, flags: message.flags)
            } catch {
                Log.warn("bad key from \(id.uuidString)")
            }
        case .displayInfo:
            do {
                applyClientDisplay(try Messages.parseDisplayInfo(frame.payload))
            } catch {
                Log.warn("bad display info from \(id.uuidString)")
            }
        case .gesture:
            do {
                let message = try Messages.parseGesture(frame.payload)
                input?.gesture(eventData: message.eventData)
            } catch {
                Log.warn("bad gesture from \(id.uuidString)")
            }
        case .hello, .helloAck, .videoConfig, .videoFrame, .pong:
            Log.debug("unexpected \(type) message from client")
        }
    }

    private func handleHello(_ frame: RawFrame, id: UUID) {
        guard let state = peers[id] else { return }
        do {
            let hello = try Messages.parseHello(frame.payload)
            state.helloTimeout?.cancel()
            state.helloTimeout = nil
            state.name = hello.name
            let hadClients = peers.values.contains { $0.helloed }
            state.helloed = true
            Log.info("client '\(hello.name)' connected")
            if !hadClients {
                DispatchQueue.main.async {
                    self.onClientConnected?(hello.name)
                }
            }
            if let payload = videoConfigPayload {
                _ = state.peer.send(type: .videoConfig, payload: payload)
            }
            encoder?.forceKeyframe()
        } catch {
            Log.warn("invalid hello from \(id.uuidString)")
        }
    }

    private func sendHelloAck(to id: UUID) {
        guard let state = peers[id] else { return }
        guard let payload = try? Messages.encodeHelloAck(Messages.HelloAck(status: 0, width: UInt32(width), height: UInt32(height), name: options.name)) else { return }
        _ = state.peer.send(type: .helloAck, payload: payload)
    }

    private func sendPong(to id: UUID, timestampMicros: UInt64) {
        guard let state = peers[id] else { return }
        guard let payload = try? Messages.encodePing(Messages.PingPong(timestampMicros: timestampMicros)) else { return }
        _ = state.peer.send(type: .pong, payload: payload)
    }

    private func makeEncoder() -> VideoEncoder {
        VideoEncoder(
            width: width,
            height: height,
            fps: options.fps,
            bitrate: options.bitrate,
            queue: encoderQueue,
            onFormatChange: { [weak self] parameterSets in
                guard let self else { return }
                self.queue.async {
                    self.handleFormatChange(parameterSets)
                }
            },
            onFrame: { [weak self] data, timestampMicros, isKeyframe in
                guard let self else { return }
                self.queue.async {
                    self.broadcastFrame(data: data, timestampMicros: timestampMicros, isKeyframe: isKeyframe)
                }
            }
        )
    }

    private func handleFormatChange(_ parameterSets: [[UInt8]]) {
        guard let payload = try? Messages.encodeVideoConfig(Messages.VideoConfig(parameterSets: parameterSets)) else {
            Log.warn("failed to encode video config")
            return
        }
        videoConfigPayload = payload
        for state in peers.values where state.helloed {
            _ = state.peer.send(type: .videoConfig, payload: payload)
        }
    }

    private func broadcastFrame(data: [UInt8], timestampMicros: UInt64, isKeyframe: Bool) {
        guard !peers.isEmpty else { return }
        guard let payload = try? Messages.encodeVideoFrame(Messages.VideoFrame(isKeyframe: isKeyframe, timestampMicros: timestampMicros, avccData: data)) else {
            Log.warn("failed to encode video frame")
            return
        }
        for state in peers.values where state.helloed {
            if state.congested {
                if state.peer.pendingBytes < 1_048_576 {
                    state.congested = false
                    encoder?.forceKeyframe()
                } else {
                    continue
                }
            } else if state.peer.pendingBytes > 4_194_304 {
                state.congested = true
                continue
            }
            _ = state.peer.send(type: .videoFrame, payload: payload)
        }
    }

    private func broadcastClipboard(_ text: String) {
        guard !peers.isEmpty else { return }
        guard let payload = try? Messages.encodeClipboard(Messages.Clipboard(kind: 0, text: text)) else { return }
        for state in peers.values where state.helloed {
            _ = state.peer.send(type: .clipboard, payload: payload)
        }
    }

    private func startTestPattern() {
        let pattern = TestPattern(width: width, height: height, fps: options.fps, queue: captureQueue) { [weak self] pixelBuffer, presentationTime in
            guard let self else { return }
            self.queue.async {
                self.encoder?.encode(pixelBuffer: pixelBuffer, presentationTime: presentationTime)
            }
        }
        testPattern = pattern
        pattern.start()
    }

    private func startCapture() {
        let capturer = ScreenCapturer(queue: captureQueue)
        capturer.onFrame = { [weak self, weak capturer] pixelBuffer, presentationTime in
            guard let self else { return }
            self.queue.async {
                // Drop late frames from a capture replaced by refreshCapture.
                guard self.capturer === capturer else { return }
                self.encoder?.encode(pixelBuffer: pixelBuffer, presentationTime: presentationTime)
            }
        }
        capturer.onError = { [weak self] error in
            guard let self else { return }
            Log.error("capture failed: \(error)")
            DispatchQueue.main.async {
                self.onCaptureError?(error)
            }
            if self.options.noUI {
                exit(4)
            }
        }
        self.capturer = capturer
        capturer.start(fps: options.fps, maxDimension: options.maxDimension, fitWithin: fitWithin) { [weak self] result in
            guard let self else { return }
            self.queue.async {
                switch result {
                case .success(let size):
                    Log.info("capture started at \(size.0)x\(size.1)")
                    self.updateDimensions(width: size.0, height: size.1)
                case .failure(let error):
                    Log.error("capture start failed: \(error)")
                    DispatchQueue.main.async {
                        self.onCaptureError?(error)
                    }
                    if self.options.noUI {
                        exit(4)
                    }
                }
            }
        }
    }

    // MARK: - Fitting the shared screen to the client's display

    /// Called on `queue` with the client's display (nil once the last client
    /// left): matches the host's display mode to it when asked, sizes the
    /// stream to the client's screen, and restarts capture if either
    /// changed. The client learns the new size through a fresh helloAck.
    private func applyClientDisplay(_ info: Messages.DisplayInfo?) {
        guard capturer != nil else { return } // test pattern: fixed size
        if let info, info.pixelWidth > 0, info.pixelHeight > 0 {
            fitWithin = (Int(info.pixelWidth), Int(info.pixelHeight))
        } else {
            fitWithin = nil
        }
        let matcher = displayMatcher
        DispatchQueue.main.async { [weak self] in
            let modeChanged: Bool
            if let info, info.matchResolution, info.pointWidth > 0, info.pointHeight > 0 {
                modeChanged = matcher.match(
                    pointWidth: Int(info.pointWidth),
                    pointHeight: Int(info.pointHeight),
                    preferHiDPI: info.pixelWidth > info.pointWidth
                )
            } else {
                modeChanged = matcher.restore()
            }
            let delay = modeChanged ? Self.modeSwitchSettleDelay : 0
            self?.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refreshCapture(force: modeChanged)
            }
        }
    }

    /// Restarts screen capture when the stream size would change (or
    /// `force`, after a display mode switch). Runs on `queue`.
    private func refreshCapture(force: Bool) {
        guard running, let current = capturer else { return }
        if !force {
            guard let expected = ScreenCapturer.expectedSize(
                displayID: CGMainDisplayID(),
                maxDimension: options.maxDimension,
                fitWithin: fitWithin
            ), expected.width != width || expected.height != height else { return }
        }
        Log.info("restarting capture for the client's display")
        current.stop()
        capturer = nil
        startCapture()
    }

    private func updateDimensions(width newWidth: Int, height newHeight: Int) {
        let w = max(2, newWidth & ~1)
        let h = max(2, newHeight & ~1)
        guard w != width || h != height else { return }
        width = w
        height = h
        videoConfigPayload = nil
        encoder?.invalidate()
        encoder = makeEncoder()
        Log.info("resolution changed to \(w)x\(h)")
        for state in peers.values where state.helloed {
            sendHelloAck(to: state.peer.id)
        }
        encoder?.forceKeyframe()
    }
}
