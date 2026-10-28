import CoreGraphics
import Foundation

/// Host side of "fit the remote Mac to the client's screen": switches the
/// host's main display to the mode that best matches the client display
/// (see DisplayFit.bestMode).
///
/// Changes are applied with `.forAppOnly`, so macOS puts the original mode
/// back by itself if RemoteDesk quits or crashes; `restore()` does it as
/// soon as the client goes away. Use from the main thread only.
final class DisplayModeMatcher {
    private let displayID: CGDirectDisplayID
    private var originalMode: CGDisplayMode?

    init(displayID: CGDirectDisplayID = CGMainDisplayID()) {
        self.displayID = displayID
    }

    /// Returns true when the display mode was changed.
    @discardableResult
    func match(pointWidth: Int, pointHeight: Int, preferHiDPI: Bool) -> Bool {
        guard let current = CGDisplayCopyDisplayMode(displayID) else { return false }
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        guard let all = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else { return false }
        let modes = all.filter { $0.isUsableForDesktopGUI() }
        let candidates = modes.map(Self.candidate)
        guard let best = DisplayFit.bestMode(
            among: candidates,
            current: Self.candidate(current),
            targetWidth: pointWidth,
            targetHeight: pointHeight,
            preferHiDPI: preferHiDPI
        ), let index = candidates.firstIndex(of: best) else {
            Log.info("display mode: current mode already fits \(pointWidth)x\(pointHeight)")
            return false
        }
        let originalBefore = originalMode
        if originalMode == nil {
            originalMode = current
        }
        guard apply(modes[index]) else {
            originalMode = originalBefore
            return false
        }
        Log.info("display mode: switched to \(best.width)x\(best.height) (\(best.pixelWidth)x\(best.pixelHeight) px) for client \(pointWidth)x\(pointHeight)")
        return true
    }

    /// Puts back the mode that was active before the first `match`.
    /// Returns true when the display mode was changed.
    @discardableResult
    func restore() -> Bool {
        guard let original = originalMode else { return false }
        originalMode = nil
        guard apply(original) else { return false }
        Log.info("display mode: restored \(original.width)x\(original.height)")
        return true
    }

    private func apply(_ mode: CGDisplayMode) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else {
            Log.warn("display mode: cannot begin configuration")
            return false
        }
        guard CGConfigureDisplayWithDisplayMode(config, displayID, mode, nil) == .success else {
            CGCancelDisplayConfiguration(config)
            Log.warn("display mode: cannot configure \(mode.width)x\(mode.height)")
            return false
        }
        let result = CGCompleteDisplayConfiguration(config, .forAppOnly)
        guard result == .success else {
            Log.warn("display mode: switching failed (\(result.rawValue))")
            return false
        }
        return true
    }

    private static func candidate(_ mode: CGDisplayMode) -> DisplayModeCandidate {
        DisplayModeCandidate(
            width: mode.width,
            height: mode.height,
            pixelWidth: mode.pixelWidth,
            pixelHeight: mode.pixelHeight,
            refreshRate: mode.refreshRate
        )
    }
}
