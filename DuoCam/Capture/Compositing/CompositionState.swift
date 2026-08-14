import CoreGraphics
import Foundation

/// The slice of compositor state that the sample-buffer queues read.
///
/// The engine is `@MainActor`, but frames arrive on two dedicated serial
/// queues that must never hop to main — Doc 3's cross-phase concurrency rules
/// and the 0-main-thread-hitches performance budget both forbid it. So
/// everything a frame callback needs lives here instead, behind one lock, and
/// the main actor writes into it whenever the composition changes.
///
/// A lock rather than an actor on purpose: a frame callback cannot `await`, and
/// making it try would reintroduce the hop this type exists to avoid.
final class CompositionState: @unchecked Sendable {
    private let lock = NSLock()

    private var _uniforms = CompositionUniforms()
    private var _outputSize = CGSize(width: 1080, height: 1920)
    private var _compositor: MetalCompositor?

    var uniforms: CompositionUniforms {
        get { lock.withLock { _uniforms } }
        set { lock.withLock { _uniforms = newValue } }
    }

    var outputSize: CGSize {
        get { lock.withLock { _outputSize } }
        set { lock.withLock { _outputSize = newValue } }
    }

    var compositor: MetalCompositor? {
        get { lock.withLock { _compositor } }
        set { lock.withLock { _compositor = newValue } }
    }

    /// One lock acquisition per frame instead of three.
    func snapshot() -> (uniforms: CompositionUniforms, outputSize: CGSize, compositor: MetalCompositor?) {
        lock.withLock { (_uniforms, _outputSize, _compositor) }
    }

    func update(uniforms: CompositionUniforms, outputSize: CGSize) {
        lock.withLock {
            _uniforms = uniforms
            _outputSize = outputSize
        }
    }
}
