import AVFoundation
import Foundation

/// A physical lens that can feed a stream.
///
/// Doc 1 §5.3.5: virtual devices (`.builtInDualCamera`, `.builtInTripleCamera`)
/// are generally unavailable in multi-cam, so every source here maps to a
/// discrete physical device. Lens transitions are the app's job, not the
/// system's.
nonisolated enum CameraSource: String, CaseIterable, Identifiable, Codable, Sendable {
    case front
    case rearUltraWide
    case rearWide
    case rearTelephoto

    var id: String { rawValue }

    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .front: .builtInTrueDepthCamera
        // Note: Doc 1 §5.3.5 writes `.builtInUltraWideAngleCamera`; the actual
        // AVFoundation symbol is `.builtInUltraWideCamera`.
        case .rearUltraWide: .builtInUltraWideCamera
        case .rearWide: .builtInWideAngleCamera
        case .rearTelephoto: .builtInTelephotoCamera
        }
    }

    var position: AVCaptureDevice.Position {
        self == .front ? .front : .back
    }

    var displayName: String {
        switch self {
        case .front: "Front"
        case .rearUltraWide: "Ultra Wide"
        case .rearWide: "Wide"
        case .rearTelephoto: "Telephoto"
        }
    }

    /// Label for the zoom pill group (Doc 2 §4.3). These are the nominal stops;
    /// the genuinely available set is probed per device at runtime.
    var zoomLabel: String {
        switch self {
        case .front: "1x"
        case .rearUltraWide: "0.5x"
        case .rearWide: "1x"
        case .rearTelephoto: "3x"
        }
    }

    /// Front capture is mirrored so the preview matches what a mirror would show
    /// (Doc 3 Phase 1 task 7). Rear capture never is.
    var prefersMirroring: Bool { self == .front }
}
