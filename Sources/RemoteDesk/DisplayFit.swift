import Foundation

/// A host display mode, reduced to what mode matching needs (sizes in
/// points and pixels). Kept free of CoreGraphics so the choice is testable.
struct DisplayModeCandidate: Equatable {
    var width: Int
    var height: Int
    var pixelWidth: Int
    var pixelHeight: Int
    var refreshRate: Double

    var isHiDPI: Bool { pixelWidth > width }
}

/// Pure sizing rules for "fit the remote Mac to the client's screen".
enum DisplayFit {
    /// Picks the host display mode that best matches a client display of
    /// `targetWidth` x `targetHeight` points: closest aspect ratio first (so
    /// full screen fills without black bars), then closest size, then HiDPI
    /// when the client is Retina, then the highest refresh rate.
    ///
    /// Returns nil when no candidate beats `current`, i.e. switching would
    /// not improve the fit.
    static func bestMode(
        among candidates: [DisplayModeCandidate],
        current: DisplayModeCandidate,
        targetWidth: Int,
        targetHeight: Int,
        preferHiDPI: Bool
    ) -> DisplayModeCandidate? {
        guard targetWidth > 0, targetHeight > 0 else { return nil }
        let targetAspect = Double(targetWidth) / Double(targetHeight)

        func score(_ mode: DisplayModeCandidate) -> (Int, Int, Int, Int, Double) {
            guard mode.width > 0, mode.height > 0 else { return (Int.max, Int.max, Int.max, Int.max, 0) }
            let aspect = Double(mode.width) / Double(mode.height)
            // ~1% steps: modes within rounding of each other tie on aspect.
            let aspectBucket = Int((abs(log(aspect / targetAspect)) * 100).rounded())
            // ~5% steps of width difference: a much smaller HiDPI mode never
            // beats a similar-sized standard one just for being HiDPI.
            let sizeBucket = Int((Double(abs(mode.width - targetWidth)) / Double(targetWidth) * 20).rounded())
            let densityPenalty = preferHiDPI && !mode.isHiDPI ? 1 : 0
            let sizeDiff = abs(mode.width - targetWidth) + abs(mode.height - targetHeight)
            return (aspectBucket, sizeBucket, densityPenalty, sizeDiff, -mode.refreshRate)
        }

        guard let best = candidates.min(by: { score($0) < score($1) }) else { return nil }
        return score(best) < score(current) ? best : nil
    }

    /// Stream size for a source of `sourceWidth` x `sourceHeight` pixels:
    /// longest side capped at `maxDimension`, and never larger than the
    /// client's screen (`fitWidth` x `fitHeight` pixels) when known — extra
    /// pixels would only cost bandwidth. Aspect ratio is preserved and both
    /// sides are even (hardware encoder requirement).
    static func streamSize(
        sourceWidth: Int,
        sourceHeight: Int,
        maxDimension: Int,
        fitWidth: Int? = nil,
        fitHeight: Int? = nil
    ) -> (width: Int, height: Int) {
        guard sourceWidth > 0, sourceHeight > 0 else { return (2, 2) }
        var scale = 1.0
        let longest = max(sourceWidth, sourceHeight)
        if maxDimension > 0, longest > maxDimension {
            scale = min(scale, Double(maxDimension) / Double(longest))
        }
        if let fitWidth, let fitHeight, fitWidth > 0, fitHeight > 0 {
            scale = min(scale, Double(fitWidth) / Double(sourceWidth), Double(fitHeight) / Double(sourceHeight))
        }
        let width = Int((Double(sourceWidth) * scale).rounded())
        let height = Int((Double(sourceHeight) * scale).rounded())
        return (max(2, width & ~1), max(2, height & ~1))
    }
}
