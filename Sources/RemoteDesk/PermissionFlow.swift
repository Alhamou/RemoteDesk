import AppKit
import ApplicationServices
import CoreGraphics

enum PermissionKind {
    case screenRecording
    case accessibility
}

/// Permission helpers for the host.
///
/// Policy: **native macOS dialogs only — RemoteDesk never shows its own
/// permission popups.** Clicking "Share This Mac" triggers the system's own
/// request directly. Any guidance is shown as plain inline text in the app
/// window (status label / host view button), never as a modal popup.
enum PermissionFlow {
    // MARK: - Status

    static var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    // MARK: - Native Requests

    /// Shows the native Screen Recording consent dialog (nothing if macOS
    /// already recorded a denial). The permission only takes effect after
    /// the app relaunches.
    static func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
    }

    /// Shows the native Accessibility consent dialog (nothing if macOS
    /// already recorded a denial). Applies live — no relaunch needed.
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: - System Settings

    static func openSettings(for kind: PermissionKind) {
        let pane: String
        switch kind {
        case .screenRecording: pane = "Privacy_ScreenCapture"
        case .accessibility: pane = "Privacy_Accessibility"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Relaunch

    /// Quits and relaunches the app (required for macOS to apply a freshly
    /// granted Screen Recording permission).
    static func relaunchApp() {
        let task = Process()
        let bundle = Bundle.main
        if bundle.bundleIdentifier != nil, bundle.bundleURL.pathExtension == "app" {
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-n", "-a", bundle.bundleURL.path]
        } else {
            let executable = CommandLine.arguments.first ?? ""
            guard !executable.isEmpty else {
                NSApp.terminate(nil)
                return
            }
            task.executableURL = URL(fileURLWithPath: executable)
            task.arguments = Array(CommandLine.arguments.dropFirst())
        }
        do {
            try task.run()
        } catch {
            Log.warn("relaunch failed: \(error)")
        }
        NSApp.terminate(nil)
    }
}
