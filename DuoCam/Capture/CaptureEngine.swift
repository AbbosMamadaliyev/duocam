import AVFoundation
import QuartzCore

/// What the capture layer is currently doing.
nonisolated enum CaptureEngineStatus: Equatable, Sendable {
    case idle
    case configuring
    case running
    /// The session was taken by a phone call or another app. Doc 2 §13: the
    /// preview shows a blurred freeze frame and auto-resumes on return.
    case interrupted(reason: String)
    case failed(message: String)

    var isRunning: Bool { self == .running }
}

/// Something the capture layer needs the UI to know about.
///
/// Delivered as a stream rather than through a delegate so the view model can
/// consume it with a single `for await` in one `Task`, instead of scattering
/// callback plumbing across the presentation layer.
nonisolated enum CaptureEngineEvent: Sendable {
    case statusChanged(CaptureEngineStatus)
    /// The hardware granted something other than what was asked for. Drives the
    /// quality pill and, once, a toast.
    case qualityNegotiated(NegotiatedQuality)
    /// A degradation step was applied. Doc 2 §13.
    case degraded(DegradationReason)
    case thermalStateChanged(ProcessInfo.ThermalState)
    /// Recoverable failure — the UI explains it and carries on in a lesser mode.
    case recoverableFailure(String)
}

/// A layer that renders one live stream.
///
/// Camera output is a `CALayer` and cannot travel through SwiftUI's own
/// rendering path (Doc 2 §15.1), so the engine vends layers and
/// `CameraPreviewView` hosts them. Boxing the layer keeps the protocol free of
/// AVFoundation types, which is what lets `SimulatedCaptureEngine` exist at all.
@MainActor
final class PreviewSource {
    let layer: CALayer

    init(layer: CALayer) {
        self.layer = layer
    }
}

/// The seam between the app and the camera.
///
/// Everything above this protocol — geometry, chrome, gestures, layout — is
/// engine-agnostic, which is what makes the entire interface verifiable in the
/// simulator where `AVCaptureMultiCamSession` cannot run at all. See
/// `00_BUILD_PLAN.md` deviation D-1.
@MainActor
protocol CaptureEngine: AnyObject {
    var status: CaptureEngineStatus { get }
    var negotiatedQuality: NegotiatedQuality { get }
    var configuration: CaptureConfiguration { get }

    /// Consumed once, by the view model.
    var events: AsyncStream<CaptureEngineEvent> { get }

    func start() async
    func stop() async

    /// Applies a new configuration, reconfiguring the session only if the diff
    /// requires it (`CaptureConfiguration.requiresSessionReconfiguration`).
    func apply(_ configuration: CaptureConfiguration) async

    /// The layer for a stream, or `nil` when the current mode has no such
    /// stream (Single mode has no secondary).
    func previewSource(for role: StreamRole) -> PreviewSource?

    /// Point is in normalised device coordinates (0…1, origin top-left).
    func focusAndExpose(at point: CGPoint, in role: StreamRole)
    func lockFocusAndExposure(at point: CGPoint, in role: StreamRole)
    func resetFocusAndExposure(in role: StreamRole)

    func setZoomFactor(_ factor: CGFloat, for role: StreamRole, ramped: Bool)
    func setExposureBias(_ bias: Float, for role: StreamRole)

    /// The zoom stops genuinely available for a stream's current lens.
    func availableZoomStops(for role: StreamRole) -> [ZoomStop]

    // MARK: Recording

    var recordingState: RecordingController.State { get }

    /// Fraction of primary frames that found no secondary partner. Doc 3 Phase
    /// 2 task 2's skew tolerance is only verifiable if this is observable.
    var unpairedFrameFraction: Double { get }

    /// The composition parameters the engine should render with.
    ///
    /// Pushed from the view model rather than pulled, because the overlay's
    /// position lives in `LayoutGeometry` on the UI side and Doc 3 Phase 2's
    /// first acceptance criterion is that the recorded file matches the
    /// on-screen preview *exactly*. Duplicating the geometry maths in the
    /// capture layer is how those two drift apart.
    func updateComposition(_ parameters: CompositionParameters)

    /// Captures a still. In a dual mode this is the composited frame; Doc 1
    /// §3.4 makes clean per-stream stills an optional extra, added in Phase F's
    /// clean-source work.
    func capturePhoto() async throws -> PhotoResult

    /// Manual controls, applied per stream (Doc 2 §6.2).
    func setManualControl(_ control: ManualControl, for role: StreamRole)

    /// Whether the primary stream's device has a torch that can be lit right
    /// now (Doc 2 §4.2 — rear-primary only).
    ///
    /// Exposed so the UI can refuse *out loud*. `setTorch` returns nothing and
    /// silently no-ops on a front-facing device, which left the torch control
    /// looking live while doing nothing at all.
    var isTorchAvailable: Bool { get }

    /// Torch, rear-primary only (Doc 2 §4.2).
    func setTorch(enabled: Bool, level: Float)

    /// Switches which lens feeds a stream without disturbing the other one
    /// (Doc 3 Phase 4 task 14).
    func setSource(_ source: CameraSource, for role: StreamRole) async

    func startRecording() async throws -> URL
    func stopRecording() async -> RecordingResult?
    func pauseRecording()
    func resumeRecording()
}

/// What the compositor needs from the presentation layer each time the layout,
/// the overlay position, or the split changes.
nonisolated struct CompositionParameters: Equatable, Sendable {
    var layout: LayoutType = .pipRounded
    /// Overlay centre in normalised output coordinates (0…1, origin top-left).
    var overlayCentre: CGPoint = CGPoint(x: 0.8, y: 0.2)
    var overlayWidthFraction: CGFloat = 0.32
    /// Fraction of the output's *height*, independent of the width.
    var overlayHeightFraction: CGFloat = 0.24
    var splitRatio: CGFloat = 0.5
    var diagonalAngle: Double = 0
    /// The overlay's border, as the user set it. Travels with the rest of the
    /// composition so the recorded frame carries the same border the preview
    /// drew, rather than the design system's default.
    var border: OverlayBorderStyle = .default
}

/// One manual adjustment, targeted at a stream.
///
/// A single enum rather than five setters so the Adjustments sheet can hand the
/// engine "whatever changed" without the protocol growing a method per control.
nonisolated enum ManualControl: Equatable, Sendable {
    case exposureBias(Float)
    case iso(Float?)          // nil restores automatic
    case shutterSpeed(Double?)
    case whiteBalance(Float?) // Kelvin
    case focus(Float?)        // 0…1 lens position
    case resetAll
}

/// A discrete lens stop offered by the zoom pill group.
nonisolated struct ZoomStop: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let zoomFactor: CGFloat
    let source: CameraSource?

    init(label: String, zoomFactor: CGFloat, source: CameraSource? = nil) {
        self.id = label
        self.label = label
        self.zoomFactor = zoomFactor
        self.source = source
    }
}

// MARK: - Failure

nonisolated enum CaptureError: LocalizedError, Sendable {
    case multiCamUnsupported
    case deviceUnavailable(CameraSource)
    case noMultiCamFormat(CameraSource)
    case connectionRejected(String)
    case hardwareCostExceeded(Float)
    case configurationFailed(String)

    var errorDescription: String? {
        switch self {
        case .multiCamUnsupported:
            "This device can't record from two cameras at once."
        case .deviceUnavailable(let source):
            "The \(source.displayName) camera isn't available."
        case .noMultiCamFormat(let source):
            "The \(source.displayName) camera has no format usable in a two-camera session."
        case .connectionRejected(let detail):
            "The camera connection was rejected: \(detail)"
        case .hardwareCostExceeded(let cost):
            "This camera pairing exceeds what the hardware allows (cost \(String(format: "%.2f", cost)))."
        case .configurationFailed(let detail):
            "Camera setup failed: \(detail)"
        }
    }
}
