import SwiftUI

/// A parameter slider for the Adjustments sheet (Doc 2 §6.2).
///
/// Custom rather than `Slider` because Doc 2 specifies a 4pt track, an accent
/// fill, a 28pt knob with a shadow, a detent haptic, and a value pill that
/// appears above the knob only while dragging — none of which the system
/// control exposes.
struct CameraSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    /// A value the slider snaps toward with a haptic — 0 EV for exposure,
    /// centre for white balance. `nil` for sliders with no natural centre.
    var detent: Double?
    /// Formats the value for the drag-time pill.
    var format: (Double) -> String = { String(format: "%.1f", $0) }
    /// When present, an `AUTO` / `AF` toggle sits at the leading edge.
    var autoLabel: String?
    var isAuto: Bool = false
    var onAutoToggle: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDragging = false
    @State private var lastDetentSide: Int = 0

    private let trackHeight: CGFloat = 4
    private let knobSize: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            GeometryReader { proxy in
                track(width: proxy.size.width)
            }
            .frame(height: knobSize)
        }
        .opacity(isAuto ? 0.45 : 1)
        .dcAnimation(DC.Motion.fade, value: isAuto)
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityValue(isAuto ? "Auto" : format(value))
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 20
            switch direction {
            case .increment: value = min(range.upperBound, value + step)
            case .decrement: value = max(range.lowerBound, value - step)
            @unknown default: break
            }
        }
    }

    private var header: some View {
        HStack {
            Text(title)
                .font(DC.Font.sheetBody)
                .foregroundStyle(DC.Color.chromeSecondary)

            Spacer()

            if let autoLabel {
                Button(action: onAutoToggle) {
                    Text(autoLabel)
                        .font(DC.Font.pillCaption)
                        .foregroundStyle(isAuto ? .black : DC.Color.chromeSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background {
                            Capsule().fill(isAuto ? DC.Color.accent : DC.Color.chromeTertiary.opacity(0.4))
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title) automatic")
                .accessibilityAddTraits(isAuto ? [.isButton, .isSelected] : .isButton)
            } else {
                Text(format(value))
                    .font(DC.Font.pillLabel)
                    .foregroundStyle(DC.Color.chromePrimary)
            }
        }
    }

    private func track(width: CGFloat) -> some View {
        let usable = max(width - knobSize, 1)
        let fraction = normalized(value)
        let knobX = usable * fraction + knobSize / 2

        return ZStack(alignment: .leading) {
            Capsule()
                .fill(DC.Color.chromeTertiary)
                .frame(height: trackHeight)

            Capsule()
                .fill(DC.Color.accent)
                .frame(width: knobX, height: trackHeight)

            if let detent {
                Rectangle()
                    .fill(DC.Color.chromePrimary.opacity(0.5))
                    .frame(width: 1, height: 10)
                    .offset(x: usable * normalized(detent) + knobSize / 2)
            }

            knob
                .position(x: knobX, y: knobSize / 2)
                .overlay(alignment: .top) {
                    if isDragging {
                        valuePill
                            .offset(x: knobX - width / 2, y: -30)
                    }
                }
        }
        .frame(height: knobSize)
        .contentShape(Rectangle())
        .gesture(dragGesture(usable: usable))
    }

    private var knob: some View {
        Circle()
            .fill(DC.Color.chromePrimary)
            .frame(width: knobSize, height: knobSize)
            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
            .scaleEffect(isDragging && !reduceMotion ? 1.1 : 1)
            .animation(DC.Motion.resolve(DC.Motion.press, reduceMotion: reduceMotion),
                       value: isDragging)
    }

    private var valuePill: some View {
        Text(format(value))
            .font(DC.Font.pillLabel)
            .foregroundStyle(DC.Color.chromePrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .dcSurface(in: Capsule())
            .fixedSize()
    }

    private func dragGesture(usable: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                if !isDragging {
                    isDragging = true
                    HapticEngine.shared.prepare()
                }
                let fraction = ((drag.location.x - knobSize / 2) / usable).clamped(to: 0...1)
                let newValue = range.lowerBound + fraction * (range.upperBound - range.lowerBound)
                fireDetentHapticIfCrossed(from: value, to: newValue)
                value = newValue
            }
            .onEnded { _ in
                isDragging = false
                lastDetentSide = 0
            }
    }

    /// Fires once per crossing rather than on every frame near the detent —
    /// a continuously retriggering haptic feels like a buzz, not a notch.
    private func fireDetentHapticIfCrossed(from old: Double, to new: Double) {
        guard let detent else { return }
        let side = new < detent ? -1 : (new > detent ? 1 : 0)
        if side != lastDetentSide, (old - detent).sign != (new - detent).sign || new == detent {
            HapticEngine.shared.sliderDetent()
        }
        lastDetentSide = side
    }

    private func normalized(_ raw: Double) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return CGFloat((raw - range.lowerBound) / span).clamped(to: 0...1)
    }
}

extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}

#Preview("Sliders") {
    struct Harness: View {
        @State private var exposure: Double = 0
        @State private var iso: Double = 400
        @State private var isoAuto = true

        var body: some View {
            VStack(spacing: 24) {
                CameraSlider(
                    title: "Exposure",
                    value: $exposure,
                    range: -2...2,
                    detent: 0,
                    format: { String(format: "%+.1f EV", $0) }
                )
                CameraSlider(
                    title: "ISO",
                    value: $iso,
                    range: 32...3200,
                    format: { String(format: "%.0f", $0) },
                    autoLabel: "AUTO",
                    isAuto: isoAuto,
                    onAutoToggle: { isoAuto.toggle() }
                )
            }
            .padding(24)
        }
    }
    return Harness()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: 0x101014))
        .preferredColorScheme(.dark)
}
