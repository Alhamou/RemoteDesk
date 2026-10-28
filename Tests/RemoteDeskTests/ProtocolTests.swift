import XCTest
@testable import RemoteDesk

final class ProtocolTests: XCTestCase {

    // MARK: - Handshake Messages

    func testHelloEncodingAndDecoding() throws {
        let original = Messages.Hello(name: "MacBookPro-Client")
        let bytes = try Messages.encodeHello(original)
        let decoded = try Messages.parseHello(bytes)
        XCTAssertEqual(decoded, original)
    }

    func testHelloAckEncodingAndDecoding() throws {
        let original = Messages.HelloAck(status: 0, width: 2560, height: 1440, name: "MacMini-Host")
        let bytes = try Messages.encodeHelloAck(original)
        let decoded = try Messages.parseHelloAck(bytes)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Video Stream Messages

    func testVideoConfigEncodingAndDecoding() throws {
        let sps: [UInt8] = [0x67, 0x42, 0xC0, 0x28, 0xD9, 0x01]
        let pps: [UInt8] = [0x68, 0xCE, 0x3C, 0x80]
        let original = Messages.VideoConfig(parameterSets: [sps, pps])
        let bytes = try Messages.encodeVideoConfig(original)
        let decoded = try Messages.parseVideoConfig(bytes)
        XCTAssertEqual(decoded, original)
    }

    func testVideoFrameEncodingAndDecoding() throws {
        let original = Messages.VideoFrame(
            isKeyframe: true,
            timestampMicros: 987654321,
            avccData: [0x00, 0x00, 0x00, 0x04, 0x65, 0x88, 0x84, 0x00]
        )
        let bytes = try Messages.encodeVideoFrame(original)
        let decoded = try Messages.parseVideoFrame(bytes)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Input Messages

    func testMouseMoveEncodingAndDecoding() throws {
        let original = Messages.MouseMove(x: 0.425, y: 0.812, flags: 0x1000)
        let bytes = try Messages.encodeMouseMove(original)
        let decoded = try Messages.parseMouseMove(bytes)
        XCTAssertEqual(decoded.flags, original.flags)
        XCTAssertEqual(decoded.x, original.x, accuracy: 0.0001)
        XCTAssertEqual(decoded.y, original.y, accuracy: 0.0001)
    }

    func testMouseButtonEncodingAndDecoding() throws {
        let original = Messages.MouseButtonMsg(button: 1, down: true, flags: 0x2000)
        let bytes = try Messages.encodeMouseButton(original)
        let decoded = try Messages.parseMouseButton(bytes)
        XCTAssertEqual(decoded, original)
    }

    func testScrollEncodingAndDecoding() throws {
        let original = Messages.ScrollMsg(dx: -15.5, dy: 30.0, flags: 0x4000)
        let bytes = try Messages.encodeScroll(original)
        let decoded = try Messages.parseScroll(bytes)
        XCTAssertEqual(decoded.flags, original.flags)
        XCTAssertEqual(decoded.dx, original.dx, accuracy: 0.0001)
        XCTAssertEqual(decoded.dy, original.dy, accuracy: 0.0001)
    }

    func testKeyEncodingAndDecoding() throws {
        let original = Messages.KeyMsg(keyCode: 53, down: true, flags: 0x8000)
        let bytes = try Messages.encodeKey(original)
        let decoded = try Messages.parseKey(bytes)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Utilities & Clipboard

    func testPingPongEncodingAndDecoding() throws {
        let original = Messages.PingPong(timestampMicros: 123456789)
        let bytes = try Messages.encodePing(original)
        let decoded = try Messages.parsePing(bytes)
        XCTAssertEqual(decoded, original)
    }

    func testClipboardEncodingAndDecoding() throws {
        let original = Messages.Clipboard(kind: 0, text: "RemoteDesk clipboard test with symbols: ⌘⌥⇧⌃ and unicode: 🚀")
        let bytes = try Messages.encodeClipboard(original)
        let decoded = try Messages.parseClipboard(bytes)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Framing & Chunk Reassembly

    func testFramingReassemblyOverArbitraryChunks() throws {
        let hello = Messages.Hello(name: "Client")
        let ping = Messages.PingPong(timestampMicros: 500)
        let scroll = Messages.ScrollMsg(dx: 1, dy: 2, flags: 0)

        var streamData: [UInt8] = []
        streamData.append(contentsOf: encodeFrame(type: .hello, payload: try Messages.encodeHello(hello)))
        streamData.append(contentsOf: encodeFrame(type: .ping, payload: try Messages.encodePing(ping)))
        streamData.append(contentsOf: encodeFrame(type: .scroll, payload: try Messages.encodeScroll(scroll)))

        var decoder = FrameDecoder()
        var receivedFrames: [RawFrame] = []

        // Split into awkward 3-byte chunks
        let chunkSize = 3
        var offset = 0
        while offset < streamData.count {
            let end = min(offset + chunkSize, streamData.count)
            decoder.append(Array(streamData[offset..<end]))
            offset = end

            while let frame = try decoder.next() {
                receivedFrames.append(frame)
            }
        }

        XCTAssertEqual(receivedFrames.count, 3)
        XCTAssertEqual(receivedFrames[0].type, MessageType.hello.rawValue)
        XCTAssertEqual(receivedFrames[1].type, MessageType.ping.rawValue)
        XCTAssertEqual(receivedFrames[2].type, MessageType.scroll.rawValue)
    }

    func testFrameDecoderRejectsOversizedLengths() {
        var decoder = FrameDecoder()
        // 70MB frame (exceeds 64MB limit)
        decoder.append([0x04, 0x60, 0x00, 0x00, 0x01])
        XCTAssertThrowsError(try decoder.next()) { error in
            guard case ProtocolError.invalidLength = error else {
                XCTFail("Expected ProtocolError.invalidLength, got \(error)")
                return
            }
        }
    }

    // MARK: - Display matching & gestures

    func testDisplayInfoEncodingAndDecoding() throws {
        let original = Messages.DisplayInfo(
            pointWidth: 1470, pointHeight: 924,
            pixelWidth: 2940, pixelHeight: 1848,
            matchResolution: true
        )
        let bytes = try Messages.encodeDisplayInfo(original)
        XCTAssertEqual(try Messages.parseDisplayInfo(bytes), original)

        var off = original
        off.matchResolution = false
        XCTAssertEqual(try Messages.parseDisplayInfo(try Messages.encodeDisplayInfo(off)), off)
    }

    func testDisplayInfoRejectsAbsurdSizes() throws {
        let bogus = Messages.DisplayInfo(pointWidth: 100_000, pointHeight: 10, pixelWidth: 10, pixelHeight: 10, matchResolution: true)
        XCTAssertThrowsError(try Messages.parseDisplayInfo(try Messages.encodeDisplayInfo(bogus)))
        XCTAssertThrowsError(try Messages.parseDisplayInfo([1, 0, 0]))
    }

    func testGestureEncodingAndDecoding() throws {
        let original = Messages.Gesture(eventData: Array(0..<200).map { UInt8($0) })
        let bytes = try Messages.encodeGesture(original)
        XCTAssertEqual(try Messages.parseGesture(bytes), original)
        XCTAssertThrowsError(try Messages.parseGesture([]))
        XCTAssertThrowsError(try Messages.parseGesture([UInt8](repeating: 0, count: Messages.maxGestureEventBytes + 1)))
    }

    func testUnknownMessageTypesStillFrame() throws {
        // Older peers must be able to skip message types they don't know.
        var decoder = FrameDecoder()
        decoder.append(encodeFrame(type: .gesture, payload: [1, 2, 3]))
        let frame = try decoder.next()
        XCTAssertEqual(frame?.type, 15)
        XCTAssertEqual(frame?.payload, [1, 2, 3])
    }
}
