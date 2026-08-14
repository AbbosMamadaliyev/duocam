import SwiftUI

// MARK: - Quality pill (Doc 2 §4.2)

/// The top-left readout: `4K RES │ 30 FPS`.
///
/// Bound to the **negotiated** quality, never to the requested one. If the user
/// asks for 4K and hardware cost forces 1080p, this reads 1080p immediately.
/// Doc 3 reminder 10: *"Users forgive limitations; they do not forgive being
/// misled about what they just recorded."*
struct QualityPill: View {
    let quality: NegotiatedQuality
    /// Dimmed and non-interactive during recording (Doc 2 §7.1 step 3).
    var isDimmed: Bool = false
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                valueGroup(quality.resolution.displayName, caption: "RES")

                Rectangle()
                    .fill(DC.Color.chromeTertiary)
                    .frame(width: 1, height: 14)

                valueGroup(quality.frameRate.displayName, caption: "FPS")
            }
            .padding(.horizontal, 14)
            .frame(height: DC.Size.pillHeight)
            .dcSurface(in: Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isDimmed ? 0.5 : 1)
        .allowsHitTesting(!isDimmed)
        .dcAnimation(DC.Motion.fade, value: isDimmed)
        .dcAnimation(DC.Motion.standard, value: quality)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Quality")
        .accessibilityValue("\(quality.resolution.displayName), \(quality.frameRate.displayName) frames per second")
        .accessibilityHint(isDimmed ? "Stop recording to change quality" : "Opens quality options")
    }

    private func valueGroup(_ value: String, caption: String) -> some View {
        HStack(spacing: 3) {
            Text(value)
                .font(DC.Font.pillLabel)
                .foregroundStyle(DC.Color.chromePrimary)
            Text(caption)
                .font(DC.Font.pillCaption)
                .foregroundStyle(DC.Color.chromeSecondary)
        }
    }
}

// MARK: - Elapsed timer (Doc 2 §7.2)

/// Top-centre during recording: a pulsing red dot and `MM:SS`.
///
/// The dot pulses at 1 Hz; the digits are monospaced so the readout does not
/// shift horizontally every second.
struct ElapsedTimerPill: View {
    let elapsed: TimeInterval
    /// While paused the dot stops pulsing and holds at 40% (Doc 2 §7.5).
    var isPaused: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dotIsDim = false

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 7) {
                Circle()
                    .fill(DC.Color.record)
                    .frame(width: 8, height: 8)
                    .opacity(dotOpacity)

                Text(formatted)
                    .font(DC.Font.timerLarge)
                    .foregroundStyle(DC.Color.chromePrimary)
            }
            .padding(.horizontal, 12)
            .frame(height: DC.Size.timerHeight)
            .dcSurface(in: Capsule())

            if isPaused {
                Text("PAUSED")
                    .font(DC.Font.microLabel)
                    .tracking(1.6)
                    .foregroundStyle(DC.Color.accent)
                    .transition(.opacity)
            }
        }
        .dcAnimation(DC.Motion.fade, value: isPaused)
        .onAppear { startPulse() }
        .onChange(of: isPaused) { _, _ in startPulse() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isPaused ? "Recording paused" : "Recording")
        .accessibilityValue(spokenDuration)
    }

    private var dotOpacity: Double {
        if isPaused { return 0.4 }
        if reduceMotion { return 1 }
        return dotIsDim ? 0.4 : 1
    }

    private func startPulse() {
        guard !isPaused, !reduceMotion else {
            dotIsDim = false
            return
        }
        withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
            dotIsDim = true
        }
    }

    private var formatted: String {
        let total = Int(elapsed)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private var spokenDuration: String {
        let total = Int(elapsed)
        let minutes = total / 60
        let seconds = total % 60
        if minutes == 0 { return "\(seconds) seconds" }
        return "\(minutes) minutes \(seconds) seconds"
    }
}

// MARK: - Zoom pills (Doc 2 §4.3)

/// The lens stops available for the current primary camera.
///
/// Auto-hides after 4 seconds of no interaction and reappears on any pinch or
/// tap in the preview area — the parent owns that timer, since it is the only
/// thing that knows about preview touches.
struct ZoomPillGroup: View {
    struct Stop: Identifiable, Equatable {
        let id: String
        let label: String
        let zoomFactor: CGFloat

        init(label: String, zoomFactor: CGFloat) {
            self.id = label
            self.label = label
            self.zoomFactor = zoomFactor
        }
    }

    let stops: [Stop]
    let selected: Stop.ID
    var onSelect: (Stop) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(stops) { stop in
                let isSelected = stop.id == selected
                Button {
                    onSelect(stop)
                } label: {
                    Text(stop.label)
                        .font(DC.Font.pillLabel)
                        .foregroundStyle(isSelected ? .black : DC.Color.chromePrimary)
                        .frame(width: 40, height: 32)
                        .background {
                            if isSelected {
                                Circle().fill(DC.Color.accent)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(stop.label) zoom")
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(4)
        .dcSurface(in: Capsule())
        .dcAnimation(DC.Motion.standard, value: selected)
    }
}

// MARK: - Previews

#Preview("Pills") {
    VStack(spacing: 24) {
        QualityPill(quality: NegotiatedQuality(resolution: .uhd4K, frameRate: .fps30, hardwareCost: 0.8))
        QualityPill(quality: .placeholder, isDimmed: true)
        ElapsedTimerPill(elapsed: 92)
        ElapsedTimerPill(elapsed: 92, isPaused: true)
        ZoomPillGroup(
            stops: [
                .init(label: "0.5x", zoomFactor: 0.5),
                .init(label: "1x", zoomFactor: 1),
                .init(label: "3x", zoomFactor: 3),
            ],
            selected: "1x"
        )
    }
    .padding(40)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(
        LinearGradient(colors: [.teal, .purple], startPoint: .top, endPoint: .bottom)
    )
    .preferredColorScheme(.dark)
}
