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
    case pipWide
    case pipCircle
    case splitHorizontal
    case splitDiagonal

    var id: String { rawValue }

    /// Caption under the schematic card in the layout sheet (Doc 2 §6.3).
    var caption: String {
        switch self {
        case .pipRounded: "PiP"
        case .pipTall: "Tall"
        case .pipWide: "Wide"
        case .pipCircle: "Circle"
        case .splitHorizontal: "Split"
        case .splitDiagonal: "Diagonal"
        }
    }

    var isPiP: Bool {
        switch self {
        case .pipRounded, .pipTall, .pipWide, .pipCircle: true
        case .splitHorizontal, .splitDiagonal: false
        }
    }

    var isSplit: Bool { !isPiP }

    /// The overlay size this layout installs when it is chosen, as fractions of
    /// a **16:9** picture — width of the picture's width, height of its height.
    ///
    /// The single source of truth for what a layout card *means*: choosing one
    /// sets both fractions from here, and the PiP Parameter sliders start from
    /// them. `OverlayMetrics.defaultSize(for:pictureAspect:)` converts them for
    /// a 4:3 frame, preserving the shape on screen rather than the raw numbers.
    ///
    /// `pipWide` is the one landscape option: every other PiP shape is taller
    /// than it is wide, which is right for a phone held upright but wrong for
    /// framing anything horizontal in the overlay — a second person, a room, a
    /// screen being filmed.
    ///
    /// Wide and Circle are deliberately much larger than the 32% the tall
    /// shapes use. A 16:9 box at 32% of the width is only a tenth of the frame
    /// tall, and a circle inside a 32% box is a badge rather than a subject —
    /// both were too small to be worth choosing.
    var defaultOverlaySize: (width: CGFloat, height: CGFloat) {
        switch self {
        case .pipRounded: (0.32, 0.24)
        case .pipTall: (0.32, 0.32)
        case .pipWide: (0.60, 0.30)
        case .pipCircle: (0.50, 0.28125)
        case .splitHorizontal, .splitDiagonal: (0.32, 0.24)
        }
    }

    /// Width-to-height ratio of the overlay *in pixels*, at this layout's own
    /// default size (Doc 2 §5.1). Meaningless for split layouts, which use a
    /// divider instead.
    ///
    /// Derived rather than declared, so the schematic on the layout card can
    /// never promise a shape the card does not actually produce. A fraction of
    /// the width and a fraction of the height are fractions of two different
    /// lengths, which is where the picture's own aspect comes in.
    ///
    /// Note that `pipWide` works out at 1.125 : 1, not 16:9 — its default is a
    /// deliberate width/height pair rather than a ratio.
    var overlayAspectRatio: CGFloat {
        let size = defaultOverlaySize
        guard size.height > 0 else { return 1 }
        return size.width * AspectRatio.sixteenByNine.portraitAspect / size.height
    }

    /// `pipCircle` clips to a `Circle`; the rest use a continuous rounded rect.
    var overlayIsCircular: Bool { self == .pipCircle }
}
