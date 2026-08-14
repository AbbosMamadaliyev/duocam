import CoreMotion
import SwiftUI

/// Rule-of-thirds grid (Doc 3 Phase 4 task 20).
struct GridOverlay: View {
    var body: some View {
        GeometryReader { proxy in
            Path { path in
                let w = proxy.size.width
                let h = proxy.size.height
                for i in 1...2 {
                    let x = w * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: h))
                    let y = h * CGFloat(i) / 3
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: w, y: y))
                }
            }
            .stroke(DC.Color.chromePrimary.opacity(0.25), lineWidth: 0.5)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Horizon level indicator (Doc 3 Phase 4 task 20).
///
/// Turns accent yellow within 1° of level, which is the whole point of it —
/// a line that only ever shows the angle makes the user do the judging.
struct LevelIndicator: View {
    let rollDegrees: Double

    private var isLevel: Bool { abs(rollDegrees) < 1 }

    var body: some View {
        ZStack {
            // Fixed reference.
            Capsule()
                .fill(DC.Color.chromePrimary.opacity(0.35))
                .frame(width: 64, height: 2)

            // Rolls with the device.
            Capsule()
                .fill(isLevel ? DC.Color.accent : DC.Color.chromePrimary)
                .frame(width: 100, height: 2)
                .rotationEffect(.degrees(rollDegrees))
        }
        .animation(.easeOut(duration: 0.08), value: rollDegrees)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Publishes device roll for the level indicator.
///
/// Started and stopped with the indicator's visibility — a motion manager left
/// running is a measurable battery cost for a feature the user turned off.
@MainActor
@Observable
final class LevelMotionProvider {
    private(set) var rollDegrees: Double = 0
    private let motion = CMMotionManager()

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let data else { return }
            MainActor.assumeIsolated {
                self?.rollDegrees = data.attitude.roll * 180 / .pi
            }
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        rollDegrees = 0
    }
}

/// Full-screen white flash used as a light source when the front camera is
/// primary (Doc 3 Phase 4 task 19).
///
/// The rear flash is a LED the front camera cannot see, so the only light
/// source available for a front-primary capture is the display itself.
struct ScreenFlashOverlay: View {
    let isActive: Bool

    var body: some View {
        Color.white
            .ignoresSafeArea()
            .opacity(isActive ? 1 : 0)
            .allowsHitTesting(false)
            .animation(.easeIn(duration: 0.05), value: isActive)
            .accessibilityHidden(true)
    }
}

/// The 0.1s 30%-opacity flash confirming a capture (Doc 3 Phase 4 task 4).
struct CaptureFlashOverlay: View {
    let isActive: Bool

    var body: some View {
        Color.white
            .ignoresSafeArea()
            .opacity(isActive ? 0.3 : 0)
            .allowsHitTesting(false)
            .animation(.easeOut(duration: DC.Duration.captureFlash), value: isActive)
            .accessibilityHidden(true)
    }
}

/// Large countdown numeral for the self-timer (Doc 3 Phase 4 task 6).
struct TimerCountdownOverlay: View {
    let remaining: Int

    var body: some View {
        Text("\(remaining)")
            .font(.system(size: 120, weight: .thin, design: .rounded))
            .foregroundStyle(DC.Color.chromePrimary)
            .shadow(color: .black.opacity(0.4), radius: 12)
            .transition(.scale(scale: 1.4).combined(with: .opacity))
            .id(remaining)
            .allowsHitTesting(false)
            .accessibilityLabel("\(remaining) seconds")
    }
}

/// Self-timer options (Doc 2 §4.1).
nonisolated enum SelfTimer: Int, CaseIterable, Identifiable, Codable, Sendable {
    case off = 0
    case three = 3
    case ten = 10

    var id: Int { rawValue }

    var displayName: String {
        self == .off ? "Off" : "\(rawValue)s"
    }
}
