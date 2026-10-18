import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

final class VideoDecoder {
    typealias FrameHandler = (_ imageBuffer: CVImageBuffer) -> Void

    private let queue: DispatchQueue
    private let onFrame: FrameHandler

    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var lastParameterSets: [[UInt8]] = []

    init(queue: DispatchQueue, onFrame: @escaping FrameHandler) {
        self.queue = queue
        self.onFrame = onFrame
    }

    func configure(parameterSets: [[UInt8]]) throws {
        guard !parameterSets.isEmpty else { throw ProtocolError.malformed }
        queue.async { [weak self] in
            self?.configureOnQueue(parameterSets: parameterSets)
        }
    }

    func decode(avcc: [UInt8], timestampMicros: UInt64, isKeyframe: Bool) {
        queue.async { [weak self] in
            self?.decodeOnQueue(avcc: avcc, timestampMicros: timestampMicros, isKeyframe: isKeyframe)
        }
    }

    func invalidate() {
        queue.async { [weak self] in
            guard let self else { return }
            self.teardownSession()
            self.lastParameterSets = []
        }
    }

    private func teardownSession() {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        formatDescription = nil
    }

    private func configureOnQueue(parameterSets: [[UInt8]]) {
        if parameterSets == lastParameterSets { return }
        lastParameterSets = parameterSets
        teardownSession()

        guard let description = Self.makeFormatDescription(parameterSets: parameterSets) else {
            Log.error("video decoder: failed to create format description")
            return
        }
        formatDescription = description

        var session: VTDecompressionSession?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        let specification: [String: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: true,
        ]
        var status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: description,
            decoderSpecification: specification as CFDictionary,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session)
        if status != noErr || session == nil {
            status = VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                formatDescription: description,
                decoderSpecification: nil,
                imageBufferAttributes: nil,
                outputCallback: nil,
                decompressionSessionOut: &session)
        }
        guard status == noErr, let created = session else {
            Log.error("video decoder: failed to create decompression session (\(status))")
            return
        }
        self.session = created
    }

    private static func makeFormatDescription(parameterSets: [[UInt8]]) -> CMVideoFormatDescription? {
        var buffers: [UnsafeMutablePointer<UInt8>] = []
        for set in parameterSets {
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            buffer.update(from: set, count: set.count)
            buffers.append(buffer)
        }
        defer { buffers.forEach { $0.deallocate() } }

        let pointers: [UnsafePointer<UInt8>] = buffers.map { UnsafePointer($0) }
        let sizes: [Int] = parameterSets.map { $0.count }
        var formatDescription: CMVideoFormatDescription?
        let status = pointers.withUnsafeBufferPointer { pointerBuffer -> OSStatus in
            guard let base = pointerBuffer.baseAddress else { return -1 }
            return sizes.withUnsafeBufferPointer { sizeBuffer -> OSStatus in
                guard let sizeBase = sizeBuffer.baseAddress else { return -1 }
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: parameterSets.count,
                    parameterSetPointers: base,
                    parameterSetSizes: sizeBase,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDescription)
            }
        }
        guard status == noErr else { return nil }
        return formatDescription
    }

    private func decodeOnQueue(avcc: [UInt8], timestampMicros: UInt64, isKeyframe: Bool) {
        guard let session, let formatDescription else { return }
        guard !avcc.isEmpty else { return }

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: 0,
            blockBufferOut: &blockBuffer)
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            Log.error("video decoder: failed to create block buffer (\(status))")
            return
        }

        status = avcc.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: avcc.count)
        }
        guard status == kCMBlockBufferNoErr else {
            Log.error("video decoder: failed to copy frame bytes (\(status))")
            return
        }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: Int64(timestampMicros), timescale: 1_000_000),
            decodeTimeStamp: .invalid)
        var sampleSize = avcc.count
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else {
            Log.error("video decoder: failed to create sample buffer (\(status))")
            return
        }

        if !isKeyframe {
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
               CFArrayGetCount(attachments) > 0,
               let raw = CFArrayGetValueAtIndex(attachments, 0) {
                let dictionary = unsafeBitCast(raw, to: CFMutableDictionary.self)
                CFDictionarySetValue(
                    dictionary,
                    unsafeBitCast(kCMSampleAttachmentKey_NotSync, to: UnsafeRawPointer.self),
                    unsafeBitCast(kCFBooleanTrue, to: UnsafeRawPointer.self))
            }
        }

        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [],
            infoFlagsOut: nil,
            outputHandler: { [weak self] status, _, imageBuffer, _, _ in
                guard status == noErr, let imageBuffer else { return }
                guard let self else { return }
                self.queue.async {
                    self.onFrame(imageBuffer)
                }
            }
        )
        if decodeStatus != noErr {
            Log.error("video decoder: decode call failed (\(decodeStatus))")
        }
    }
}
