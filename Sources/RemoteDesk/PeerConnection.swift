import Foundation
import Network

final class PeerConnection {
    let id = UUID()
    private let connection: NWConnection
    private let queue: DispatchQueue

    var onFrame: ((RawFrame) -> Void)?
    var onClose: (() -> Void)?
    var onReady: (() -> Void)?

    private var decoder = FrameDecoder()
    private var started = false
    private var readyFired = false
    private var closed = false

    private let pendingLock = NSLock()
    private var pendingBytesStorage = 0

    var pendingBytes: Int {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        return pendingBytesStorage
    }

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        guard !started else { return }
        started = true
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if !self.readyFired {
                    self.readyFired = true
                    self.onReady?()
                }
                self.receiveLoop()
            case .failed, .cancelled:
                self.close()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    @discardableResult
    func send(type: MessageType, payload: [UInt8]) -> Bool {
        guard !closed else { return false }
        let bytes = encodeFrame(type: type, payload: payload)
        pendingLock.lock()
        pendingBytesStorage += bytes.count
        pendingLock.unlock()
        connection.send(content: Data(bytes), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.pendingLock.lock()
            self.pendingBytesStorage = max(0, self.pendingBytesStorage - bytes.count)
            self.pendingLock.unlock()
            if error != nil {
                self.close()
            }
        })
        return true
    }

    func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose?()
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.decoder.append(Array(data))
                do {
                    while let frame = try self.decoder.next() {
                        self.onFrame?(frame)
                        if self.closed { return }
                    }
                } catch {
                    Log.info("peer protocol error: \(error)")
                    self.close()
                    return
                }
            }
            if error != nil || isComplete {
                self.close()
                return
            }
            if !self.closed {
                self.receiveLoop()
            }
        }
    }
}
