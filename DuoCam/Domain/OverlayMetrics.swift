import CoreGraphics
import Foundation

/// The limits on the floating overlay's size.
///
/// Both are fractions **of the picture** — `LayoutGeometry.previewRect`, the
/// recorded frame as it appears on screen — not of the display. That is the
/// coordinate space the compositor lays the overlay out in, so a size expressed
/// this way means the same thing on a 6.9" screen, on a 4:3 frame, and in the
/// file, without a single conversion in between.
nonisolated enum OverlayMetrics {
    /// Small enough to be a corner badge…
    static let minimumWidthFraction: CGFloat = 0.15
    /// …and large enough to leave only the 16pt gutter
    /// `LayoutGeometry.overlayEdgeInset` insists on. On a 393pt frame this is
    /// 361pt wide, which is the full width less 16pt on each side — the widest
    /// the overlay can be and still be draggable at all.
    static let maximumWidthFraction: CGFloat = 0.92

    static let minimumHeightFraction: CGFloat = 0.08
    /// Deliberately short of the frame. An overlay that can be dragged out to
    /// the full height of the picture is not an overlay any more — it covers the
    /// stream it is supposed to be floating over, and there is a layout for
    /// that: Split.
    static let maximumHeightFraction: CGFloat = 0.55

    static let widthRange = minimumWidthFraction...maximumWidthFraction
    static let heightRange = minimumHeightFraction...maximumHeightFraction

    /// The size a layout installs when it is chosen, for the frame shape in use.
    ///
    /// `LayoutType.defaultOverlaySize` states each preset against a 16:9
    /// picture. A 4:3 picture is shorter for the same width, so the same height
    /// *fraction* would draw a squatter overlay; scaling by the ratio of the two
    /// picture aspects keeps the shape on screen — and in the file — identical.
    static func defaultSize(
        for layout: LayoutType,
        pictureAspect: CGFloat
    ) -> (width: CGFloat, height: CGFloat) {
        let base = layout.defaultOverlaySize
        let reference = AspectRatio.sixteenByNine.portraitAspect
        let height = base.height * pictureAspect / max(reference, 0.01)
        return (
            base.width.clamped(to: widthRange),
            height.clamped(to: heightRange)
        )
    }
}
