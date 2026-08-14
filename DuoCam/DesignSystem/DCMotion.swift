import SwiftUI

// MARK: - Motion (Doc 2 §9)

extension DC {
    /// The complete animation vocabulary. Design principle 5: *"No element
    /// appears, disappears, or moves instantly."*
    ///
    /// Every curve has a Reduce Motion alternative. Doc 2 §9.3 is emphatic that
    /// the alternative removes *motion* only — all haptics remain, because
    /// motion reduction must not remove feedback.
    enum Motion {
        /// Standard UI transition.
        static let standard = Animation.spring(response: 0.4, dampingFraction: 0.8)
        /// Layout morph — the secondary stream's frame, radius and clip shape
        /// interpolating together.
        static let layout = Animation.spring(response: 0.5, dampingFraction: 0.8)
        /// Overlay magnetic snap. Stiff and lightly damped so a flick reads as
        /// physical rather than as an animation playing.
        static let overlaySnap = Animation.interpolatingSpring(stiffness: 220, damping: 24)
        /// Tracks a finger during a gesture.
        static let gestureTracking = Animation.interactiveSpring(response: 0.2, dampingFraction: 0.85)
        /// Press-down micro-feedback.
        static let press = Animation.easeOut(duration: 0.08)
        /// Generic fade.
        static let fade = Animation.easeInOut(duration: 0.25)
        /// The shutter's circle↔square morph.
        static let shutterMorph = Animation.spring(response: 0.35, dampingFraction: 0.7)
        /// The primary/secondary swap crossfade.
        static let swap = Animation.spring(response: 0.45, dampingFraction: 0.78)

        /// The Reduce Motion substitute for every spring above.
        static let reduced = Animation.easeInOut(duration: 0.2)

        /// Resolve a curve against the accessibility setting.
        static func resolve(_ animation: Animation, reduceMotion: Bool) -> Animation {
            reduceMotion ? reduced : animation
        }
    }

    /// Fixed durations quoted by Doc 2, kept here so timing that must agree
    /// across several views cannot drift apart.
    enum Duration {
        /// Idle → Recording, all seven elements in parallel (Doc 2 §7.1).
        static let recordingTransition: TimeInterval = 0.4
        /// Progressive blur while the session reconfigures (Doc 2 §9.2).
        static let reconfigureBlur: TimeInterval = 0.2
        /// Cross-fade from the blurred still to the new live preview.
        static let reconfigureCrossfade: TimeInterval = 0.25
        /// How long the transient `PHOTO` / `VIDEO` label stays up.
        static let subModeLabel: TimeInterval = 1.2
        /// Zoom pills idle out.
        static let zoomPillAutoHide: TimeInterval = 4
        /// Split divider handle idles out.
        static let dividerAutoHide: TimeInterval = 3
        /// Chrome dims to 30% opacity.
        static let chromeAutoHide: TimeInterval = 6
        /// Toast dwell before it leaves.
        static let toastDwell: TimeInterval = 2.5
        /// Focus reticle fade after it settles.
        static let reticleDwell: TimeInterval = 2
        /// Photo capture screen flash.
        static let captureFlash: TimeInterval = 0.1
    }
}

// MARK: - Reduce Motion convenience

private struct ReducedAnimationModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: V

    func body(content: Content) -> some View {
        content.animation(DC.Motion.resolve(animation, reduceMotion: reduceMotion), value: value)
    }
}

extension View {
    /// `.animation(_:value:)` that automatically degrades under Reduce Motion.
    ///
    /// Using this instead of the raw modifier is what makes Doc 2 §9.3 a
    /// property of the design system rather than something each view has to
    /// remember — and forgetting it in one place is exactly how an app ends up
    /// "mostly" supporting the setting.
    func dcAnimation<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(ReducedAnimationModifier(animation: animation, value: value))
    }
}
