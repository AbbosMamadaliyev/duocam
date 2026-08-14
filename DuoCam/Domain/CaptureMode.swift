import Foundation

/// How many streams are captured, and which physical cameras feed them.
///
/// Doc 1 §3.2 replaces the prototype's conflated "Dual / Single / Front-Back"
/// naming (problem P6) with an explicit two-axis model. This type is **Axis A**:
/// the stream count and the default source pairing. Which lens actually feeds
/// each stream is `CameraSource`, and how the streams are arranged on screen is
/// `LayoutType`. Keeping the three apart is the whole point of the correction —
/// a mode button must never silently change the layout.
nonisolated enum CaptureMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case dualFrontBack
    case dualRear
    case single

    var id: String { rawValue }

    /// User-facing name shown in the mode selector (Doc 2 §4.3).
    var displayName: String {
        switch self {
        case .dualFrontBack: "Front + Back"
        case .dualRear: "Rear + Rear"
        case .single: "Single"
        }
    }

    var streamCount: Int {
        self == .single ? 1 : 2
    }

    var isDual: Bool { streamCount == 2 }

    /// The default lens for each role when entering this mode.
    var defaultSources: (primary: CameraSource, secondary: CameraSource?) {
        switch self {
        case .dualFrontBack: (.rearWide, .front)
        case .dualRear: (.rearWide, .rearUltraWide)
        case .single: (.rearWide, nil)
        }
    }

    /// Single mode runs on a standard `AVCaptureSession` rather than a multi-cam
    /// one. Doc 1 §5.3.7: Night Mode, Deep Fusion, ProRAW, Photographic Styles
    /// and Cinematic Mode are all unavailable in multi-cam, so the only way to
    /// offer them is a separate code path.
    var usesMultiCamSession: Bool { isDual }
}
