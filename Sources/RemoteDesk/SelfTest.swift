import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

enum SelfTest {
    static func run() {
        print("Running RemoteDesk self-tests...")

        do {
            try testProtocolRoundTrips()
            print("✓ Protocol round-trips passed")

            try testFraming()
            print("✓ Framing reassembly passed")

            try testCodecLoop()
            print("✓ Codec loop passed")

            print("SELF-TEST: ALL PASS")
            exit(0)
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }

    // MARK: - 1. Protocol Round-trips

    private static func testProtocolRoundTrips() throws {
        // Hello
        let hello = Messages.Hello(name: "MacBookPro-SelfTest")
        let helloBytes = try Messages.encodeHello(hello)
        let parsedHello = try Messages.parseHello(helloBytes)
        guard parsedHello == hello else { throw TestError("Hello round-trip mismatch") }

        // HelloAck
        let ack = Messages.HelloAck(status: 0, width: 2560, height: 1440, name: "MacMini-Host")
        let ackBytes = try Messages.encodeHelloAck(ack)
        let parsedAck = try Messages.parseHelloAck(ackBytes)
        guard parsedAck == ack else { throw TestError("HelloAck round-trip mismatch") }

        // VideoConfig
        let sps: [UInt8] = [0x67, 0x42, 0xC0, 0x28, 0xD9, 0x01]
        let pps: [UInt8] = [0x68, 0xCE, 0x3C, 0x80]
        let config = Messages.VideoConfig(parameterSets: [sps, pps])
        let configBytes = try Messages.encodeVideoConfig(config)
        let parsedConfig = try Messages.parseVideoConfig(configBytes)
        guard parsedConfig == config else { throw TestError("VideoConfig round-trip mismatch") }

        // VideoFrame
        let frame = Messages.VideoFrame(
            isKeyframe: true,
            timestampMicros: 123456789,
            avccData: [0x00, 0x00, 0x00, 0x04, 0x65, 0x88, 0x84, 0x00]
        )
        let frameBytes = try Messages.encodeVideoFrame(frame)
        let parsedFrame = try Messages.parseVideoFrame(frameBytes)
        guard parsedFrame == frame else { throw TestError("VideoFrame round-trip mismatch") }

        // MouseMove
        let move = Messages.MouseMove(x: 0.35, y: 0.72, flags: 0x1000)
        let moveBytes = try Messages.encodeMouseMove(move)
        let parsedMove = try Messages.parseMouseMove(moveBytes)
        guard abs(parsedMove.x - move.x) < 0.0001,
              abs(parsedMove.y - move.y) < 0.0001,
              parsedMove.flags == move.flags else {
            throw TestError("MouseMove round-trip mismatch")
        }

        // MouseButton
        let btn = Messages.MouseButtonMsg(button: 1, down: true, flags: 0x2000)
        let btnBytes = try Messages.encodeMouseButton(btn)
        let parsedBtn = try Messages.parseMouseButton(btnBytes)
        guard parsedBtn == btn else { throw TestError("MouseButton round-trip mismatch") }

        // Scroll
        let scroll = Messages.ScrollMsg(dx: -12.5, dy: 45.0, flags: 0x4000)
        let scrollBytes = try Messages.encodeScroll(scroll)
        let parsedScroll = try Messages.parseScroll(scrollBytes)
        guard abs(parsedScroll.dx - scroll.dx) < 0.0001,
              abs(parsedScroll.dy - scroll.dy) < 0.0001,
              parsedScroll.flags == scroll.flags else {
            throw TestError("Scroll round-trip mismatch")
        }

        // Key
        let key = Messages.KeyMsg(keyCode: 12, down: true, flags: 0x8000)
        let keyBytes = try Messages.encodeKey(key)
        let parsedKey = try Messages.parseKey(keyBytes)
        guard parsedKey == key else { throw TestError("Key round-trip mismatch") }

        // Ping
        let ping = Messages.PingPong(timestampMicros: 987654321)
        let pingBytes = try Messages.encodePing(ping)
        let parsedPing = try Messages.parsePing(pingBytes)
        guard parsedPing == ping else { throw TestError("Ping round-trip mismatch") }

        // Clipboard
        let clip = Messages.Clipboard(kind: 0, text: "Self-test clipboard test string with symbols: ⌘⌥⇧⌃ and Arabic: مرحباً")
        let clipBytes = try Messages.encodeClipboard(clip)
        let parsedClip = try Messages.parseClipboard(clipBytes)
        guard parsedClip == clip else { throw TestError("Clipboard round-trip mismatch") }
    }

    // MARK: - 2. Framing & Reassembly

    private static func testFraming() throws {
        var framesToSend: [(MessageType, [UInt8])] = []
        framesToSend.append((.hello, try Messages.encodeHello(Messages.Hello(name: "Client1"))))
        framesToSend.append((.ping, try Messages.encodePing(Messages.PingPong(timestampMicros: 1000))))
        framesToSend.append((.scroll, try Messages.encodeScroll(Messages.ScrollMsg(dx: 1, dy: 2, flags: 0))))
        framesToSend.append((.clipboard, try Messages.encodeClipboard(Messages.Clipboard(kind: 0, text: "chunk test"))))

        var streamData: [UInt8] = []
        for (type, payload) in framesToSend {
            streamData.append(contentsOf: encodeFrame(type: type, payload: payload))
        }

        // Feed into FrameDecoder in awkward 3-byte chunks
        var decoder = FrameDecoder()
        var receivedFrames: [RawFrame] = []
        var offset = 0
        let chunkSize = 3

        while offset < streamData.count {
            let end = min(offset + chunkSize, streamData.count)
            let chunk = Array(streamData[offset..<end])
            decoder.append(chunk)
            offset = end

            while let frame = try decoder.next() {
                receivedFrames.append(frame)
            }
        }

        guard receivedFrames.count == framesToSend.count else {
            throw TestError("Framing count mismatch: expected \(framesToSend.count), got \(receivedFrames.count)")
        }

        for (i, received) in receivedFrames.enumerated() {
            let (expectedType, expectedPayload) = framesToSend[i]
            guard received.type == expectedType.rawValue else {
                throw TestError("Frame \(i) type mismatch: expected \(expectedType.rawValue), got \(received.type)")
            }
            guard received.payload == expectedPayload else {
                throw TestError("Frame \(i) payload mismatch")
            }
        }

        // Test invalid length handling
        var badDecoder = FrameDecoder()
        // Length 70MB (exceeds maxFrameLength of 64MB)
        badDecoder.append([0x04, 0x60, 0x00, 0x00, 0x01])
        do {
            _ = try badDecoder.next()
            throw TestError("Expected ProtocolError.invalidLength not thrown")
        } catch ProtocolError.invalidLength {
            // Success
        }
    }

    // MARK: - 3. Codec Loop

    private static func testCodecLoop() throws {
        let width = 640
        let height = 360
        let fps = 30
        let testQueue = DispatchQueue(label: "remotedesk.selftest.codec")

        var decodedBuffers: [CVImageBuffer] = []
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()

        let decoder = VideoDecoder(queue: testQueue) { imageBuffer in
            lock.lock()
            decodedBuffers.append(imageBuffer)
            let count = decodedBuffers.count
            lock.unlock()

            if count >= 2 {
                semaphore.signal()
            }
        }

        let encoder = VideoEncoder(
            width: width,
            height: height,
            fps: fps,
            bitrate: 2_000_000,
            queue: testQueue,
            onFormatChange: { parameterSets in
                do {
                    try decoder.configure(parameterSets: parameterSets)
                } catch {
                    fputs("decoder configure failed: \(error)\n", stderr)
                }
            },
            onFrame: { avcc, timestampMicros, isKeyframe in
                decoder.decode(avcc: avcc, timestampMicros: timestampMicros, isKeyframe: isKeyframe)
            }
        )

        // Create 5 solid-color test pixel buffers
        let colors: [(UInt8, UInt8, UInt8)] = [
            (255, 0, 0),     // Red
            (0, 255, 0),     // Green
            (0, 0, 255),     // Blue
            (255, 255, 0),   // Yellow
            (255, 255, 255), // White
        ]

        var pixelBuffers: [CVPixelBuffer] = []
        for (r, g, b) in colors {
            guard let buffer = makeSolidColorBuffer(width: width, height: height, r: r, g: g, b: b) else {
                throw TestError("Failed to create pixel buffer")
            }
            pixelBuffers.append(buffer)
        }

        // Feed all 5 frames with 33ms interval
        for (index, buffer) in pixelBuffers.enumerated() {
            let pts = CMTime(value: Int64(index * 33333), timescale: 1_000_000)
            encoder.encode(pixelBuffer: buffer, presentationTime: pts)
            Thread.sleep(forTimeInterval: 0.035)
        }

        // Wait up to 5 seconds for at least 2 frames to be decoded
        let waitResult = semaphore.wait(timeout: .now() + 5.0)
        encoder.invalidate()
        decoder.invalidate()

        guard waitResult == .success else {
            throw TestError("Codec loop timed out waiting for decoded frames (received \(decodedBuffers.count))")
        }

        lock.lock()
        let count = decodedBuffers.count
        let firstBuffer = decodedBuffers.first
        lock.unlock()

        guard count >= 2 else {
            throw TestError("Expected >= 2 decoded frames, got \(count)")
        }

        if let buf = firstBuffer {
            let outWidth = CVPixelBufferGetWidth(buf)
            let outHeight = CVPixelBufferGetHeight(buf)
            guard outWidth == width, outHeight == height else {
                throw TestError("Decoded dimensions mismatch: expected \(width)x\(height), got \(outWidth)x\(outHeight)")
            }
        }
    }

    private static func makeSolidColorBuffer(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) -> CVPixelBuffer? {
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

        // Fill BGRA
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let px = row.advanced(by: x * 4)
                px[0] = b
                px[1] = g
                px[2] = r
                px[3] = 255
            }
        }
        return buffer
    }

    private struct TestError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
