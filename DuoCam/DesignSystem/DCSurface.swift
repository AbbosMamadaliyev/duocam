import SwiftUI

/// The material treatment every floating control shares (Doc 2 §2.4).
///
/// ```swift
/// .background(.ultraThinMaterial, in: Capsule())
/// .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
/// .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
/// ```
///
/// The 0.5pt hairline is the part that is easy to skip and must not be:
/// without it, material containers disappear entirely against a bright camera
/// scene, and design principle 1 — *the preview is the interface* — collapses
/// into unreadable chrome.
///
/// Under Reduce Transparency the material is replaced by solid `#1C1C1E` at 92%
/// (Doc 2 §14), which keeps contrast while dropping the blur.
private struct SurfaceModifier<S: InsettableShape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let shape: S
    let elevated: Bool
    let shadowRadius: CGFloat
    let shadowY: CGFloat

    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency {
                    shape.fill(DC.Color.opaqueSurface)
                } else if elevated {
                    shape.fill(.regularMaterial)
                } else {
                    shape.fill(.ultraThinMaterial)
                }
            }
            .overlay {
                shape.strokeBorder(DC.Color.hairline, lineWidth: DC.Stroke.hairline)
            }
            .shadow(
                color: .black.opacity(DC.Shadow.controlOpacity),
                radius: shadowRadius,
                y: shadowY
            )
    }
}

extension View {
    /// `surface` — control containers, pills, sheets.
    func dcSurface<S: InsettableShape>(
        in shape: S,
        shadowRadius: CGFloat = DC.Shadow.controlRadius,
        shadowY: CGFloat = DC.Shadow.controlY
    ) -> some View {
        modifier(SurfaceModifier(
            shape: shape, elevated: false,
            shadowRadius: shadowRadius, shadowY: shadowY
        ))
    }

    /// `surfaceElevated` — modal sheets, settings panels.
    func dcSurfaceElevated<S: InsettableShape>(
        in shape: S,
        shadowRadius: CGFloat = DC.Shadow.controlRadius,
        shadowY: CGFloat = DC.Shadow.controlY
    ) -> some View {
        modifier(SurfaceModifier(
            shape: shape, elevated: true,
            shadowRadius: shadowRadius, shadowY: shadowY
        ))
    }
}

// MARK: - Continuous corners

extension RoundedRectangle {
    /// Doc 2 §2.3: *"Never use the default circular style — continuous
    /// curvature is what makes an interface read as iOS-native."*
    static func dc(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}

// MARK: - Full-bleed scrims (Doc 2 §3.2)

/// The only darkening the preview ever receives.
///
/// Legibility over bright scenes is achieved by material on the *controls*, not
/// by dimming the image — this is the correction to prototype problem P5, where
/// opaque black bars consumed roughly a quarter of the screen. These two narrow
/// gradients are invisible on most scenes but guarantee icon contrast against a
/// white sky or a snow field.
struct ChromeScrims: View {
    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [.black.opacity(0.25), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 120)

            Spacer(minLength: 0)

            LinearGradient(
                colors: [.clear, .black.opacity(0.35)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 180)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
