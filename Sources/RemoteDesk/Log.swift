import Foundation

enum Log {
    private static let lock = NSLock()
    static var verbose = false

    static func info(_ message: String) { log("INFO", message) }
    static func warn(_ message: String) { log("WARN", message) }
    static func error(_ message: String) { log("ERROR", message) }

    static func debug(_ message: String) {
        guard verbose else { return }
        log("DEBUG", message)
    }

    private static func log(_ level: String, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardError.write(Data("[\(level)] \(message)\n".utf8))
    }
}
