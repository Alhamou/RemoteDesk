import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

final class VideoEncoder {
    typealias FormatHandler = (_ parameterSets: [[UInt8]]) -> Void
    typealias FrameHandler = (_ avcc: [UInt8], _ timestampMicros: UInt64, _ isKeyframe: Bool) -> Void

    private let queue: DispatchQueue
    private let fps: Int
    private let bitrate: Int
    private let onFormatChange: FormatHandler
    private let onFrame: FrameHandler

    private var session: VTCompressionSession?
    private var width: Int
    private var height: Int
    private var lastParameterSets: [[UInt8]] = []
    private var keyframeRequested = false
    private var invalidated = false
    private let lock = NSLock()

    init(width: Int, height: Int, fps: Int, bitrate: Int,
         queue: DispatchQueue,
         onFormatChange: @escaping FormatHandler,
         onFrame: @escaping FrameHandler) {
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrate = bitrate
        self.queue = queue
        self.onFormatChange = onFormatChange
        self.onFrame = onFrame
        createSession()
    }

    func forceKeyframe() {
        lock.lock()
        keyframeRequested = true
        lock.unlock()
    }

    func encode(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        queue.async { [weak self] in
            self?.encodeOnQueue(pixelBuffer: pixelBuffer, presentationTime: presentationTime)
        }
    }

    func invalidate() {
        queue.async { [weak self] in
            guard let self, !self.invalidated else { return }
            self.invalidated = true
            self.teardownSession()
        }
    }

    private func createSession() {
        let lowLatencySpec: [String: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String: true,
        ]
        if let session = createSessionOnce(specification: lowLatencySpec) {
            self.session = session
            return
        }
        let hardwareSpec: [String: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
        ]
        if let session = createSessionOnce(specification: hardwareSpec) {
            self.session = session
            return
        }
        Log.error("video encoder: failed to create H.264 compression session")
    }

    private func createSessionOnce(specification: [String: Any]) -> VTCompressionSession? {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: specification as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session)
        guard status == noErr, let created = session else {
            return nil
        }
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitrate))
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: fps * 2))
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: 2))
        VTCompressionSessionPrepareToEncodeFrames(created)
        return created
    }

    private func teardownSession() {
        if let session {
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        lastParameterSets = []
    }

    private func encodeOnQueue(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        guard !invalidated else { return }

        let bufferWidth = CVPixelBufferGetWidth(pixelBuffer)
        let bufferHeight = CVPixelBufferGetHeight(pixelBuffer)
        if bufferWidth != width || bufferHeight != height {
            teardownSession()
            width = bufferWidth
            height = bufferHeight
            createSession()
        }
        guard let session else { return }

        lock.lock()
        let forceKeyframe = keyframeRequested
        keyframeRequested = false
        lock.unlock()

        let frameProperties: CFDictionary? = forceKeyframe
            ? ([kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary)
            : nil

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: .invalid,
            frameProperties: frameProperties,
            infoFlagsOut: nil,
            outputHandler: { [weak self] status, _, sampleBuffer in
                guard let self else { return }
                self.queue.async {
                    self.handleEncodedFrame(status: status, sampleBuffer: sampleBuffer)
                }
            }
        )
        if status != noErr {
            Log.error("video encoder: encode call failed (\(status))")
        }
    }

    private func handleEncodedFrame(status: OSStatus, sampleBuffer: CMSampleBuffer?) {
        guard status == noErr, let sampleBuffer else { return }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }

        let isKeyframe = Self.isKeyframeSample(sampleBuffer)

        if let parameterSets = Self.parameterSets(from: formatDescription), parameterSets != lastParameterSets {
            lastParameterSets = parameterSets
            onFormatChange(parameterSets)
        }

        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(dataBuffer)
        guard length > 0 else { return }
        var bytes = [UInt8](repeating: 0, count: length)
        let copyStatus = bytes.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: length, destination: base)
        }
        guard copyStatus == noErr else {
            Log.error("video encoder: failed to copy encoded bytes (\(copyStatus))")
            return
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timestampMicros = UInt64(max(0, CMTimeGetSeconds(pts) * 1_000_000))
        onFrame(bytes, timestampMicros, isKeyframe)
    }

    private static func parameterSets(from formatDescription: CMFormatDescription) -> [[UInt8]]? {
        var count = 0
        var nalLength: Int32 = 0
        let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: &nalLength)
        guard status == noErr, count > 0 else { return nil }

        var sets: [[UInt8]] = []
        sets.reserveCapacity(count)
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let setStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil)
            guard setStatus == noErr, let pointer else { return nil }
            sets.append(Array(UnsafeBufferPointer(start: pointer, count: size)))
        }
        return sets
    }

    private static func isKeyframeSample(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[String: Any]],
              let first = attachments.first else {
            return true
        }
        if let notSync = first[kCMSampleAttachmentKey_NotSync as String] as? Bool {
            return !notSync
        }
        if let notSync = first[kCMSampleAttachmentKey_NotSync as String] as? NSNumber {
            return !notSync.boolValue
        }
        return true
    }
}
