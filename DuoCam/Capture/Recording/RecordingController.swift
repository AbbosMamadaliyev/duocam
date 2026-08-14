import AVFoundation
import CoreMedia
import CoreVideo
import os

/// Writes composited frames and audio to a file.
///
/// Doc 3 Phase 2 tasks 5–8. Two details there are easy to get subtly wrong and
/// both are handled explicitly below:
///
/// - `startSession(atSourceTime:)` takes the **first buffer's PTS**, not
///   `.zero`. Passing zero produces a file whose first frames are timestamped
///   far in the future relative to the session start, which plays as a long
///   freeze before anything moves.
/// - Pause/resume works by accumulating paused duration and subtracting it from
///   every subsequent timestamp, so the output is one continuous file rather
///   than a file with a gap in it.
final class RecordingController: @unchecked Sendable {
    enum State: Equatable {
        case idle
        case recording
        case paused
        case finishing
    }

    private(set) var state: State = .idle

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?

    private var outputURL: URL?
    private var sessionStartTime: CMTime?
    private var pausedAccumulated: CMTime = .zero
    private var pauseBeganAt: CMTime?

    private(set) var framesAppended = 0
    private(set) var framesDropped = 0

    private let lock = NSLock()

    // MARK: Start

    func start(
        outputSize: CGSize,
        quality: QualityProfile,
        hasAudio: Bool
    ) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        guard state == .idle else { throw RecordingError.alreadyRecording }

        let url = Self.makeOutputURL()
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: quality.codec.avCodecType,
            AVVideoWidthKey: Int(outputSize.width),
            AVVideoHeightKey: Int(outputSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: quality.resolution.targetBitrate,
                AVVideoExpectedSourceFrameRateKey: quality.frameRate.rawValue,
                AVVideoMaxKeyFrameIntervalKey: quality.frameRate.rawValue * 2,
            ],
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        // Without this the writer buffers aggressively and the capture pipeline
        // stalls behind it.
        videoInput.expectsMediaDataInRealTime = true

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(outputSize.width),
                kCVPixelBufferHeightKey as String: Int(outputSize.height),
            ]
        )

        guard writer.canAdd(videoInput) else { throw RecordingError.inputRejected("video") }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if hasAudio {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000,
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            } else {
                // Doc 3 error-handling rule: degrade, do not fail. A recording
                // without sound beats no recording.
                Log.recording.error("Audio input rejected — recording will be silent")
            }
        }

        guard writer.startWriting() else {
            throw RecordingError.writerFailed(writer.error?.localizedDescription ?? "unknown")
        }

        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
        self.adaptor = adaptor
        self.outputURL = url
        sessionStartTime = nil
        pausedAccumulated = .zero
        pauseBeganAt = nil
        framesAppended = 0
        framesDropped = 0
        state = .recording

        Log.recording.info(
            "Recording started → \(url.lastPathComponent, privacy: .public) at \(Int(outputSize.width))×\(Int(outputSize.height))"
        )
        return url
    }

    // MARK: Append

    func appendVideo(_ pixels: CVPixelBuffer, at rawTime: CMTime) {
        lock.lock()
        defer { lock.unlock() }

        guard state == .recording,
              let writer, let videoInput, let adaptor,
              writer.status == .writing
        else {
            if state == .recording { framesDropped += 1 }
            return
        }

        // The session's zero point is the first frame's own timestamp.
        if sessionStartTime == nil {
            sessionStartTime = rawTime
            writer.startSession(atSourceTime: rawTime)
            Log.recording.info("Session start time \(rawTime.seconds, format: .fixed(precision: 3))s")
        }

        guard videoInput.isReadyForMoreMediaData else {
            framesDropped += 1
            return
        }

        let presentationTime = CMTimeSubtract(rawTime, pausedAccumulated)
        if adaptor.append(pixels, withPresentationTime: presentationTime) {
            framesAppended += 1
        } else {
            framesDropped += 1
            Log.recording.error("Frame append failed: \(writer.error?.localizedDescription ?? "unknown", privacy: .public)")
        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }

        guard state == .recording,
              let writer, writer.status == .writing,
              let audioInput, audioInput.isReadyForMoreMediaData,
              sessionStartTime != nil
        else { return }

        // Audio has to be shifted by the same accumulated pause offset as
        // video, or the two drift apart by exactly the pause duration.
        if pausedAccumulated == .zero {
            audioInput.append(sampleBuffer)
            return
        }

        var timing = CMSampleTimingInfo()
        guard CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timing)
                == noErr
        else { return }
        timing.presentationTimeStamp = CMTimeSubtract(timing.presentationTimeStamp, pausedAccumulated)

        var adjusted: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &adjusted
        ) == noErr, let adjusted else { return }

        audioInput.append(adjusted)
    }

    // MARK: Pause

    func pause(at time: CMTime) {
        lock.lock()
        defer { lock.unlock() }
        guard state == .recording else { return }
        pauseBeganAt = time
        state = .paused
        Log.recording.info("Recording paused")
    }

    func resume(at time: CMTime) {
        lock.lock()
        defer { lock.unlock() }
        guard state == .paused, let pauseBeganAt else { return }
        pausedAccumulated = CMTimeAdd(pausedAccumulated, CMTimeSubtract(time, pauseBeganAt))
        self.pauseBeganAt = nil
        state = .recording
        Log.recording.info("Recording resumed · total paused \(self.pausedAccumulated.seconds, format: .fixed(precision: 2))s")
    }

    // MARK: Finish

    /// Finalises and returns the file.
    ///
    /// Called on interruption and on thermal shutdown as well as on a normal
    /// stop, because Doc 3 Phase 2's criteria require that an interrupted
    /// recording still yields a playable file covering everything captured up
    /// to that point — never a corrupt one.
    func finish() async -> RecordingResult? {
        lock.lock()
        guard state != .idle, let writer, let videoInput, let url = outputURL else {
            lock.unlock()
            return nil
        }
        state = .finishing
        let appended = framesAppended
        let dropped = framesDropped
        lock.unlock()

        videoInput.markAsFinished()
        audioInput?.markAsFinished()

        await writer.finishWriting()

        lock.lock()
        self.writer = nil
        self.videoInput = nil
        self.audioInput = nil
        self.adaptor = nil
        self.outputURL = nil
        state = .idle
        lock.unlock()

        guard writer.status == .completed else {
            Log.recording.error("Writer finished in state \(writer.status.rawValue): \(writer.error?.localizedDescription ?? "unknown", privacy: .public)")
            return nil
        }

        let duration = try? await AVURLAsset(url: url).load(.duration)
        let result = RecordingResult(
            url: url,
            duration: duration?.seconds ?? 0,
            framesAppended: appended,
            framesDropped: dropped
        )

        Log.recording.info(
            "Recording finished · \(String(format: "%.1f", result.duration))s, \(appended) frames, \(dropped) dropped (\(String(format: "%.3f", result.dropFraction * 100))%)"
        )
        return result
    }

    // MARK: Files

    /// The app's own media directory, kept out of Documents so it is not
    /// exposed to the Files app before the user has chosen to export.
    static var mediaDirectory: URL {
        let base = URL.applicationSupportDirectory.appending(path: "Captures", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func makeOutputURL() -> URL {
        let name = "DuoCam-\(Int(Date().timeIntervalSince1970)).mov"
        return mediaDirectory.appending(path: name)
    }

    /// Free space check before starting (Doc 3 Phase 2 task 18).
    static func availableBytes() -> Int64 {
        let values = try? mediaDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? .max
    }
}

nonisolated struct RecordingResult: Sendable {
    let url: URL
    let duration: TimeInterval
    let framesAppended: Int
    let framesDropped: Int
    /// Populated by `CleanSourceRecorder` when the setting is on.
    var cleanSourceFileNames: [StreamRole: String] = [:]

    var dropFraction: Double {
        let total = framesAppended + framesDropped
        return total == 0 ? 0 : Double(framesDropped) / Double(total)
    }
}

nonisolated enum RecordingError: LocalizedError {
    case alreadyRecording
    case inputRejected(String)
    case writerFailed(String)
    case insufficientStorage(Int64)

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: "A recording is already in progress."
        case .inputRejected(let kind): "The \(kind) track could not be created."
        case .writerFailed(let detail): "Recording could not start: \(detail)"
        case .insufficientStorage(let bytes):
            "Not enough space to record — \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) free."
        }
    }
}
