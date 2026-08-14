import AVFoundation
import Foundation
import os

/// Watches thermal and system pressure and steps quality down to keep the
/// session alive.
///
/// Doc 1 §5.3.8: *"Thermal degradation is mandatory, not optional. Two live
/// cameras plus real-time Metal composition plus hardware encoding will drive
/// sustained thermal pressure. Without an active governor, iOS will terminate
/// the session mid-recording."*
///
/// Doc 3 builds this in its Phase 2 specifically so Phase 5's 4K support can be
/// added on top of a working governor rather than retrofitted into a pipeline
/// that assumes maximum quality.
@MainActor
@Observable
final class ThermalGovernor {
    /// The ladder from Doc 3 Phase 2 task 13, applied in order.
    enum Step: Int, CaseIterable, Comparable {
        case none = 0
        case secondaryResolution = 1
        case primaryResolution = 2
        case frameRate = 3
        case outputResolution = 4
        case stopRecording = 5

        static func < (lhs: Step, rhs: Step) -> Bool { lhs.rawValue < rhs.rawValue }

        /// Steps 1–4 are silent apart from one toast and a quality-pill update;
        /// step 5 shows an alert (Doc 3 Phase 2 task 14).
        var isSilent: Bool { self != .stopRecording }
    }

    private(set) var currentStep: Step = .none
    private(set) var thermalState: ProcessInfo.ThermalState = .nominal
    private(set) var systemPressure: AVCaptureDevice.SystemPressureState.Level = .nominal

    /// Raised while a recording is in flight. Doc 3 Phase 2 task 15: quality
    /// must never be restored *upward* mid-take — visibly fluctuating quality
    /// is worse than consistently lower quality.
    var isRecording = false

    /// Called with each new step so the capture layer can apply it.
    var onStepChanged: ((Step) -> Void)?
    /// Called once when a step is first crossed, for the single user-facing
    /// toast.
    var onUserVisibleDegradation: ((DegradationReason) -> Void)?

    private var observers: [NSObjectProtocol] = []
    private var pressureObservations: [NSKeyValueObservation] = []

    init() {
        thermalState = ProcessInfo.processInfo.thermalState
        observers.append(
            NotificationCenter.default.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                let state = ProcessInfo.processInfo.thermalState
                MainActor.assumeIsolated {
                    self?.handleThermalState(state)
                }
            }
        )
    }

    /// `systemPressureState` is per-device and only meaningful while a session
    /// is configured, so devices are registered after configuration rather than
    /// at init.
    func observe(devices: [AVCaptureDevice]) {
        pressureObservations.removeAll()
        for device in devices {
            let observation = device.observe(\.systemPressureState, options: [.new]) { [weak self] _, change in
                guard let level = change.newValue?.level else { return }
                MainActor.assumeIsolated {
                    self?.handleSystemPressure(level)
                }
            }
            pressureObservations.append(observation)
        }
    }

    // MARK: Handling

    private func handleThermalState(_ state: ProcessInfo.ThermalState) {
        thermalState = state
        Log.thermal.info("Thermal state → \(String(describing: state), privacy: .public)")
        evaluate(reason: .thermalPressure)
    }

    private func handleSystemPressure(_ level: AVCaptureDevice.SystemPressureState.Level) {
        systemPressure = level
        Log.thermal.info("System pressure → \(level.rawValue, privacy: .public)")
        evaluate(reason: .systemPressure)
    }

    private func evaluate(reason: DegradationReason) {
        let target = targetStep()

        // Only ever climb the ladder while recording. Coming back down is
        // allowed once the take has ended, so the next recording starts at full
        // quality rather than inheriting the last one's heat.
        if target > currentStep {
            advance(to: target, reason: reason)
        } else if target < currentStep, !isRecording {
            Log.thermal.info("Pressure eased — restoring to step \(target.rawValue)")
            currentStep = target
            onStepChanged?(target)
        }
    }

    /// Maps the worse of the two pressure signals onto a ladder step.
    private func targetStep() -> Step {
        let fromThermal: Step = switch thermalState {
        case .nominal: .none
        case .fair: .none
        case .serious: .secondaryResolution
        case .critical: .stopRecording
        @unknown default: .secondaryResolution
        }

        let fromPressure: Step = switch systemPressure {
        case .nominal, .fair: .none
        case .serious: .secondaryResolution
        case .critical: .frameRate
        case .shutdown: .stopRecording
        default: .none
        }

        return max(fromThermal, fromPressure)
    }

    private func advance(to step: Step, reason: DegradationReason) {
        // Climb one rung at a time. Jumping straight to the target would drop
        // more quality than the pressure actually requires, and Doc 1 §1.1's
        // "honest quality" pillar cuts both ways — over-degrading is as
        // dishonest as over-promising.
        let next = Step(rawValue: currentStep.rawValue + 1) ?? step
        let applied = min(next, step)

        guard applied != currentStep else { return }
        currentStep = applied
        Log.thermal.notice("Degradation ladder → step \(applied.rawValue)")

        onStepChanged?(applied)
        if applied.isSilent {
            onUserVisibleDegradation?(reason)
        }
    }

    /// Applies the ladder to a quality profile, returning what should actually
    /// be configured.
    func degraded(_ profile: QualityProfile) -> QualityProfile {
        var result = profile
        switch currentStep {
        case .none:
            break
        case .secondaryResolution:
            // Handled by the engine, which owns the per-stream split; the
            // composited profile is untouched.
            break
        case .primaryResolution:
            result.resolution = profile.resolution.loweredOneTier ?? profile.resolution
        case .frameRate:
            result.resolution = profile.resolution.loweredOneTier ?? profile.resolution
            result.frameRate = .fps24
        case .outputResolution, .stopRecording:
            result.resolution = .hd720p
            result.frameRate = .fps24
        }
        return result
    }

    /// The resolution the *secondary* stream should run at — the first rung.
    func secondaryResolution(for profile: QualityProfile) -> Resolution {
        currentStep >= .secondaryResolution
            ? (profile.resolution.loweredOneTier ?? profile.resolution)
            : profile.resolution
    }

    /// Cleared between takes so a new recording starts from a clean slate.
    func resetAfterRecording() {
        isRecording = false
        evaluate(reason: .thermalPressure)
    }
}
