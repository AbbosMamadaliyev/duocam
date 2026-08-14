import SwiftUI

/// The mode selector, and the stream selector inside the Adjustments sheet
/// (Doc 2 §4.3, §6.2).
///
/// A custom control rather than `Picker(.segmented)` for three reasons the
/// system control cannot satisfy: the selected segment must be a filled accent
/// capsule with black text, the indicator must spring between positions, and
/// the whole control must accept a horizontal swipe that advances the
/// selection — matching the iOS Camera mode wheel.
struct CustomSegmentedControl<T: Hashable & Identifiable>: View {
    let options: [T]
    @Binding var selection: T
    let title: (T) -> String

    var height: CGFloat = DC.Size.modeSelector
    var accessibilityLabel: String = "Mode"
    var onChange: (T) -> Void = { _ in }

    @Namespace private var indicator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                segment(option)
            }
        }
        .padding(4)
        .frame(height: height)
        .dcSurface(in: Capsule())
        .gesture(swipeGesture)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private func segment(_ option: T) -> some View {
        let isSelected = option == selection

        return Text(title(option))
            .font(DC.Font.modeLabel)
            .foregroundStyle(isSelected ? .black : DC.Color.chromeSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if isSelected {
                    Capsule()
                        .fill(DC.Color.accent)
                        .matchedGeometryEffect(id: "segment", in: indicator)
                }
            }
            .contentShape(Capsule())
            .onTapGesture { select(option) }
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityLabel(title(option))
    }

    /// Horizontal swipe advances the selection, matching iOS Camera.
    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height),
                      let current = options.firstIndex(of: selection)
                else { return }

                let step = value.translation.width < 0 ? 1 : -1
                let next = current + step
                guard options.indices.contains(next) else { return }
                select(options[next])
            }
    }

    private func select(_ option: T) {
        guard option != selection else { return }
        withAnimation(DC.Motion.resolve(DC.Motion.standard, reduceMotion: reduceMotion)) {
            selection = option
        }
        HapticEngine.shared.modeChanged()
        onChange(option)
    }
}

#Preview("Mode selector") {
    struct Harness: View {
        @State private var mode: CaptureMode = .dualFrontBack
        var body: some View {
            CustomSegmentedControl(
                options: CaptureMode.allCases,
                selection: $mode,
                title: \.displayName,
                accessibilityLabel: "Capture mode"
            )
            .padding(.horizontal, DC.Spacing.edgeMargin)
        }
    }
    return Harness()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(colors: [.indigo, .black], startPoint: .top, endPoint: .bottom)
        )
        .preferredColorScheme(.dark)
}

#Preview("Stream selector") {
    struct Harness: View {
        @State private var role: StreamRole = .primary
        var body: some View {
            CustomSegmentedControl(
                options: StreamRole.allCases,
                selection: $role,
                title: \.displayName,
                height: 36,
                accessibilityLabel: "Stream"
            )
            .padding(.horizontal, DC.Spacing.edgeMargin)
        }
    }
    return Harness()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .preferredColorScheme(.dark)
}
