import SwiftUI

/// The design system namespace (Doc 2 §2).
///
/// Everything visual comes from here. Once Phase B lands, no raw hex value,
/// no literal font size, and no bare `UIImpactFeedbackGenerator` should appear
/// anywhere outside `DesignSystem/` — that is what keeps a camera UI from
/// drifting into five slightly different greys.
enum DC {}

// MARK: - Colour (Doc 2 §2.1)

extension DC {
    /// The app runs in permanent dark appearance. The camera feed provides all
    /// the colour there is; chrome is monochrome with a single accent.
    enum Color {
        /// `#FFD426`. Chosen over blue deliberately: it reads clearly against
        /// every camera scene and does not compete with the red record state.
        static let accent = SwiftUI.Color(hex: 0xFFD426)

        /// `#FF3B30`. Record fill and the recording indicator dot. Reserved —
        /// nothing that is not about recording may use it.
        static let record = SwiftUI.Color(hex: 0xFF3B30)

        /// Icons and primary labels.
        static let chromePrimary = SwiftUI.Color.white
        /// Inactive labels, secondary text.
        static let chromeSecondary = SwiftUI.Color.white.opacity(0.60)
        /// Disabled controls.
        static let chromeTertiary = SwiftUI.Color.white.opacity(0.35)

        /// Behind text when material is unavailable.
        static let scrim = SwiftUI.Color.black.opacity(0.40)

        /// The Reduce Transparency substitute for every material (Doc 2 §14).
        static let opaqueSurface = SwiftUI.Color(hex: 0x1C1C1E, opacity: 0.92)

        /// The 0.5pt hairline that keeps material containers from vanishing
        /// against bright scenes (Doc 2 §2.4). Critical, not decorative.
        static let hairline = SwiftUI.Color.white.opacity(0.12)

        /// Onboarding gradient stops (Doc 2 §11.1).
        static let onboardGradientStart = SwiftUI.Color(hex: 0x1E1B4B)
        static let onboardGradientEnd = SwiftUI.Color(hex: 0x7C1D6F)
        /// Primary-action gradient, shared by onboarding and the paywall.
        static let ctaGradientStart = SwiftUI.Color(hex: 0x5B5BF0)
        static let ctaGradientEnd = SwiftUI.Color(hex: 0xE0407F)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

// MARK: - Typography (Doc 2 §2.2)

extension DC {
    enum Font {
        /// Elapsed recording time. Monospaced so the readout does not shuffle
        /// sideways every time a digit changes.
        static let timerLarge = SwiftUI.Font.system(
            size: 17, weight: .semibold, design: .monospaced
        ).monospacedDigit()

        /// `4K`, `30 FPS`, `1x`.
        static let pillLabel = SwiftUI.Font.system(
            size: 13, weight: .semibold, design: .rounded
        ).monospacedDigit()

        /// The `RES` / `FPS` suffixes.
        static let pillCaption = SwiftUI.Font.system(
            size: 10, weight: .medium, design: .rounded
        )

        /// Mode selector segments.
        static let modeLabel = SwiftUI.Font.system(size: 15, weight: .semibold)

        /// Sheet headers.
        static let sheetTitle = SwiftUI.Font.system(size: 17, weight: .semibold)
        /// Sheet content.
        static let sheetBody = SwiftUI.Font.system(size: 15, weight: .regular)

        /// Onboarding headline.
        static let onboardTitle = SwiftUI.Font.system(size: 34, weight: .bold)
        /// Onboarding subtitle.
        static let onboardBody = SwiftUI.Font.system(size: 17, weight: .regular)

        /// Transient `PHOTO` / `VIDEO` label above the shutter, and the
        /// `PAUSED` / `AE/AF LOCK` labels. Letter-spaced at the call site.
        static let microLabel = SwiftUI.Font.system(size: 11, weight: .semibold)
    }
}

// MARK: - Geometry (Doc 2 §2.3)

extension DC {
    enum Radius {
        /// Overlay corners. Continuous curvature is what makes an interface
        /// read as iOS-native — never the default circular style.
        static let overlay: CGFloat = 20
        /// Sheet top corners.
        static let sheet: CGFloat = 28
        /// Gallery thumbnail.
        static let thumbnail: CGFloat = 12
        /// Layout schematic cards.
        static let card: CGFloat = 14
        /// The shutter's recording square.
        static let shutterSquare: CGFloat = 8
    }

    enum Stroke {
        /// The overlay's 3pt white border. With the ambient shadow, this is
        /// what separates a floating element from prototype problem P7's
        /// hard-cornered rectangle punched into the scene.
        static let overlay: CGFloat = 3
        static let overlayOpacity: Double = 0.9
        /// The material hairline.
        static let hairline: CGFloat = 0.5
    }

    enum Spacing {
        static let grid: CGFloat = 8
        /// Distance from any screen edge to chrome.
        static let edgeMargin: CGFloat = 20
        /// Gap between the controls in the top-right trio.
        static let controlGap: CGFloat = 12
    }

    enum Size {
        /// Minimum tap target, and the diameter of every circular control.
        static let control: CGFloat = 44
        /// Bottom-row controls (gallery, swap, layout) are slightly larger.
        static let bottomControl: CGFloat = 48
        /// Shutter outer ring.
        static let shutterOuter: CGFloat = 76
        /// Shutter inner shape at rest.
        static let shutterInner: CGFloat = 64
        /// Shutter inner shape while recording.
        static let shutterRecording: CGFloat = 32
        /// Quality pill height.
        static let pillHeight: CGFloat = 34
        /// Elapsed timer pill height.
        static let timerHeight: CGFloat = 32
        /// Mode selector height.
        static let modeSelector: CGFloat = 44
        /// Primary CTA button height (onboarding, paywall).
        static let cta: CGFloat = 56
    }

    enum Shadow {
        /// Standard floating-control shadow.
        static let controlRadius: CGFloat = 8
        static let controlY: CGFloat = 2
        static let controlOpacity: Double = 0.25

        /// The overlay at rest.
        static let overlayRadius: CGFloat = 16
        static let overlayY: CGFloat = 6
        static let overlayOpacity: Double = 0.35

        /// The overlay while being dragged — it lifts off the surface.
        static let overlayLiftedRadius: CGFloat = 24
    }
}

// MARK: - Layer stack (Doc 2 §3.1)

extension DC {
    /// Rendered back to front. Naming the z-indices keeps "nothing important is
    /// ever covered" (design principle 4) enforceable rather than aspirational.
    enum Layer {
        static let preview: Double = 0
        static let composition: Double = 10
        static let overlay: Double = 20
        static let transient: Double = 30
        static let topCluster: Double = 40
        static let bottomCluster: Double = 50
        static let sheet: Double = 60
        static let toast: Double = 70
    }
}
