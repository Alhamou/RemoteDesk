import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import CoreGraphics

final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    var onError: ((Error) -> Void)?

    private let queue: DispatchQueue
    private var stream: SCStream?
    private var running = false

    init(queue: DispatchQueue) {
        self.queue = queue
        super.init()
    }

    /// `fitWithin`: the client's screen in pixels, when known — the stream
    /// is never made larger than that (see DisplayFit.streamSize).
    func start(fps: Int, maxDimension: Int, fitWithin: (width: Int, height: Int)? = nil, completion: @escaping (Result<(Int, Int), Error>) -> Void) {
        guard !running else {
            completion(.failure(CaptureError.alreadyRunning))
            return
        }
        // The system permission request is owned by PermissionFlow (shown to
        // the user with a prior explanation). Here we only verify: if the
        // permission is not active we fail quietly without prompting, so no
        // duplicate system dialog or overlapping alert ever appears.
        if !CGPreflightScreenCaptureAccess() {
            completion(.failure(CaptureError.permissionDenied))
            return
        }
        running = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let mainID = CGMainDisplayID()
                guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
                    throw CaptureError.noDisplay
                }
                let size = ScreenCapturer.targetSize(display: display, maxDimension: maxDimension, fitWithin: fitWithin)
                let configuration = SCStreamConfiguration()
                configuration.width = size.width
                configuration.height = size.height
                configuration.pixelFormat = kCVPixelFormatType_32BGRA
                configuration.showsCursor = true
                configuration.queueDepth = 3
                let clampedFps = min(max(fps, 1), 60)
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(clampedFps))
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                try await stream.startCapture()
                guard self.running else {
                    // stop() was called while the stream was starting.
                    try? await stream.stopCapture()
                    return
                }
                self.stream = stream
                Log.info("capturing display \(display.displayID) at \(size.width)x\(size.height) @\(clampedFps)fps")
                completion(.success((size.width, size.height)))
            } catch {
                self.running = false
                completion(.failure(error))
            }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        let stream = self.stream
        self.stream = nil
        guard let stream else { return }
        Task {
            do {
                try await stream.stopCapture()
            } catch {
                Log.warn("capture stop failed: \(error)")
            }
        }
    }

    private static func targetSize(display: SCDisplay, maxDimension: Int, fitWithin: (width: Int, height: Int)?) -> (width: Int, height: Int) {
        let source = sourcePixelSize(displayID: display.displayID)
            ?? (width: display.width, height: display.height)
        return DisplayFit.streamSize(
            sourceWidth: source.width,
            sourceHeight: source.height,
            maxDimension: maxDimension,
            fitWidth: fitWithin?.width,
            fitHeight: fitWithin?.height
        )
    }

    /// The stream size a capture of `displayID` would use right now.
    static func expectedSize(displayID: CGDirectDisplayID, maxDimension: Int, fitWithin: (width: Int, height: Int)?) -> (width: Int, height: Int)? {
        guard let source = sourcePixelSize(displayID: displayID) else { return nil }
        return DisplayFit.streamSize(
            sourceWidth: source.width,
            sourceHeight: source.height,
            maxDimension: maxDimension,
            fitWidth: fitWithin?.width,
            fitHeight: fitWithin?.height
        )
    }

    /// Real backing pixels of the display's current mode (2x the point size
    /// on Retina / HiDPI modes), so Retina clients get a sharp picture.
    private static func sourcePixelSize(displayID: CGDirectDisplayID) -> (width: Int, height: Int)? {
        if let mode = CGDisplayCopyDisplayMode(displayID), mode.pixelWidth > 0, mode.pixelHeight > 0 {
            return (mode.pixelWidth, mode.pixelHeight)
        }
        let width = CGDisplayPixelsWide(displayID)
        let height = CGDisplayPixelsHigh(displayID)
        guard width > 0, height > 0 else { return nil }
        return (width, height)
    }
}

extension ScreenCapturer {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard sampleBuffer.isValid else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]] else { return }
        guard let statusValue = attachments.first?[SCStreamFrameInfo.status] as? Int else { return }
        guard let status = SCFrameStatus(rawValue: statusValue), status == .complete else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        onFrame?(pixelBuffer, pts)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [weak self] in
            // A stream we replaced or stopped on purpose (e.g. around a
            // display mode switch) is not an error.
            guard let self, stream === self.stream else { return }
            Log.warn("capture stream stopped: \(error)")
            self.running = false
            self.onError?(error)
        }
    }
}

extension ScreenCapturer {
    enum CaptureError: LocalizedError {
        case noDisplay
        case alreadyRunning
        case permissionDenied

        var errorDescription: String? {
            switch self {
            case .noDisplay: return "no display available for capture"
            case .alreadyRunning: return "capture already running"
            case .permissionDenied: return "Screen Recording permission is required. Please grant permission in System Settings → Privacy & Security → Screen Recording, then quit and reopen RemoteDesk (Cmd+Q)."
            }
        }
    }
}
