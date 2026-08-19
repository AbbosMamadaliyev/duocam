import CoreGraphics
import CoreMedia
import Foundation

/// The shape of the recorded frame — and therefore of the preview.
///
/// One value drives both. The composited canvas is built from
/// `outputSize(for:)` and the on-screen picture is confined to a rect of the
/// same proportion (`LayoutGeometry.previewRect`), so what the user frames is
/// what the file contains. A preview stretched to fill a 19.5:9 display while
/// the file is written at 16:9 is not a cosmetic mismatch: the recording holds
/// picture at the sides that the preview cropped away, and the user never saw
/// what they were shooting.
nonisolated enum AspectRatio: String, CaseIterable, Identifiable, Codable, Sendable {
    case sixteenByNine
    case fourByThree

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sixteenByNine: "16:9"
        case .fourByThree: "4:3"
        }
    }

    /// Long side ÷ short side.
    var ratio: CGFloat {
        switch self {
        case .sixteenByNine: 16.0 / 9
        case .fourByThree: 4.0 / 3
        }
    }

    /// Width ÷ height of the portrait frame this app records.
    var portraitAspect: CGFloat { 1 / ratio }

    /// The composited canvas for a resolution tier, in portrait.
    ///
    /// The tier's *short* side is the anchor, because that is the dimension the
    /// sensor formats are defined by: 1080p is 1080 lines whether the frame is
    /// 16:9 or 4:3. Anchoring on the long side instead would make "1080p at
    /// 4:3" a 1440-line capture, which the negotiated format cannot supply and
    /// the pill would still call 1080p.
    ///
    /// Rounded to an even number of pixels — HEVC and H.264 both encode in
    /// macroblocks and reject odd dimensions. Every tier here already lands
    /// even; the rounding is what keeps that true for a tier added later.
    func outputSize(for resolution: Resolution) -> CGSize {
        let shortSide = CGFloat(resolution.dimensions.height)
        let longSide = (shortSide * ratio / 2).rounded() * 2
        return CGSize(width: shortSide, height: longSide)
    }

    var toggled: AspectRatio {
        self == .sixteenByNine ? .fourByThree : .sixteenByNine
    }
}
