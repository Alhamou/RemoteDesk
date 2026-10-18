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

    func start(fps: Int, maxDimension: Int, completion: @escaping (Result<(Int, Int), Error>) -> Void) {
        guard !running else {
            completion(.failure(CaptureError.alreadyRunning))
            return
        }
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
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
                let size = ScreenCapturer.targetSize(display: display, maxDimension: maxDimension)
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

    private static func targetSize(display: SCDisplay, maxDimension: Int) -> (width: Int, height: Int) {
        let pixelWidth = CGDisplayPixelsWide(display.displayID)
        let pixelHeight = CGDisplayPixelsHigh(display.displayID)
        let baseWidth = pixelWidth > 0 ? pixelWidth : display.width
        let baseHeight = pixelHeight > 0 ? pixelHeight : display.height
        var width = baseWidth
        var height = baseHeight
        let longest = max(width, height)
        if maxDimension > 0 && longest > maxDimension {
            let scale = Double(maxDimension) / Double(longest)
            width = Int((Double(width) * scale).rounded())
            height = Int((Double(height) * scale).rounded())
        }
        width = max(2, width & ~1)
        height = max(2, height & ~1)
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
            guard let self else { return }
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
