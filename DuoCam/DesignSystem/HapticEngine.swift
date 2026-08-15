import SwiftUI
import UIKit

/// The app's complete haptic vocabulary (Doc 2 §10).
///
/// Deliberately exposes *semantic* methods — `captureTaken()`, `snapped()`,
/// `modeChanged()` — and never raw impact styles. Doc 3 Phase 3 task 3 gives
/// the reason: once call sites can pick their own styles, the vocabulary drifts
/// and two conceptually identical events start feeling different.
///
/// Generators are pre-prepared, because an unprepared generator has a
/// perceptible latency on first fire — which in a camera app means the shutter
/// feels late.
@MainActor
final class HapticEngine {
    static let shared = HapticEngine()

    private let light = UIImpactFeedbackGenerator(style: .light)
    private let medium = UIImpactFeedbackGenerator(style: .medium)
    private let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private let selection = UISelectionFeedbackGenerator()
    private let notification = UINotificationFeedbackGenerator()

    private init() {}

    /// Call before a gesture begins so the Taptic Engine is already warm.
    /// Doc 2 §10: generators must be pre-prepared *before gesture start*.
    func prepare() {
        light.prepare()
        medium.prepare()
        heavy.prepare()
        rigid.prepare()
        selection.prepare()
        notification.prepare()
    }

    // MARK: Capture

    /// Photo captured.
    func captureTaken() { medium.impactOccurred() }

    /// Recording started.
    func recordingStarted() { notification.notificationOccurred(.success) }

    /// Recording stopped.
    func recordingStopped() { heavy.impactOccurred() }

    /// Recording paused or resumed.
    func recordingPauseToggled() { light.impactOccurred() }

    /// A still grabbed during an active recording.
    func stillDuringVideo() { light.impactOccurred() }

    // MARK: Overlay

    /// The overlay was picked up and is now following the finger.
    ///
    /// Light, and fired exactly once per drag. It used to fire on every snap
    /// zone the finger passed over, which on a screen-length drag is eight taps
    /// against the palm — the overlay felt like it was resisting rather than
    /// being carried.
    func overlayLifted() { light.impactOccurred() }

    /// The overlay was set down.
    func overlayPlaced() { light.impactOccurred() }

    /// Crossed a 5% step while pinch-resizing.
    func resizeStep() { rigid.impactOccurred() }

    /// Hit the 25% or 50% resize limit.
    func resizeLimit() { heavy.impactOccurred() }

    /// Primary and secondary streams swapped.
    func streamsSwapped() { medium.impactOccurred() }

    /// The split divider crossed the exact 50% detent.
    func dividerCentred() { rigid.impactOccurred() }

    // MARK: Selection

    /// A layout was chosen in the layout sheet.
    func layoutSelected() { selection.selectionChanged() }

    /// The capture mode changed.
    func modeChanged() { selection.selectionChanged() }

    /// Photo ↔ Video toggled.
    func subModeChanged() { selection.selectionChanged() }

    /// A slider crossed its detent.
    func sliderDetent() { light.impactOccurred() }

    /// AE/AF locked by long press.
    func focusLocked() { rigid.impactOccurred() }

    // MARK: Status

    /// An unsupported action was attempted.
    func error() { notification.notificationOccurred(.error) }

    /// Thermal pressure crossed a threshold.
    func warning() { notification.notificationOccurred(.warning) }

    /// A destructive-ish operation completed successfully (e.g. Reset).
    func success() { notification.notificationOccurred(.success) }
}

// MARK: - Environment access

private struct HapticsKey: EnvironmentKey {
    static var defaultValue: HapticEngine { HapticEngine.shared }
}

extension EnvironmentValues {
    var haptics: HapticEngine {
        get { self[HapticsKey.self] }
        set { self[HapticsKey.self] = newValue }
    }
}
