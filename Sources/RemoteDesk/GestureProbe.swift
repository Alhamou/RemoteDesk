import Foundation
import CoreGraphics
import ApplicationServices

/// Debug tool: logs every field of every kCGEventGesture (type 29) event
/// for N seconds, so the private field layout can be determined empirically.
/// Passive (listen-only) tap — swipes still act locally while probing.
/// Writes to stdout and /tmp/rd-gesture-probe.log.
enum GestureProbe {
    static let logPath = "/tmp/rd-gesture-probe.log"
    private static var logHandle: FileHandle?

    private static func emit(_ line: String) {
        logHandle?.write(Data((line + "\n").utf8))
        print(line)
        fflush(stdout)
    }

    static func run(seconds: Double) {
        guard FileManager.default.createFile(atPath: logPath, contents: nil) else {
            FileHandle.standardError.write(Data("error: cannot create \(logPath)\n".utf8))
            exit(4)
        }
        guard let logFile = FileHandle(forWritingAtPath: logPath) else {
            FileHandle.standardError.write(Data("error: cannot open \(logPath)\n".utf8))
            exit(4)
        }
        logHandle = logFile
        guard AXIsProcessTrusted() else {
            emit("ERROR: Accessibility not granted to this process; cannot tap gesture events")
            exit(2)
        }
        let mask: CGEventMask = 1 << 29
        let callback: CGEventTapCallBack = { _, type, event, _ in
            let ts = Date().timeIntervalSince1970
            var line = String(format: "[%.3f] type=%d", ts, type.rawValue)
            var ints: [String] = []
            for field: UInt32 in 0..<160 {
                let v = event.getIntegerValueField(CGEventField(rawValue: field)!)
                if v != 0 { ints.append("i\(field)=\(v)") }
            }
            var dbls: [String] = []
            for field: UInt32 in 0..<160 {
                let v = event.getDoubleValueField(CGEventField(rawValue: field)!)
                if v != 0 { dbls.append(String(format: "d%d=%.4f", field, v)) }
            }
            line += " " + ints.joined(separator: " ")
            line += " " + dbls.joined(separator: " ")
            GestureProbe.emit(line)
            return Unmanaged.passRetained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: nil
        ) else {
            emit("ERROR: failed to create gesture tap")
            exit(3)
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        emit("PROBE STARTED — waiting for gestures…")
        CFRunLoopRunInMode(.defaultMode, seconds, false)
        emit("PROBE DONE")
    }
}
