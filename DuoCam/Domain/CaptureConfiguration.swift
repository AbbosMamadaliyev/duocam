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

    /// What the user asked the main stream to magnify, expressed the way the
    /// pills read it: `1` is the wide lens's own framing, `0.5` is twice as
    /// wide, `3` is three times closer.
    ///
    /// Deliberately *not* a device zoom factor, and deliberately independent of
    /// `primarySource`. A lens is one way to reach a magnification and digital
    /// zoom is the other; keeping the request in lens-agnostic units is what
    /// lets the engine ride one lens up to the point where the next takes over,
    /// instead of cutting between them. Excluded from
    /// `requiresSessionReconfiguration` because no zoom, of either kind, needs
    /// the graph rebuilt.
    var primaryZoom: CGFloat = 1

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
        // A magnification asked of one pairing means nothing to the next: the
        // new primary is a different lens with a different widest frame.
        primaryZoom = 1
    }

    /// Swaps which stream fills the screen. Pure presentation — Doc 2 §5.6
    /// stresses that both streams stay live, so this must never trigger a
    /// session reconfiguration.
    mutating func swapStreams() {
        guard let secondary = secondarySource else { return }
        secondarySource = primarySource
        primarySource = secondary
        // The stream arriving from the overlay is framed at its own lens's
        // full width; carrying the old stream's magnification over would crop
        // it the moment it took the screen. Callers that know better — the zoom
        // pills, which swap *in order to* reach a magnification — set it again
        // after swapping.
        primaryZoom = 1
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
