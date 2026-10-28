import AppKit
import Foundation
import Network

final class ClientController {
    let options: Options

    private let queue = DispatchQueue(label: "remotedesk.client")
    private let decoderQueue = DispatchQueue(label: "remotedesk.client.decoder")

    private var peer: PeerConnection?
    private var browser: NWBrowser?
    private var decoder: VideoDecoder?
    private var clipboard: ClipboardSync?
    private var pingTimer: DispatchSourceTimer?
    private var timeoutTimer: DispatchSourceTimer?

    private var running = false
    private var decodedFrames = 0
    private var connectionEstablished = false
    private var hostWidth: UInt32 = 0
    private var hostHeight: UInt32 = 0
    private var hostName: String = ""
    private var displayInfo: Messages.DisplayInfo?
    private var displayInfoSent = false

    // UI Callbacks
    var onConnected: ((_ width: UInt32, _ height: UInt32, _ hostName: String) -> Void)?
    var onDisconnected: ((_ reason: String) -> Void)?
    var onFrame: ((_ imageBuffer: CVImageBuffer) -> Void)?
    var onDiscoveredHosts: (([NWBrowser.Result]) -> Void)?

    var targetEndpoint: NWEndpoint?

    init(options: Options) {
        self.options = options
    }

    func start() {
        guard !running else { return }
        running = true

        decoder = VideoDecoder(queue: decoderQueue) { [weak self] imageBuffer in
            self?.handleDecodedFrame(imageBuffer)
        }

        if !options.noUI {
            let clipboard = ClipboardSync()
            clipboard.onLocalChange = { [weak self] text in
                guard let self else { return }
                self.queue.async {
                    self.sendClipboard(text)
                }
            }
            self.clipboard = clipboard
            clipboard.start()
        }

        if options.timeoutSeconds > 0 && options.noUI {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + options.timeoutSeconds)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                Log.error("client timed out after \(self.options.timeoutSeconds)s")
                exit(2)
            }
            timeoutTimer = timer
            timer.resume()
        }

        if let endpoint = targetEndpoint {
            connect(toEndpoint: endpoint)
        } else if let host = options.connectHost {
            connect(toHost: host, port: options.connectPort)
        } else if options.browse || options.noUI {
            startBrowsing(autoConnectFirst: true)
        } else {
            startBrowsing(autoConnectFirst: false)
        }
    }

    func stop() {
        queue.sync {
            guard running else { return }
            running = false
            timeoutTimer?.cancel()
            timeoutTimer = nil
            pingTimer?.cancel()
            pingTimer = nil
            browser?.cancel()
            browser = nil
            peer?.close()
            peer = nil
            decoder?.invalidate()
            decoder = nil
            clipboard?.stop()
            clipboard = nil
        }
    }

    func connect(toHost host: String, port: UInt16) {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            Log.info("connecting to \(host):\(port)...")
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                Log.error("invalid port: \(port)")
                if self.options.noUI { exit(2) }
                return
            }
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
            self.connect(toEndpoint: endpoint)
        }
    }

    func connect(toEndpoint endpoint: NWEndpoint) {
        self.targetEndpoint = endpoint
        if !running {
            start()
            return
        }
        queue.async { [weak self] in
            guard let self, self.running else { return }
            self.browser?.cancel()
            self.browser = nil
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let connection = NWConnection(to: endpoint, using: parameters)
            self.setupPeer(connection: connection)
        }
    }

    func startBrowsing(autoConnectFirst: Bool) {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            let descriptor = NWBrowser.Descriptor.bonjour(type: "_remotedesk._tcp", domain: nil)
            let parameters = NWParameters()
            let browser = NWBrowser(for: descriptor, using: parameters)
            self.browser = browser

            browser.browseResultsChangedHandler = { [weak self] results, _ in
                guard let self else { return }
                DispatchQueue.main.async {
                    self.onDiscoveredHosts?(Array(results))
                }
                if autoConnectFirst, let first = results.first {
                    self.browser?.cancel()
                    self.browser = nil
                    Log.info("discovered Bonjour host: \(first.endpoint), connecting...")
                    self.connect(toEndpoint: first.endpoint)
                }
            }

            browser.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    Log.info("browsing for _remotedesk._tcp hosts...")
                case .failed(let error):
                    Log.warn("bonjour browser failed: \(error)")
                default:
                    break
                }
            }

            browser.start(queue: self.queue)
        }
    }

    private func setupPeer(connection: NWConnection) {
        peer?.close()
        let peer = PeerConnection(connection: connection, queue: queue)
        self.peer = peer

        peer.onReady = { [weak self] in
            self?.peerReady()
        }
        peer.onFrame = { [weak self] frame in
            self?.handleFrame(frame)
        }
        peer.onClose = { [weak self] in
            self?.handlePeerClose()
        }
        peer.start()
    }

    private func peerReady() {
        connectionEstablished = true
        Log.info("connection established, sending hello...")
        do {
            let hello = Messages.Hello(name: options.name)
            let payload = try Messages.encodeHello(hello)
            _ = peer?.send(type: .hello, payload: payload)
        } catch {
            Log.error("failed to encode hello: \(error)")
            peer?.close()
        }
    }

    private func handlePeerClose() {
        Log.info("connection closed")
        pingTimer?.cancel()
        pingTimer = nil
        if options.noUI {
            if options.expectFrames > 0 && decodedFrames < options.expectFrames {
                Log.error("disconnected before reaching \(options.expectFrames) frames (got \(decodedFrames))")
                exit(3)
            }
        } else {
            let wasEstablished = connectionEstablished
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if wasEstablished {
                    self.onDisconnected?("Connection closed by host")
                } else {
                    let target = self.options.connectHost ?? "the selected host"
                    self.onDisconnected?("Could not connect to \(target) — no RemoteDesk host is listening. Make sure the other Mac is running RemoteDesk and has clicked “Share This Mac”.")
                }
            }
        }
    }

    private func handleFrame(_ frame: RawFrame) {
        guard let type = MessageType(rawValue: frame.type) else {
            Log.warn("unknown frame type: \(frame.type)")
            return
        }

        switch type {
        case .helloAck:
            do {
                let ack = try Messages.parseHelloAck(frame.payload)
                guard ack.status == 0 else {
                    Log.error("host rejected hello with status \(ack.status)")
                    peer?.close()
                    return
                }
                hostWidth = ack.width
                hostHeight = ack.height
                hostName = ack.name
                Log.info("connected to '\(ack.name)' (\(ack.width)x\(ack.height))")
                startPingTimer()
                // The host re-sends helloAck after every resolution change;
                // only the first one needs the display info.
                if !displayInfoSent {
                    sendDisplayInfoIfReady()
                }
                DispatchQueue.main.async { [weak self] in
                    self?.onConnected?(ack.width, ack.height, ack.name)
                }
            } catch {
                Log.error("malformed helloAck: \(error)")
                peer?.close()
            }

        case .videoConfig:
            do {
                let config = try Messages.parseVideoConfig(frame.payload)
                Log.debug("received videoConfig with \(config.parameterSets.count) parameter sets")
                try decoder?.configure(parameterSets: config.parameterSets)
            } catch {
                Log.warn("failed to apply videoConfig: \(error)")
            }

        case .videoFrame:
            do {
                let videoFrame = try Messages.parseVideoFrame(frame.payload)
                decoder?.decode(
                    avcc: videoFrame.avccData,
                    timestampMicros: videoFrame.timestampMicros,
                    isKeyframe: videoFrame.isKeyframe
                )
            } catch {
                Log.warn("failed to parse video frame: \(error)")
            }

        case .clipboard:
            do {
                let msg = try Messages.parseClipboard(frame.payload)
                if msg.kind == 0 {
                    DispatchQueue.main.async { [weak self] in
                        self?.clipboard?.applyRemote(msg.text)
                    }
                }
            } catch {
                Log.warn("failed to parse clipboard message: \(error)")
            }

        case .pong:
            Log.debug("received pong")

        case .ping:
            do {
                let ping = try Messages.parsePing(frame.payload)
                if let pongPayload = try? Messages.encodePing(ping) {
                    _ = peer?.send(type: .pong, payload: pongPayload)
                }
            } catch {
                Log.warn("failed to parse ping: \(error)")
            }

        case .bye:
            Log.info("received bye from host")
            peer?.close()

        default:
            Log.debug("unexpected message type on client: \(type)")
        }
    }

    private func handleDecodedFrame(_ imageBuffer: CVImageBuffer) {
        decodedFrames += 1
        let count = decodedFrames

        if options.noUI {
            if options.expectFrames > 0 && count >= options.expectFrames {
                print("RESULT: OK frames=\(count)")
                fflush(stdout)
                exit(0)
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.onFrame?(imageBuffer)
            }
        }
    }

    private func startPingTimer() {
        pingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let micros = UInt64(Date().timeIntervalSince1970 * 1_000_000)
            if let payload = try? Messages.encodePing(Messages.PingPong(timestampMicros: micros)) {
                _ = self.peer?.send(type: .ping, payload: payload)
            }
        }
        pingTimer = timer
        timer.resume()
    }

    // Input sending methods called from RemoteView or main queue
    func sendMouseMove(x: Float, y: Float, flags: UInt64) {
        queue.async { [weak self] in
            guard let self, let peer = self.peer else { return }
            let msg = Messages.MouseMove(x: x, y: y, flags: flags)
            if let payload = try? Messages.encodeMouseMove(msg) {
                _ = peer.send(type: .mouseMove, payload: payload)
            }
        }
    }

    func sendMouseButton(button: UInt8, down: Bool, flags: UInt64) {
        queue.async { [weak self] in
            guard let self, let peer = self.peer else { return }
            let msg = Messages.MouseButtonMsg(button: button, down: down, flags: flags)
            if let payload = try? Messages.encodeMouseButton(msg) {
                _ = peer.send(type: .mouseButton, payload: payload)
            }
        }
    }

    func sendScroll(dx: Float, dy: Float, flags: UInt64) {
        queue.async { [weak self] in
            guard let self, let peer = self.peer else { return }
            let msg = Messages.ScrollMsg(dx: dx, dy: dy, flags: flags)
            if let payload = try? Messages.encodeScroll(msg) {
                _ = peer.send(type: .scroll, payload: payload)
            }
        }
    }

    func sendKey(keyCode: UInt16, down: Bool, flags: UInt64) {
        queue.async { [weak self] in
            guard let self, let peer = self.peer else { return }
            let msg = Messages.KeyMsg(keyCode: keyCode, down: down, flags: flags)
            if let payload = try? Messages.encodeKey(msg) {
                _ = peer.send(type: .key, payload: payload)
            }
        }
    }

    /// Forwards a raw trackpad gesture event (see InputGrabber).
    func sendGesture(eventData: [UInt8]) {
        queue.async { [weak self] in
            guard let self, let peer = self.peer else { return }
            if let payload = try? Messages.encodeGesture(Messages.Gesture(eventData: eventData)) {
                _ = peer.send(type: .gesture, payload: payload)
            }
        }
    }

    /// Tells the host which display the remote view is shown on, so it can
    /// match its resolution and size the stream to it.
    func sendDisplayInfo(_ info: Messages.DisplayInfo) {
        queue.async { [weak self] in
            guard let self else { return }
            self.displayInfo = info
            self.sendDisplayInfoIfReady()
        }
    }

    private func sendDisplayInfoIfReady() {
        guard let peer, let info = displayInfo, hostWidth > 0 else { return }
        if let payload = try? Messages.encodeDisplayInfo(info) {
            displayInfoSent = true
            _ = peer.send(type: .displayInfo, payload: payload)
        }
    }

    func requestKeyframe() {
        queue.async { [weak self] in
            _ = self?.peer?.send(type: .requestKeyframe, payload: [])
        }
    }

    private func sendClipboard(_ text: String) {
        guard let peer else { return }
        let msg = Messages.Clipboard(kind: 0, text: text)
        if let payload = try? Messages.encodeClipboard(msg) {
            _ = peer.send(type: .clipboard, payload: payload)
        }
    }
}
