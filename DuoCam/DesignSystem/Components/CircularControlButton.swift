import SwiftUI

/// A circular, translucent control that floats directly over the live preview.
///
/// Doc 1 §2.1 identifies this as a baseline competitor pattern worth adopting:
/// circular blurred containers over the preview rather than icons in an opaque
/// bar. It preserves preview area and reads as native iOS.
struct CircularControlButton: View {
    let systemImage: String
    var size: CGFloat = DC.Size.control
    /// Active controls tint accent and switch to palette rendering.
    var isActive: Bool = false
    var isEnabled: Bool = true

    var accessibilityLabel: String
    var accessibilityValue: String?
    var accessibilityHint: String?

    var action: () -> Void = {}

    /// Exactly the shape `QualityPill` and the gallery control have: a `Button`
    /// with `.buttonStyle(.plain)` and nothing layered on top of it.
    ///
    /// Every earlier version of this control added something to that shape, and
    /// every one of them cost the single tap. First a hand-rolled
    /// `DragGesture`/`LongPressGesture` composite, which only ever fired on a
    /// hold. Then a `Button` — but wrapped in a custom `ButtonStyle`, a
    /// `.contentShape(Circle())` and a long-press modifier, and the six controls
    /// built from it stayed dead on a single tap while the two controls built
    /// the plain way, in the same clusters, on the same screen, kept working.
    /// That comparison is the whole argument: what these controls needed was not
    /// a better layer, it was no layer.
    ///
    /// What went with those layers:
    ///
    /// - The press-down scale. `ButtonStyle` is the only hook for it, and it is
    ///   the hook that was in the way. The resting appearance is unchanged.
    /// - `.contentShape(Circle())`, which had shrunk the target from the full
    ///   `size`-square to the circle inscribed in it — and then shrank it again
    ///   mid-press, because the style scaled the shape it was measured from.
    ///   The target is now the whole square, which is what the gallery control
    ///   has always used.
    /// - `longPressAction`, which no caller had passed since the flash control
    ///   stopped offering torch brightness.
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.42, weight: .medium))
                .symbolRenderingMode(isActive ? .palette : .hierarchical)
                .foregroundStyle(foreground)
                .frame(width: size, height: size)
                .dcSurface(in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .dcAnimation(DC.Motion.standard, value: isActive)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue ?? "")
        .accessibilityHint(accessibilityHint ?? "")
    }

    private var foreground: Color {
        if !isEnabled { return DC.Color.chromeTertiary }
        return isActive ? DC.Color.accent : DC.Color.chromePrimary
    }
}

#Preview("Control trio") {
    HStack(spacing: DC.Spacing.controlGap) {
        CircularControlButton(
            systemImage: "slider.horizontal.3",
            accessibilityLabel: "Adjustments"
        )
        CircularControlButton(
            systemImage: "bolt.fill",
            isActive: true,
            accessibilityLabel: "Flash",
            accessibilityValue: "On"
        )
        CircularControlButton(
            systemImage: "gearshape",
            accessibilityLabel: "Settings"
        )
        CircularControlButton(
            systemImage: "flashlight.on.fill",
            isEnabled: false,
            accessibilityLabel: "Torch"
        )
    }
    .padding(40)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(
        LinearGradient(colors: [.orange, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
    )
    .preferredColorScheme(.dark)
}
