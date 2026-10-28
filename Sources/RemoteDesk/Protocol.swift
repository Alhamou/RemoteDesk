import Foundation

let protocolVersion: UInt16 = 1
let maxFrameLength: UInt32 = 64 * 1024 * 1024
let maxStringLength: Int = 1024 * 1024

enum ProtocolError: Error, Equatable, CustomStringConvertible {
    case invalidLength(UInt32)
    case unknownType(UInt8)
    case truncated
    case badString
    case tooLarge
    case malformed

    var description: String {
        switch self {
        case .invalidLength(let value): return "invalid frame length \(value)"
        case .unknownType(let value): return "unknown message type \(value)"
        case .truncated: return "truncated payload"
        case .badString: return "invalid UTF-8 string"
        case .tooLarge: return "value exceeds protocol limit"
        case .malformed: return "malformed payload"
        }
    }
}

enum MessageType: UInt8 {
    case hello = 1
    case helloAck = 2
    case videoConfig = 3
    case videoFrame = 4
    case mouseMove = 5
    case mouseButton = 6
    case scroll = 7
    case key = 8
    case ping = 9
    case pong = 10
    case requestKeyframe = 11
    case clipboard = 12
    case bye = 13
    case displayInfo = 14
    case gesture = 15
}

struct ByteWriter {
    private(set) var bytes: [UInt8] = []

    mutating func u8(_ value: UInt8) {
        bytes.append(value)
    }

    mutating func u16(_ value: UInt16) {
        bytes.append(UInt8(value >> 8))
        bytes.append(UInt8(value & 0xFF))
    }

    mutating func u32(_ value: UInt32) {
        bytes.append(UInt8(value >> 24))
        bytes.append(UInt8((value >> 16) & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
        bytes.append(UInt8(value & 0xFF))
    }

    mutating func u64(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8((value >> shift) & 0xFF))
        }
    }

    mutating func f32(_ value: Float) {
        u32(value.bitPattern)
    }

    mutating func raw(_ value: [UInt8]) {
        bytes.append(contentsOf: value)
    }

    mutating func string(_ value: String) throws {
        let utf8 = Array(value.utf8)
        guard utf8.count <= maxStringLength else { throw ProtocolError.tooLarge }
        u32(UInt32(utf8.count))
        raw(utf8)
    }
}

struct ByteReader {
    private let bytes: [UInt8]
    private var index = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var remaining: Int {
        bytes.count - index
    }

    mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw ProtocolError.truncated }
        defer { index += 1 }
        return bytes[index]
    }

    mutating func u16() throws -> UInt16 {
        guard remaining >= 2 else { throw ProtocolError.truncated }
        let value = (UInt16(bytes[index]) << 8) | UInt16(bytes[index + 1])
        index += 2
        return value
    }

    mutating func u32() throws -> UInt32 {
        guard remaining >= 4 else { throw ProtocolError.truncated }
        let value = (UInt32(bytes[index]) << 24) | (UInt32(bytes[index + 1]) << 16) | (UInt32(bytes[index + 2]) << 8) | UInt32(bytes[index + 3])
        index += 4
        return value
    }

    mutating func u64() throws -> UInt64 {
        guard remaining >= 8 else { throw ProtocolError.truncated }
        var value: UInt64 = 0
        for offset in 0..<8 {
            value = (value << 8) | UInt64(bytes[index + offset])
        }
        index += 8
        return value
    }

    mutating func f32() throws -> Float {
        Float(bitPattern: try u32())
    }

    mutating func raw(_ count: Int) throws -> [UInt8] {
        guard count >= 0, remaining >= count else { throw ProtocolError.truncated }
        let value = Array(bytes[index..<(index + count)])
        index += count
        return value
    }

    mutating func string() throws -> String {
        let length = Int(try u32())
        guard length <= maxStringLength else { throw ProtocolError.tooLarge }
        let value = try raw(length)
        guard let string = String(bytes: value, encoding: .utf8) else { throw ProtocolError.badString }
        return string
    }
}

struct RawFrame: Equatable {
    var type: UInt8
    var payload: [UInt8]
}

func encodeFrame(type: MessageType, payload: [UInt8]) -> [UInt8] {
    let length = UInt32(payload.count + 1)
    var out: [UInt8] = []
    out.reserveCapacity(payload.count + 5)
    out.append(UInt8(length >> 24))
    out.append(UInt8((length >> 16) & 0xFF))
    out.append(UInt8((length >> 8) & 0xFF))
    out.append(UInt8(length & 0xFF))
    out.append(type.rawValue)
    out.append(contentsOf: payload)
    return out
}

struct FrameDecoder {
    private var buffer: [UInt8] = []

    mutating func append(_ data: [UInt8]) {
        buffer.append(contentsOf: data)
    }

    mutating func next() throws -> RawFrame? {
        guard buffer.count >= 4 else { return nil }
        let length = (UInt32(buffer[0]) << 24) | (UInt32(buffer[1]) << 16) | (UInt32(buffer[2]) << 8) | UInt32(buffer[3])
        guard length >= 1, length <= maxFrameLength else { throw ProtocolError.invalidLength(length) }
        let total = 4 + Int(length)
        guard buffer.count >= total else { return nil }
        let type = buffer[4]
        let payload = Array(buffer[5..<total])
        buffer.removeFirst(total)
        return RawFrame(type: type, payload: payload)
    }
}

enum Messages {
    struct Hello: Equatable {
        var name: String
    }

    struct HelloAck: Equatable {
        var status: UInt8
        var width: UInt32
        var height: UInt32
        var name: String
    }

    struct VideoConfig: Equatable {
        var parameterSets: [[UInt8]]
    }

    struct VideoFrame: Equatable {
        var isKeyframe: Bool
        var timestampMicros: UInt64
        var avccData: [UInt8]
    }

    struct MouseMove: Equatable {
        var x: Float
        var y: Float
        var flags: UInt64
    }

    struct MouseButtonMsg: Equatable {
        var button: UInt8
        var down: Bool
        var flags: UInt64
    }

    struct ScrollMsg: Equatable {
        var dx: Float
        var dy: Float
        var flags: UInt64
    }

    struct KeyMsg: Equatable {
        var keyCode: UInt16
        var down: Bool
        var flags: UInt64
    }

    struct PingPong: Equatable {
        var timestampMicros: UInt64
    }

    struct Clipboard: Equatable {
        var kind: UInt8
        var text: String
    }

    /// Client → Host: the client display the remote view lives on, so the
    /// host can match its resolution / aspect ratio and size the stream.
    /// Sizes of 0 mean "unknown". Older hosts ignore this message.
    struct DisplayInfo: Equatable {
        var pointWidth: UInt32
        var pointHeight: UInt32
        var pixelWidth: UInt32
        var pixelHeight: UInt32
        /// Ask the host to switch its display mode to match this display.
        var matchResolution: Bool
    }

    /// Client → Host: a raw trackpad gesture / Dock-control CGEvent
    /// (CGEvent.data), replayed on the host. Older hosts ignore it.
    struct Gesture: Equatable {
        var eventData: [UInt8]
    }

    static let maxGestureEventBytes = 64 * 1024
    static let maxDisplayDimension: UInt32 = 32768

    static func encodeHello(_ message: Hello) throws -> [UInt8] {
        var writer = ByteWriter()
        writer.u16(protocolVersion)
        try writer.string(message.name)
        return writer.bytes
    }

    static func encodeHelloAck(_ message: HelloAck) throws -> [UInt8] {
        var writer = ByteWriter()
        writer.u8(message.status)
        writer.u32(message.width)
        writer.u32(message.height)
        try writer.string(message.name)
        return writer.bytes
    }

    static func encodeVideoConfig(_ message: VideoConfig) throws -> [UInt8] {
        var writer = ByteWriter()
        writer.u32(UInt32(message.parameterSets.count))
        for set in message.parameterSets {
            writer.u32(UInt32(set.count))
            writer.raw(set)
        }
        return writer.bytes
    }

    static func encodeVideoFrame(_ message: VideoFrame) throws -> [UInt8] {
        var writer = ByteWriter()
        writer.u8(message.isKeyframe ? 1 : 0)
        writer.u64(message.timestampMicros)
        writer.raw(message.avccData)
        return writer.bytes
    }

    static func encodeMouseMove(_ message: MouseMove) throws -> [UInt8] {
        var writer = ByteWriter()
        writer.f32(message.x)
        writer.f32(message.y)
        writer.u64(message.flags)
        return writer.bytes
    }

    static func encodeMouseButton(_ message: MouseButtonMsg) throws -> [UInt8] {
        var writer = ByteWriter()
        writer.u8(message.button)
        writer.u8(message.down ? 1 : 0)
        writer.u64(message.flags)
        return writer.bytes
    }

    static func encodeScroll(_ message: ScrollMsg) throws -> [UInt8] {
        var writer = ByteWriter()
        writer.f32(message.dx)
        writer.f32(message.dy)
        writer.u64(message.flags)
        return writer.bytes
    }

    static func encodeKey(_ message: KeyMsg) throws -> [UInt8] {
        var writer = ByteWriter()
        writer.u16(message.keyCode)
        writer.u8(message.down ? 1 : 0)
        writer.u64(message.flags)
        return writer.bytes
    }

    static func encodePing(_ message: PingPong) throws -> [UInt8] {
        var writer = ByteWriter()
        writer.u64(message.timestampMicros)
        return writer.bytes
    }

    static func encodeClipboard(_ message: Clipboard) throws -> [UInt8] {
        var writer = ByteWriter()
        writer.u8(message.kind)
        try writer.string(message.text)
        return writer.bytes
    }

    static func encodeDisplayInfo(_ message: DisplayInfo) throws -> [UInt8] {
        var writer = ByteWriter()
        writer.u8(message.matchResolution ? 1 : 0)
        writer.u32(message.pointWidth)
        writer.u32(message.pointHeight)
        writer.u32(message.pixelWidth)
        writer.u32(message.pixelHeight)
        return writer.bytes
    }

    static func encodeGesture(_ message: Gesture) throws -> [UInt8] {
        guard !message.eventData.isEmpty else { throw ProtocolError.malformed }
        guard message.eventData.count <= maxGestureEventBytes else { throw ProtocolError.tooLarge }
        var writer = ByteWriter()
        writer.raw(message.eventData)
        return writer.bytes
    }

    static func parseHello(_ payload: [UInt8]) throws -> Hello {
        var reader = ByteReader(payload)
        let version = try reader.u16()
        guard version == protocolVersion else { throw ProtocolError.malformed }
        let name = try reader.string()
        return Hello(name: name)
    }

    static func parseHelloAck(_ payload: [UInt8]) throws -> HelloAck {
        var reader = ByteReader(payload)
        let status = try reader.u8()
        let width = try reader.u32()
        let height = try reader.u32()
        let name = try reader.string()
        return HelloAck(status: status, width: width, height: height, name: name)
    }

    static func parseVideoConfig(_ payload: [UInt8]) throws -> VideoConfig {
        var reader = ByteReader(payload)
        let count = try reader.u32()
        guard count <= 64 else { throw ProtocolError.malformed }
        var sets: [[UInt8]] = []
        for _ in 0..<count {
            let length = Int(try reader.u32())
            sets.append(try reader.raw(length))
        }
        return VideoConfig(parameterSets: sets)
    }

    static func parseVideoFrame(_ payload: [UInt8]) throws -> VideoFrame {
        var reader = ByteReader(payload)
        let flags = try reader.u8()
        let timestamp = try reader.u64()
        let remaining = reader.remaining
        let avcc = try reader.raw(remaining)
        return VideoFrame(isKeyframe: flags & 1 != 0, timestampMicros: timestamp, avccData: avcc)
    }

    static func parseMouseMove(_ payload: [UInt8]) throws -> MouseMove {
        var reader = ByteReader(payload)
        let x = try reader.f32()
        let y = try reader.f32()
        let flags = try reader.u64()
        return MouseMove(x: x, y: y, flags: flags)
    }

    static func parseMouseButton(_ payload: [UInt8]) throws -> MouseButtonMsg {
        var reader = ByteReader(payload)
        let button = try reader.u8()
        let down = try reader.u8() != 0
        let flags = try reader.u64()
        return MouseButtonMsg(button: button, down: down, flags: flags)
    }

    static func parseScroll(_ payload: [UInt8]) throws -> ScrollMsg {
        var reader = ByteReader(payload)
        let dx = try reader.f32()
        let dy = try reader.f32()
        let flags = try reader.u64()
        return ScrollMsg(dx: dx, dy: dy, flags: flags)
    }

    static func parseKey(_ payload: [UInt8]) throws -> KeyMsg {
        var reader = ByteReader(payload)
        let keyCode = try reader.u16()
        let down = try reader.u8() != 0
        let flags = try reader.u64()
        return KeyMsg(keyCode: keyCode, down: down, flags: flags)
    }

    static func parsePing(_ payload: [UInt8]) throws -> PingPong {
        var reader = ByteReader(payload)
        let timestamp = try reader.u64()
        return PingPong(timestampMicros: timestamp)
    }

    static func parseClipboard(_ payload: [UInt8]) throws -> Clipboard {
        var reader = ByteReader(payload)
        let kind = try reader.u8()
        let text = try reader.string()
        return Clipboard(kind: kind, text: text)
    }

    static func parseDisplayInfo(_ payload: [UInt8]) throws -> DisplayInfo {
        var reader = ByteReader(payload)
        let flags = try reader.u8()
        let pointWidth = try reader.u32()
        let pointHeight = try reader.u32()
        let pixelWidth = try reader.u32()
        let pixelHeight = try reader.u32()
        for value in [pointWidth, pointHeight, pixelWidth, pixelHeight] where value > maxDisplayDimension {
            throw ProtocolError.tooLarge
        }
        return DisplayInfo(
            pointWidth: pointWidth,
            pointHeight: pointHeight,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            matchResolution: flags & 1 != 0
        )
    }

    static func parseGesture(_ payload: [UInt8]) throws -> Gesture {
        guard !payload.isEmpty else { throw ProtocolError.malformed }
        guard payload.count <= maxGestureEventBytes else { throw ProtocolError.tooLarge }
        return Gesture(eventData: payload)
    }
}
