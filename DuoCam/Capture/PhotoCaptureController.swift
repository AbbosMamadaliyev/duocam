import AVFoundation
import CoreImage
import os
import UIKit

/// Captures a still from each stream and composites them (Doc 3 Phase 4 §Photo).
///
/// The two captures are triggered within the same run loop iteration and paired
/// by timestamp, then composited through **the same Metal layout engine** the
/// video path uses. That shared engine is the point: Doc 3's acceptance
/// criterion is that a dual-mode still matches the preview framing *exactly*,
/// and a second, parallel compositing implementation is how those two quietly
/// diverge.
final class PhotoCaptureController: NSObject, @unchecked Sendable {
    private struct PendingCapture {
        var primary: CVPixelBuffer?
        var secondary: CVPixelBuffer?
        var expectsSecondary: Bool
        var continuation: CheckedContinuation<PhotoResult, Error>?
    }

    private let lock = NSLock()
    private var pending: [Int64: PendingCapture] = [:]
    private var delegatesByID: [Int64: PhotoDelegate] = [:]

    private let compositionState: CompositionState

    init(compositionState: CompositionState) {
        self.compositionState = compositionState
    }

    /// Fires both outputs and waits for the composited result.
    func capture(
        primaryOutput: AVCapturePhotoOutput,
        secondaryOutput: AVCapturePhotoOutput?,
        settings: () -> AVCapturePhotoSettings
    ) async throws -> PhotoResult {
        let primarySettings = settings()
        let id = primarySettings.uniqueID

        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                pending[id] = PendingCapture(
                    expectsSecondary: secondaryOutput != nil,
                    continuation: continuation
                )
            }

            let primaryDelegate = PhotoDelegate(id: id, role: .primary) { [weak self] id, role, buffer in
                self?.deliver(id: id, role: role, buffer: buffer)
            }
            lock.withLock { delegatesByID[id] = primaryDelegate }
            primaryOutput.capturePhoto(with: primarySettings, delegate: primaryDelegate)

            if let secondaryOutput {
                // Same run loop iteration, so the sensors are triggered as close
                // together as the platform allows.
                let secondarySettings = AVCapturePhotoSettings(from: primarySettings)
                let secondaryDelegate = PhotoDelegate(id: id, role: .secondary) { [weak self] id, role, buffer in
                    self?.deliver(id: id, role: role, buffer: buffer)
                }
                lock.withLock { delegatesByID[secondarySettings.uniqueID] = secondaryDelegate }
                secondaryOutput.capturePhoto(with: secondarySettings, delegate: secondaryDelegate)
            }
        }
    }

    private func deliver(id: Int64, role: StreamRole, buffer: CVPixelBuffer?) {
        var finished: (PendingCapture, CVPixelBuffer, CVPixelBuffer?)?
        var failure: PendingCapture?

        lock.withLock {
            guard var capture = pending[id] else { return }

            // A nil buffer on the *primary* is unrecoverable, and leaving the
            // continuation un-resumed would hang the caller forever rather than
            // surfacing anything. A nil secondary just means no overlay.
            if role == .primary, buffer == nil {
                pending[id] = nil
                delegatesByID[id] = nil
                failure = capture
                return
            }

            switch role {
            case .primary: capture.primary = buffer
            case .secondary: capture.secondary = buffer
            }
            pending[id] = capture

            guard let primary = capture.primary else { return }
            // A secondary that came back empty must not stall the capture.
            if capture.expectsSecondary, capture.secondary == nil, role != .secondary { return }

            pending[id] = nil
            delegatesByID[id] = nil
            finished = (capture, primary, capture.secondary)
        }

        if let failure {
            failure.continuation?.resume(throwing: PhotoError.noPixelBuffer)
            return
        }

        guard let (capture, primary, secondary) = finished,
              let continuation = capture.continuation
        else { return }

        let (uniforms, outputSize, compositor) = compositionState.snapshot()
        guard let compositor,
              let composited = compositor.composite(
                  primary: primary,
                  secondary: secondary,
                  uniforms: uniforms,
                  outputSize: outputSize
              )
        else {
            continuation.resume(throwing: PhotoError.compositingFailed)
            return
        }

        guard let data = Self.jpegData(from: composited) else {
            continuation.resume(throwing: PhotoError.encodingFailed)
            return
        }

        continuation.resume(returning: PhotoResult(
            jpegData: data,
            width: CVPixelBufferGetWidth(composited),
            height: CVPixelBufferGetHeight(composited)
        ))
    }

    private static func jpegData(from buffer: CVPixelBuffer) -> Data? {
        let image = CIImage(cvPixelBuffer: buffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.92)
    }
}

/// One output's delegate. `AVCapturePhotoOutput` holds these weakly, so the
/// controller keeps them alive until the capture completes.
private final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let id: Int64
    private let role: StreamRole
    private let completion: (Int64, StreamRole, CVPixelBuffer?) -> Void

    init(
        id: Int64,
        role: StreamRole,
        completion: @escaping (Int64, StreamRole, CVPixelBuffer?) -> Void
    ) {
        self.id = id
        self.role = role
        self.completion = completion
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            Log.capture.error("Photo capture failed: \(error.localizedDescription, privacy: .public)")
        }
        completion(id, role, photo.pixelBuffer)
    }
}

nonisolated struct PhotoResult: Sendable {
    let jpegData: Data
    let width: Int
    let height: Int
}

nonisolated enum PhotoError: LocalizedError {
    case noOutput
    case noPixelBuffer
    case compositingFailed
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .noOutput: "Photo capture isn't available in this mode."
        case .noPixelBuffer: "The camera returned no image data."
        case .compositingFailed: "The photo couldn't be composed."
        case .encodingFailed: "The photo couldn't be encoded."
        }
    }
}
