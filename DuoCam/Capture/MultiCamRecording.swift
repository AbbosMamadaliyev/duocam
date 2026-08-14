import AVFoundation
import CoreMedia
import os

/// The sample-buffer side of `MultiCamCaptureEngine`.
///
/// Split into its own file because it lives on a different thread from
/// everything else in the engine: the delegate callbacks arrive on dedicated
/// serial queues (Doc 3 cross-phase rule: *"sample buffer delegates run on
/// their own serial queues, never shared"*), and nothing here may touch
/// main-actor state.
final class StreamOutputHandler: NSObject, @unchecked Sendable {
    let role: StreamRole
    /// The whole sample buffer is passed on, not just its pixels: the clean
    /// source writers append it verbatim, and re-wrapping a pixel buffer would
    /// lose the timing information that keeps them frame-accurate to the
    /// composited file.
    private let onFrame: @Sendable (StreamRole, CMSampleBuffer, CVPixelBuffer, CMTime) -> Void

    init(
        role: StreamRole,
        onFrame: @escaping @Sendable (StreamRole, CMSampleBuffer, CVPixelBuffer, CMTime) -> Void
    ) {
        self.role = role
        self.onFrame = onFrame
    }
}

extension StreamOutputHandler: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame(role, sampleBuffer, pixels, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        Log.composition.debug("Dropped \(self.role.rawValue, privacy: .public) frame")
    }
}

/// Audio delegate. Doc 1 §5.3.6: **one** audio input per session, even with two
/// video streams — directional capture is an `AVAudioSession` data-source
/// choice, not a second input.
final class AudioOutputHandler: NSObject, @unchecked Sendable {
    private let onSample: @Sendable (CMSampleBuffer) -> Void

    init(onSample: @escaping @Sendable (CMSampleBuffer) -> Void) {
        self.onSample = onSample
    }
}

extension AudioOutputHandler: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        onSample(sampleBuffer)
    }
}

// MARK: - Audio session

enum AudioSessionConfigurator {
    /// Doc 3 Phase 2 task 10.
    static func configureForRecording() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .videoRecording,
                options: [.allowBluetooth, .defaultToSpeaker, .mixWithOthers]
            )
            try session.setActive(true)
            Log.recording.info("Audio session configured for video recording")
        } catch {
            Log.recording.error("Audio session setup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Doc 3 Phase 2 task 11: directional capture through data sources,
    /// defaulting to whichever side the primary camera is on.
    static func selectDataSource(matching position: AVCaptureDevice.Position) {
        let session = AVAudioSession.sharedInstance()
        guard let input = session.availableInputs?.first(where: { $0.portType == .builtInMic }),
              let sources = input.dataSources
        else { return }

        let orientation: AVAudioSession.Orientation = position == .front ? .front : .back
        guard let match = sources.first(where: { $0.orientation == orientation }) else { return }

        do {
            try input.setPreferredDataSource(match)
            try session.setPreferredInput(input)
            Log.recording.info("Microphone data source → \(match.dataSourceName, privacy: .public)")
        } catch {
            Log.recording.error("Data source selection failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
