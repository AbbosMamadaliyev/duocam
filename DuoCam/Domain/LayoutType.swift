import CoreGraphics
import Foundation

/// How the two streams are arranged on screen (Doc 1 §3.3).
///
/// The layout is a *presentation* concern: in the Metal compositor it is passed
/// as a uniform struct, which is what lets it change mid-recording with no
/// session reconfiguration (Doc 3 Phase 4 task 13).
nonisolated enum LayoutType: String, CaseIterable, Identifiable, Codable, Sendable {
    case pipRounded
    case pipTall
    case pipCircle
    case splitHorizontal
    case splitDiagonal

    var id: String { rawValue }

    /// Caption under the schematic card in the layout sheet (Doc 2 §6.3).
    var caption: String {
        switch self {
        case .pipRounded: "PiP"
        case .pipTall: "Tall"
        case .pipCircle: "Circle"
        case .splitHorizontal: "Split"
        case .splitDiagonal: "Diagonal"
        }
    }

    var isPiP: Bool {
        switch self {
        case .pipRounded, .pipTall, .pipCircle: true
        case .splitHorizontal, .splitDiagonal: false
        }
    }

    var isSplit: Bool { !isPiP }

    /// Width-to-height ratio of the floating overlay (Doc 2 §5.1).
    /// Meaningless for split layouts, which use a divider instead.
    var overlayAspectRatio: CGFloat {
        switch self {
        case .pipRounded: 3.0 / 4.0
        case .pipTall: 9.0 / 16.0
        case .pipCircle: 1.0
        case .splitHorizontal, .splitDiagonal: 3.0 / 4.0
        }
    }

    /// `pipCircle` clips to a `Circle`; the rest use a continuous rounded rect.
    var overlayIsCircular: Bool { self == .pipCircle }
}
