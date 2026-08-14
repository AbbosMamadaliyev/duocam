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
    @State private var didFireLongPress = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.42, weight: .medium))
            .symbolRenderingMode(isActive ? .palette : .hierarchical)
            .foregroundStyle(foreground)
            .frame(width: size, height: size)
            .dcSurface(in: Circle())
            .scaleEffect(isPressed && !reduceMotion ? 0.92 : 1)
            .opacity(isPressed ? 0.85 : 1)
            .dcAnimation(DC.Motion.press, value: isPressed)
            .contentShape(Circle())
            .gesture(pressGesture)
            .disabled(!isEnabled)
            .dcAnimation(DC.Motion.standard, value: isActive)
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(accessibilityValue ?? "")
            .accessibilityHint(accessibilityHint ?? "")
            .accessibilityAction { action() }
    }

    /// Tap and long press share one gesture rather than layering a
    /// `LongPressGesture` over a `Button`.
    ///
    /// Layering them is what broke single taps: the long-press recognizer wins
    /// the touch sequence, and `Button`'s own tap never fires — every control
    /// on the camera screen could only be triggered by holding it. The
    /// minimum-distance-0 drag doubles as a press tracker, so press-down
    /// feedback still starts on touch rather than on release, and it is the
    /// same shape as `MorphingShutter`'s gesture.
    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !isPressed else { return }
                isPressed = true
            }
            .onEnded { value in
                isPressed = false

                // A long press that already fired must not also fire the tap.
                guard !didFireLongPress else {
                    didFireLongPress = false
                    return
                }
                // Treat it as a tap only if the finger stayed on the control.
                let distance = hypot(value.translation.width, value.translation.height)
                guard distance < size else { return }
                action()
            }
            .simultaneously(with:
                LongPressGesture(minimumDuration: 0.4)
                    .onEnded { _ in
                        guard let longPressAction else { return }
                        didFireLongPress = true
                        longPressAction()
                    }
            )
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
