import Foundation
import AppKit
import CoreMedia
import CoreText
import CoreVideo
import QuartzCore

final class TestPattern {
    typealias FrameHandler = (_ pixelBuffer: CVPixelBuffer, _ presentationTime: CMTime) -> Void

    let width: Int
    let height: Int
    private let fps: Int
    private let queue: DispatchQueue
    private let onFrame: FrameHandler

    private var pool: CVPixelBufferPool?
    private var timer: DispatchSourceTimer?
    private var frameIndex = 0
    private var startTime: CFTimeInterval = 0
    private var staticLine: CTLine?
    private var loggedPoolFailure = false

    init(width: Int, height: Int, fps: Int, queue: DispatchQueue, onFrame: @escaping FrameHandler) {
        self.width = width
        self.height = height
        self.fps = max(1, fps)
        self.queue = queue
        self.onFrame = onFrame
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            if self.pool == nil {
                self.createPool()
            }
            if self.staticLine == nil {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: 28, weight: .semibold),
                    .foregroundColor: NSColor.white,
                ]
                self.staticLine = CTLineCreateWithAttributedString(
                    NSAttributedString(string: "RemoteDesk test pattern", attributes: attributes))
            }
            self.startTime = CACurrentMediaTime()
            let interval = 1.0 / Double(self.fps)
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in
                self?.renderFrame()
            }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.timer?.cancel()
            self.timer = nil
        }
    }

    private func createPool() {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        guard status == kCVReturnSuccess else {
            Log.error("test pattern: failed to create pixel buffer pool (\(status))")
            return
        }
        self.pool = pool
    }

    private func renderFrame() {
        guard let pool else { return }
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        guard status == kCVReturnSuccess, let pixelBuffer else {
            if !loggedPoolFailure {
                loggedPoolFailure = true
                Log.warn("test pattern: pixel buffer pool exhausted")
            }
            return
        }
        loggedPoolFailure = false

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let context = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }

        let elapsed = CACurrentMediaTime() - startTime

        context.setFillColor(NSColor(calibratedWhite: 0.07, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))

        let radius: CGFloat = 40
        let travelX = max(0, CGFloat(width) - radius * 2)
        let travelY = max(0, CGFloat(height) - radius * 2)
        let circleX = (sin(elapsed * 1.5) * 0.5 + 0.5) * travelX + radius
        let circleY = (cos(elapsed * 2.0) * 0.5 + 0.5) * travelY + radius
        context.setFillColor(NSColor.systemTeal.cgColor)
        context.fillEllipse(in: CGRect(x: circleX - radius, y: circleY - radius, width: radius * 2, height: radius * 2))

        context.textMatrix = .identity
        if let staticLine {
            context.textPosition = CGPoint(x: 24, y: 24)
            CTLineDraw(staticLine, context)
        }

        let counterText = "Frame \(frameIndex)   t=\(String(format: "%.1f", elapsed))s"
        let counterAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 22, weight: .regular),
            .foregroundColor: NSColor.white,
        ]
        let counterLine = CTLineCreateWithAttributedString(
            NSAttributedString(string: counterText, attributes: counterAttributes))
        context.textPosition = CGPoint(x: 24, y: CGFloat(height) - 46)
        CTLineDraw(counterLine, context)

        let presentationTime = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(fps))
        frameIndex += 1
        onFrame(pixelBuffer, presentationTime)
    }
}
