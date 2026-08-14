import AVFoundation
import CoreMedia
import os

/// Writes each stream's untouched footage alongside the composited file.
///
/// Doc 1 §2.3 lists independent dual-file export as the product's second
/// differentiator: one composited file plus two clean sources, so a creator can
/// re-edit the composition later instead of being locked into the framing they
/// chose while filming.
///
/// Sample buffers are appended **directly** rather than round-tripped through
/// the compositor. That is what makes them frame-accurate to the composited
/// file — they are literally the same frames — and it keeps the clean path off
/// the GPU entirely, so Doc 3 Phase 4 task 22's requirement that three
/// concurrent writers stay inside the thermal budget has a chance.
final class CleanSourceRecorder: @unchecked Sendable {
    private struct Writer {
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let url: URL
        var started = false
    }

    private let lock = NSLock()
    private var writers: [StreamRole: Writer] = [:]
    private(set) var isRecording = false

    /// Starts one writer per role.
    ///
    /// Failures here are *not* fatal: Doc 3 Phase 4 task 22 says to degrade the
    /// clean sources first and never the composited output, so a clean writer
    /// that cannot start is simply absent from the result.
    func start(
        roles: [StreamRole: (size: CGSize, rotationDegrees: Double)],
        quality: QualityProfile
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard writers.isEmpty else { return }

        for (role, spec) in roles {
            let name = "DuoCam-\(Int(Date().timeIntervalSince1970))-\(role.rawValue).mov"
            let url = RecordingController.mediaDirectory.appending(path: name)

            do {
                let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
                let settings: [String: Any] = [
                    AVVideoCodecKey: quality.codec.avCodecType,
                    AVVideoWidthKey: Int(spec.size.width),
                    AVVideoHeightKey: Int(spec.size.height),
                    AVVideoCompressionPropertiesKey: [
                        AVVideoAverageBitRateKey: quality.resolution.targetBitrate,
                        AVVideoExpectedSourceFrameRateKey: quality.frameRate.rawValue,
                    ],
                ]
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
                input.expectsMediaDataInRealTime = true
                // The buffers are in sensor orientation; a transform on the
                // track keeps the file upright without re-encoding a rotation.
                input.transform = CGAffineTransform(rotationAngle: spec.rotationDegrees * .pi / 180)

                // Inputs must be added *before* `startWriting()`. Calling it
                // first moves the writer to `.writing`, and `addInput` then
                // raises `NSInternalInconsistencyException` — a hard crash, not
                // an error return.
                guard writer.canAdd(input) else {
                    Log.recording.error("Clean writer for \(role.rawValue, privacy: .public) rejected its input")
                    continue
                }
                writer.add(input)

                guard writer.startWriting() else {
                    Log.recording.error("Clean writer for \(role.rawValue, privacy: .public) refused to start")
                    continue
                }
                writers[role] = Writer(writer: writer, input: input, url: url)
            } catch {
                Log.recording.error("Clean writer failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        isRecording = !writers.isEmpty
        if isRecording {
            Log.recording.info("Clean sources recording: \(self.writers.keys.map(\.rawValue).joined(separator: ", "), privacy: .public)")
        }
    }

    func append(_ sampleBuffer: CMSampleBuffer, for role: StreamRole) {
        // The lock is held only long enough to read this role's writer. Holding
        // it across `append` would serialise the primary and secondary capture
        // queues against each other for the duration of an encode — two
        // independent writers, one shared bottleneck.
        lock.lock()
        guard isRecording, var entry = writers[role], entry.writer.status == .writing else {
            lock.unlock()
            return
        }
        let needsSessionStart = !entry.started
        if needsSessionStart {
            entry.started = true
            writers[role] = entry
        }
        let writer = entry.writer
        let input = entry.input
        lock.unlock()

        if needsSessionStart {
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        }
        guard input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }

    /// Finalises and returns the file names, keyed by role.
    func finish() async -> [StreamRole: String] {
        lock.lock()
        let current = writers
        writers.removeAll()
        isRecording = false
        lock.unlock()

        guard !current.isEmpty else { return [:] }

        var result: [StreamRole: String] = [:]
        for (role, entry) in current {
            entry.input.markAsFinished()
            await entry.writer.finishWriting()
            if entry.writer.status == .completed {
                result[role] = entry.url.lastPathComponent
            } else {
                try? FileManager.default.removeItem(at: entry.url)
                Log.recording.error("Clean source \(role.rawValue, privacy: .public) did not finalise")
            }
        }
        return result
    }

    /// Called when the governor needs headroom. Doc 3 Phase 4 task 22: clean
    /// sources are the first thing to go, never the composited output.
    func abandon() {
        lock.lock()
        let current = writers
        writers.removeAll()
        isRecording = false
        lock.unlock()

        for (_, entry) in current {
            entry.writer.cancelWriting()
            try? FileManager.default.removeItem(at: entry.url)
        }
        Log.recording.notice("Clean sources abandoned to protect the composited recording")
    }
}
