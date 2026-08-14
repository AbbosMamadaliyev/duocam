import Foundation

/// The complete description of what the capture layer should be doing.
///
/// Deliberately a value type: the view model owns one, mutates it, and hands
/// the whole thing to the engine. That makes "what changed" diffable, which is
/// what lets the engine decide between a cheap presentation update (layout,
/// swap) and an expensive session reconfiguration (mode, resolution, lens) —
/// the distinction Doc 2 §9.2 requires, since only the latter needs the
/// blur-masked transition.
nonisolated struct CaptureConfiguration: Equatable, Codable, Sendable {
    var mode: CaptureMode = .dualFrontBack
    var layout: LayoutType = .pipRounded
    var quality: QualityProfile = .default

    /// Which lens feeds each role. Independent of `mode` on purpose (Doc 1
    /// §3.2) — the user can put ultra-wide in the overlay of a Front + Back
    /// session without the mode changing meaning.
    var primarySource: CameraSource = .rearWide
    var secondarySource: CameraSource? = .front

    var photoVideoMode: PhotoVideoMode = .video
    var flashMode: FlashMode = .off
    var isTorchOn: Bool = false
    var mirrorsFrontCamera: Bool = true
    var showsGrid: Bool = false
    var showsLevel: Bool = false

    static let `default` = CaptureConfiguration()

    /// Applying a mode resets the sources to that mode's defaults, because a
    /// lens that was valid in one mode is frequently invalid in another.
    mutating func apply(mode newMode: CaptureMode) {
        mode = newMode
        let defaults = newMode.defaultSources
        primarySource = defaults.primary
        secondarySource = defaults.secondary
    }

    /// Swaps which stream fills the screen. Pure presentation — Doc 2 §5.6
    /// stresses that both streams stay live, so this must never trigger a
    /// session reconfiguration.
    mutating func swapStreams() {
        guard let secondary = secondarySource else { return }
        secondarySource = primarySource
        primarySource = secondary
    }

    /// True when moving from `self` to `other` requires tearing down and
    /// rebuilding the session, and therefore requires the blur mask.
    func requiresSessionReconfiguration(comparedTo other: CaptureConfiguration) -> Bool {
        mode != other.mode
            || quality.resolution != other.quality.resolution
            || quality.frameRate != other.quality.frameRate
            || Set([primarySource, secondarySource].compactMap { $0 })
                != Set([other.primarySource, other.secondarySource].compactMap { $0 })
    }
}
