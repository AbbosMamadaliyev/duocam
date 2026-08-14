import SwiftUI

/// The five states the shutter can be in (Doc 2 §6.1).
///
/// One control, five appearances. This is the fix for prototype problem P4,
/// where a red record circle and a white photo circle sat side by side with no
/// indication of which was active.
enum ShutterState: Equatable {
    case photoIdle
    case videoIdle
    case videoRecording
    case videoPaused
    case disabled
}

/// The app's single primary action.
///
/// Design principle 2: *"The shutter is the only element that is never hidden,
/// never moved, and never ambiguous."*
///
/// The morph is implemented as an animatable `size` and `cornerRadius` on **one**
/// `RoundedRectangle`, so the shape interpolates continuously. Doc 2 §6.1 is
/// explicit that this must not be a cross-fade between two views — a cross-fade
/// shows both shapes at once through the middle of the transition, which reads
/// as a glitch rather than as a transformation.
struct MorphingShutter: View {
    let state: ShutterState

    /// 0…1 while a long press is filling the ring — burst progress in Photo
    /// mode, quick-record duration in Video mode.
    var longPressProgress: Double = 0

    var onTap: () -> Void = {}
    var onLongPressChanged: (Bool) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPressed = false
    @State private var pausePulse = false

    var body: some View {
        ZStack {
            outerRing
            progressRing
            innerShape
        }
        .frame(width: DC.Size.shutterOuter, height: DC.Size.shutterOuter)
        .contentShape(Circle())
        .dcAnimation(DC.Motion.shutterMorph, value: state)
        .dcAnimation(DC.Motion.press, value: isPressed)
        .gesture(pressGesture)
        .onAppear { startPausePulseIfNeeded() }
        .onChange(of: state) { _, _ in startPausePulseIfNeeded() }
        .accessibilityElement()
        .accessibilityLabel("Shutter")
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onTap() }
    }

    // MARK: Pieces

    private var outerRing: some View {
        Circle()
            .strokeBorder(
                state == .disabled ? DC.Color.chromeTertiary : DC.Color.chromePrimary,
                lineWidth: 4
            )
    }

    /// Fills clockwise while a long press is held (Doc 2 §6.1, burst capture).
    @ViewBuilder
    private var progressRing: some View {
        if longPressProgress > 0 {
            Circle()
                .trim(from: 0, to: longPressProgress)
                .stroke(DC.Color.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }

    private var innerShape: some View {
        RoundedRectangle(cornerRadius: innerRadius, style: .circular)
            .fill(innerFill)
            .frame(width: innerSize, height: innerSize)
            .opacity(pausePulseOpacity)
    }

    // MARK: State → geometry

    private var innerSize: CGFloat {
        switch state {
        case .photoIdle:
            isPressed ? 56 : DC.Size.shutterInner
        case .videoIdle:
            isPressed ? 56 : DC.Size.shutterInner
        case .videoRecording, .videoPaused:
            DC.Size.shutterRecording
        case .disabled:
            DC.Size.shutterInner
        }
    }

    /// A `RoundedRectangle` whose radius is exactly half its side *is* a
    /// circle, which is what lets one shape cover both the resting circle and
    /// the recording square without ever swapping views.
    ///
    /// `.circular` rather than `.continuous` here is the one deliberate
    /// exception to Doc 2 §2.3: the resting shape sits concentrically inside a
    /// true circular ring, and a squircle inside a circle reads as a rendering
    /// defect rather than as a style choice.
    private var innerRadius: CGFloat {
        switch state {
        case .videoRecording, .videoPaused: DC.Radius.shutterSquare
        default: innerSize / 2
        }
    }

    private var innerFill: Color {
        switch state {
        case .photoIdle:
            isPressed ? DC.Color.chromePrimary.opacity(0.8) : DC.Color.chromePrimary
        case .videoIdle, .videoRecording:
            DC.Color.record
        case .videoPaused:
            DC.Color.record
        case .disabled:
            DC.Color.chromeTertiary
        }
    }

    /// Paused pulses between 100% and 50% on a 1.4s loop (Doc 2 §7.5).
    private var pausePulseOpacity: Double {
        guard state == .videoPaused, !reduceMotion else { return 1 }
        return pausePulse ? 0.5 : 1
    }

    private func startPausePulseIfNeeded() {
        guard state == .videoPaused, !reduceMotion else {
            pausePulse = false
            return
        }
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
            pausePulse = true
        }
    }

    // MARK: Gesture

    /// A minimum-distance-0 drag doubles as a press tracker, which is what lets
    /// the press-down scale start on touch rather than on release.
    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard state != .disabled, !isPressed else { return }
                isPressed = true
                onLongPressChanged(true)
            }
            .onEnded { value in
                guard state != .disabled else { return }
                isPressed = false
                onLongPressChanged(false)

                // Treat it as a tap only if the finger stayed on the control.
                let distance = hypot(value.translation.width, value.translation.height)
                if distance < DC.Size.shutterOuter / 2 {
                    onTap()
                }
            }
    }

    private var accessibilityValue: String {
        switch state {
        case .photoIdle: "Photo mode, ready"
        case .videoIdle: "Video mode, ready"
        case .videoRecording: "Recording"
        case .videoPaused: "Recording paused"
        case .disabled: "Unavailable"
        }
    }
}

// MARK: - Previews

#Preview("All states") {
    VStack(spacing: 28) {
        ForEach(
            [
                ("Photo idle", ShutterState.photoIdle),
                ("Video idle", .videoIdle),
                ("Recording", .videoRecording),
                ("Paused", .videoPaused),
                ("Disabled", .disabled),
            ],
            id: \.0
        ) { name, state in
            HStack(spacing: 20) {
                MorphingShutter(state: state)
                Text(name)
                    .font(DC.Font.modeLabel)
                    .foregroundStyle(DC.Color.chromeSecondary)
            }
        }
    }
    .padding(40)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.black)
    .preferredColorScheme(.dark)
}

#Preview("Burst progress") {
    MorphingShutter(state: .photoIdle, longPressProgress: 0.65)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .preferredColorScheme(.dark)
}
