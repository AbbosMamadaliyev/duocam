import CoreMedia
import CoreVideo
import os

/// Pairs frames from two independently-delivered streams by presentation
/// timestamp.
///
/// Doc 3 Phase 2 task 2: sample buffers arrive on two separate serial queues
/// and must be synchronised "through a small ring buffer that pairs frames by
/// presentation timestamp, tolerating up to one frame of skew".
///
/// The two cameras are genuinely not in lockstep — they free-run at the same
/// nominal rate with an arbitrary phase offset — so waiting for exact PTS
/// equality would pair nothing at all. The rule instead is: the primary stream
/// drives output, and each primary frame is matched with the most recent
/// secondary frame within tolerance.
final class FramePairer: @unchecked Sendable {
    /// One frame of skew at the current rate.
    private var tolerance: CMTime

    private let lock = NSLock()
    private var secondaryBuffer: [(time: CMTime, pixels: CVPixelBuffer)] = []

    /// The newest secondary frame ever offered, kept outside the ring.
    ///
    /// This is what the overlay falls back to when nothing is inside tolerance.
    /// See `matchSecondary(for:)` for why a stale overlay beats no overlay.
    private var lastSecondary: (time: CMTime, pixels: CVPixelBuffer)?

    /// Depth 3 covers a full frame of skew in either direction plus a spare.
    /// Deeper would add latency; shallower would drop pairs during jitter.
    private let ringDepth = 3

    /// How long the last secondary frame may be reused before the overlay is
    /// dropped instead. Half a second is far longer than any skew or lens
    /// switch, and short enough that a genuinely dead stream does not leave a
    /// frozen picture in the corner for the rest of the take.
    private let maximumHold = CMTime(value: 1, timescale: 2)

    private(set) var pairedCount = 0
    private(set) var unpairedCount = 0
    /// Frames that reused the previous secondary rather than pairing.
    private(set) var heldCount = 0

    init(frameRate: FrameRate = .fps30) {
        tolerance = CMTime(value: 1, timescale: CMTimeScale(frameRate.rawValue))
    }

    func updateFrameRate(_ frameRate: FrameRate) {
        lock.lock()
        defer { lock.unlock() }
        tolerance = CMTime(value: 1, timescale: CMTimeScale(frameRate.rawValue))
    }

    /// Called from the secondary stream's queue.
    func offerSecondary(_ pixels: CVPixelBuffer, at time: CMTime) {
        lock.lock()
        defer { lock.unlock() }
        secondaryBuffer.append((time, pixels))
        if secondaryBuffer.count > ringDepth {
            secondaryBuffer.removeFirst(secondaryBuffer.count - ringDepth)
        }
        // Newest wins: the two streams free-run, so a late arrival with an older
        // timestamp than one already seen must not become the held frame.
        if let last = lastSecondary, CMTimeCompare(time, last.time) <= 0 { return }
        lastSecondary = (time, pixels)
    }

    /// Called from the primary stream's queue. Returns the secondary frame to
    /// composite with, or `nil` when there is nothing usable at all.
    ///
    /// When nothing is inside tolerance the **previous** secondary frame is
    /// returned rather than `nil`, for up to `maximumHold`.
    ///
    /// That reuse is the whole point of this type. `nil` makes the compositor
    /// clear `hasSecondary`, and the shader then draws the primary edge to edge
    /// — the overlay, its rounded mask and its stroke all vanish for exactly
    /// that one frame. Scattered through a take at 30 fps this is what the
    /// overlay blinking on and off actually *is*: not a camera dropping out, but
    /// single frames failing to find a partner within one frame of skew, which
    /// happens routinely after a lens switch, under thermal frame-rate drift, or
    /// whenever the two modules' phase slips. A 33 ms-old overlay is
    /// indistinguishable to the eye; a missing one is a flash.
    func matchSecondary(for primaryTime: CMTime) -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }

        var best: (time: CMTime, pixels: CVPixelBuffer)?
        var bestDelta = CMTime.positiveInfinity

        for candidate in secondaryBuffer {
            let delta = CMTimeAbsoluteValue(CMTimeSubtract(candidate.time, primaryTime))
            if CMTimeCompare(delta, bestDelta) < 0 {
                bestDelta = delta
                best = candidate
            }
        }

        if let best, CMTimeCompare(bestDelta, tolerance) <= 0 {
            pairedCount += 1
            return best.pixels
        }

        unpairedCount += 1

        guard let held = lastSecondary else { return nil }
        let age = CMTimeAbsoluteValue(CMTimeSubtract(primaryTime, held.time))
        guard CMTimeCompare(age, maximumHold) <= 0 else { return nil }

        heldCount += 1
        return held.pixels
    }

    /// Drops every buffered frame. For a session rebuild, where the frames in
    /// hand came from a lens that no longer exists.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        secondaryBuffer.removeAll(keepingCapacity: true)
        lastSecondary = nil
        resetCountsLocked()
    }

    /// Zeroes the counters and keeps the frames.
    ///
    /// This is what the start of a recording wants. The secondary stream has
    /// been running and offering frames the whole time the user was framing the
    /// shot, so throwing them away would guarantee the take's first frames have
    /// no overlay — the overlay arriving a beat late at the top of every clip.
    func resetStatistics() {
        lock.lock()
        defer { lock.unlock() }
        resetCountsLocked()
    }

    private func resetCountsLocked() {
        pairedCount = 0
        unpairedCount = 0
        heldCount = 0
    }

    /// Fraction of primary frames that found no partner — the number Doc 3
    /// Phase 2's "<0.1% frame drops" criterion is measured against.
    var unpairedFraction: Double {
        let total = pairedCount + unpairedCount
        return total == 0 ? 0 : Double(unpairedCount) / Double(total)
    }

    /// Fraction of primary frames that reached the compositor with **no**
    /// overlay — the ones the viewer sees as a blink. Held frames are excluded
    /// because they are not visible as anything.
    var blankFraction: Double {
        let total = pairedCount + unpairedCount
        return total == 0 ? 0 : Double(unpairedCount - heldCount) / Double(total)
    }
}
