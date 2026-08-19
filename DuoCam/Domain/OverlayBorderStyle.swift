import CoreGraphics
import Foundation

/// The floating overlay's border — corner radius, thickness, colour.
///
/// A *composition* value rather than a design token, because the border is
/// drawn twice: once by SwiftUI in `FloatingOverlayView` and once by the
/// fragment shader into the recorded frame. Both read this, which is the same
/// rule `LayoutGeometry` follows for the overlay's position — Doc 3 Phase 2's
/// first acceptance criterion is that the file matches what the user saw, and
/// two independently-configured borders is exactly how that stops being true.
///
/// The colour is stored as components rather than as a `SwiftUI.Color` so the
/// type stays `Codable`, `Sendable` and free of any UI framework: it travels
/// into the capture layer, where SwiftUI does not exist.
nonisolated struct OverlayBorderStyle: Equatable, Codable, Sendable {
    /// 0…`maximumCornerRadius`, in points of the *preview*. The compositor
    /// rescales it to the output resolution so a 4K file gets the same visual
    /// corner as the screen.
    var cornerRadius: CGFloat
    /// 0…`maximumWidth`, in preview points. Zero means no border at all, which
    /// is a legitimate look rather than a broken one.
    var width: CGFloat

    var red: Double
    var green: Double
    var blue: Double
    /// Folded into the stroke's alpha in both renderers.
    var opacity: Double

    /// The ceilings are the shipped defaults: the sliders run from "off" up to
    /// the border the app has always drawn, so every reachable value is one the
    /// design system already sanctions.
    static let maximumCornerRadius: CGFloat = DC.Radius.overlay
    static let maximumWidth: CGFloat = DC.Stroke.overlay

    static let `default` = OverlayBorderStyle(
        cornerRadius: DC.Radius.overlay,
        width: DC.Stroke.overlay,
        red: 1,
        green: 1,
        blue: 1,
        opacity: DC.Stroke.overlayOpacity
    )

    /// Clamps into the ranges the sliders offer.
    ///
    /// Applied on the way *in* from persistence as well as from the UI: a
    /// stored value from a build with different ceilings must not resurrect a
    /// border the current sliders cannot express or undo.
    var sanitized: OverlayBorderStyle {
        OverlayBorderStyle(
            cornerRadius: cornerRadius.clamped(to: 0...Self.maximumCornerRadius),
            width: width.clamped(to: 0...Self.maximumWidth),
            red: red.clamped(to: 0...1),
            green: green.clamped(to: 0...1),
            blue: blue.clamped(to: 0...1),
            opacity: opacity.clamped(to: 0...1)
        )
    }

    /// Replaces the colour, leaving the geometry alone.
    mutating func setColor(red: Double, green: Double, blue: Double, opacity: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.opacity = opacity
    }

    /// Whether two styles paint the same colour, ignoring radius and width —
    /// what the swatch row needs to mark one of its presets as chosen.
    func matchesColor(red: Double, green: Double, blue: Double) -> Bool {
        let tolerance = 0.01
        return abs(self.red - red) < tolerance
            && abs(self.green - green) < tolerance
            && abs(self.blue - blue) < tolerance
    }
}
