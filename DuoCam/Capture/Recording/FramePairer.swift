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

    /// Depth 3 covers a full frame of skew in either direction plus a spare.
    /// Deeper would add latency; shallower would drop pairs during jitter.
    private let ringDepth = 3

    private(set) var pairedCount = 0
    private(set) var unpairedCount = 0

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
    }

    /// Called from the primary stream's queue. Returns the secondary frame to
    /// composite with, or `nil` when nothing is close enough.
    ///
    /// A `nil` here is not an error: it happens for the first frame or two of a
    /// session and during a lens switch. The caller composites primary-only
    /// rather than dropping the frame, because a dropped frame is a gap in the
    /// recording and a missing overlay is not.
    func matchSecondary(for primaryTime: CMTime) -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }

        guard !secondaryBuffer.isEmpty else {
            unpairedCount += 1
            return nil
        }

        var best: (time: CMTime, pixels: CVPixelBuffer)?
        var bestDelta = CMTime.positiveInfinity

        for candidate in secondaryBuffer {
            let delta = CMTimeAbsoluteValue(CMTimeSubtract(candidate.time, primaryTime))
            if CMTimeCompare(delta, bestDelta) < 0 {
                bestDelta = delta
                best = candidate
            }
        }

        guard let best, CMTimeCompare(bestDelta, tolerance) <= 0 else {
            unpairedCount += 1
            return nil
        }

        pairedCount += 1
        return best.pixels
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        secondaryBuffer.removeAll(keepingCapacity: true)
        pairedCount = 0
        unpairedCount = 0
    }

    /// Fraction of primary frames that found no partner — the number Doc 3
    /// Phase 2's "<0.1% frame drops" criterion is measured against.
    var unpairedFraction: Double {
        let total = pairedCount + unpairedCount
        return total == 0 ? 0 : Double(unpairedCount) / Double(total)
    }
}
