import SwiftUI

/// The floating overlay's outline — a continuous rounded rectangle, or a circle
/// when the layout asks for one.
///
/// `InsettableShape` rather than a bare `Shape`, and that is the point of the
/// type. The compositor draws the border in the band *just inside* the overlay's
/// boundary; SwiftUI's `stroke` straddles the path, half in and half out. At the
/// 3pt border the app shipped with, the two disagreed by 1.5pt and nobody
/// noticed. With the border under the user's control the disagreement becomes
/// visible — and it grows in the direction that matters, because a stroke drawn
/// half outside the clip is a stroke the recording does not contain.
/// `strokeBorder`, which needs this conformance, insets instead.
struct OverlayShape: InsettableShape {
    var cornerRadius: CGFloat
    var isCircular: Bool
    private var insetAmount: CGFloat = 0

    init(cornerRadius: CGFloat, isCircular: Bool) {
        self.cornerRadius = cornerRadius
        self.isCircular = isCircular
    }

    func path(in rect: CGRect) -> Path {
        let inner = rect.insetBy(dx: insetAmount, dy: insetAmount)
        // `Ellipse`, not `Circle`: the width and height are independent
        // parameters now, and `Circle` inscribes in the shorter axis rather than
        // filling the box — which would leave the stroke and the clipped video
        // disagreeing about where the edge is the moment the two differ. At
        // equal width and height an ellipse *is* a circle, so the Circle layout
        // is unchanged until the user changes it.
        guard !isCircular else { return Ellipse().path(in: inner) }
        // The radius shrinks with the inset so concentric outlines stay
        // concentric — a fixed radius on an inset rect bulges at the corners.
        return RoundedRectangle
            .dc(max(cornerRadius - insetAmount, 0))
            .path(in: inner)
    }

    func inset(by amount: CGFloat) -> OverlayShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

extension OverlayBorderStyle {
    /// The border's colour for SwiftUI, opacity included.
    var swiftUIColor: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }

    /// The same colour at full opacity — what a swatch shows, so a nearly
    /// transparent border still reads as the colour it is.
    var opaqueSwiftUIColor: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }

    /// Takes the components back out of a `Color`, which is the only way a
    /// system `ColorPicker` can hand them over.
    ///
    /// Resolved through `UIColor` rather than trusted blindly: a `Color` from
    /// the picker may be in any colour space, and reading it as sRGB is what
    /// keeps the preview's border and the recorded one the same colour.
    mutating func apply(_ color: Color) {
        let resolved = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard resolved.getRed(&r, green: &g, blue: &b, alpha: &a) else { return }
        setColor(red: Double(r), green: Double(g), blue: Double(b), opacity: Double(a))
    }
}
