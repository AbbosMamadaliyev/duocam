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
    var longPressAction: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.42, weight: .medium))
                .symbolRenderingMode(isActive ? .palette : .hierarchical)
                .foregroundStyle(foreground)
                .frame(width: size, height: size)
                .dcSurface(in: Circle())
        }
        .buttonStyle(PressScaleStyle(isPressed: $isPressed))
        .disabled(!isEnabled)
        // Attached unconditionally and no-op when there is no long-press
        // action: `@ViewBuilder` cannot assemble gestures, and a conditional
        // gesture modifier changes the view's identity between states.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.4)
                .onEnded { _ in longPressAction?() }
        )
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

/// Shared press-down feedback: a 0.08s ease-out scale, per Doc 2 §9.1's
/// "micro-feedback (press)" curve.
struct PressScaleStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var isPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(DC.Motion.resolve(DC.Motion.press, reduceMotion: reduceMotion),
                       value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                isPressed = pressed
            }
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
