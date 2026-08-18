import AVFoundation
import CoreMedia
import os
import QuartzCore
import SwiftUI
import UIKit

/// A capture engine that draws synthetic frames instead of reading a camera.
///
/// This is not a stub — it is the reason the interface can be built and
/// verified at all. `AVCaptureMultiCamSession` cannot run in the simulator, so
/// without a substitute every screen in Document 2 would be unreviewable until
/// a physical device was in hand.
///
/// The two streams are drawn deliberately *differently*: distinct hues, a
/// moving element, and a large role label. That makes swap, mirroring, and
/// layout transitions verifiable by eye — a pair of identical grey rectangles
/// would let a broken swap look correct.
@MainActor
@Observable
final class SimulatedCaptureEngine: CaptureEngine {
    private(set) var status: CaptureEngineStatus = .idle
    private(set) var negotiatedQuality: NegotiatedQuality = .placeholder
    private(set) var configuration: CaptureConfiguration = .default

    let events: AsyncStream<CaptureEngineEvent>
    private let continuation: AsyncStream<CaptureEngineEvent>.Continuation

    private var sources: [StreamRole: PreviewSource] = [:]
    private var animators: [StreamRole: SyntheticStreamLayer] = [:]

    // MARK: Recording pipeline — the same types the hardware path uses

    /// Sensor-native dimensions for the synthetic streams. Landscape, matching
    /// what a real camera delivers, so the aspect-fill maths is exercised
    /// rather than trivially satisfied.
    nonisolated static let syntheticSize = CGSize(width: 1280, height: 720)

    nonisolated private let recorder = RecordingController()
    nonisolated private let pairer = FramePairer()
    nonisolated private let compositionState = CompositionState()
    nonisolated private let frameSource = SyntheticFrameSource(size: syntheticSize)

    private var composition = CompositionParameters()
    /// Frame production runs off the main actor for the same reason the real
    /// path does: `MetalCompositor.composite` waits on the GPU, and doing that
    /// on the main run loop starves the writer and drops frames — 11% of them,
    /// measured, before this queue existed.
    nonisolated private let frameQueue = DispatchQueue(
        label: "com.altzet.DuoCam.synthetic", qos: .userInitiated
    )
    nonisolated private let frameTimerBox = SyntheticTimerBox()

    init() {
        (events, continuation) = AsyncStream.makeStream()
    }

    deinit {
        continuation.finish()
    }

    // MARK: Lifecycle

    func start() async {
        guard status != .running else { return }
        emit(.statusChanged(.configuring))

        rebuildStreams()

        // A real session takes real time to come up; matching that here keeps
        // the launch transition honest rather than suspiciously instant.
        try? await Task.sleep(for: .milliseconds(120))

        negotiatedQuality = NegotiatedQuality(
            resolution: configuration.quality.resolution,
            frameRate: configuration.quality.frameRate,
            hardwareCost: configuration.mode.isDual ? 0.74 : 0.31
        )
        emit(.qualityNegotiated(negotiatedQuality))
        emit(.statusChanged(.running))
        Log.capture.info("Simulated engine running · mode=\(self.configuration.mode.rawValue, privacy: .public)")
    }

    func stop() async {
        animators.values.forEach { $0.stopAnimating() }
        emit(.statusChanged(.idle))
    }

    func apply(_ newConfiguration: CaptureConfiguration) async {
        let previous = configuration
        let needsRebuild = newConfiguration.requiresSessionReconfiguration(comparedTo: previous)
        configuration = newConfiguration

        guard needsRebuild else {
            remapRoles(from: previous)
            // The synthetic frame scales by this, so a zoom change is visible in
            // the simulator too — which is the only place the pills can be
            // exercised at all.
            animators[.primary]?.zoom = newConfiguration.primaryZoom
            return
        }

        emit(.statusChanged(.configuring))
        rebuildStreams()
        animators[.primary]?.zoom = newConfiguration.primaryZoom
        try? await Task.sleep(for: .milliseconds(80))

        negotiatedQuality = NegotiatedQuality(
            resolution: newConfiguration.quality.resolution,
            frameRate: newConfiguration.quality.frameRate,
            hardwareCost: newConfiguration.mode.isDual ? 0.74 : 0.31
        )
        emit(.qualityNegotiated(negotiatedQuality))
        emit(.statusChanged(.running))
    }

    // MARK: Previews

    func previewSource(for role: StreamRole) -> PreviewSource? {
        sources[role]
    }

    /// The simulated counterpart to the hardware engine's role remap.
    ///
    /// A swap needs no session work in either engine, but both still have to
    /// move the two live streams between roles — that is what the swap *is*.
    /// Modelling it here is what lets the control be verified at all, since
    /// multi-cam cannot run in the simulator.
    private func remapRoles(from previous: CaptureConfiguration) {
        guard previous.primarySource == configuration.secondarySource,
              previous.secondarySource == configuration.primarySource,
              let primary = animators[.primary],
              let secondary = animators[.secondary]
        else { return }

        let carried = sources
        animators[.primary] = secondary
        animators[.secondary] = primary
        sources[.primary] = carried[.secondary]
        sources[.secondary] = carried[.primary]

        // Each synthetic frame names the role it is filling, so the labels have
        // to follow the layers into their new slots.
        secondary.configure(role: .primary, source: configuration.primarySource)
        primary.configure(role: .secondary, source: configuration.secondarySource ?? .front)
    }

    private func rebuildStreams() {
        let roles: [StreamRole] = configuration.mode.isDual ? [.primary, .secondary] : [.primary]

        // Drop streams the new mode no longer has, so Single mode does not keep
        // a stale secondary layer alive behind the scenes.
        for role in StreamRole.allCases where !roles.contains(role) {
            animators[role]?.stopAnimating()
            animators[role] = nil
            sources[role] = nil
        }

        for role in roles {
            let source = role == .primary
                ? configuration.primarySource
                : (configuration.secondarySource ?? .front)

            if let existing = animators[role] {
                existing.configure(role: role, source: source)
            } else {
                let layer = SyntheticStreamLayer()
                layer.configure(role: role, source: source)
                layer.startAnimating()
                animators[role] = layer
                sources[role] = PreviewSource(layer: layer)
            }
        }
    }

    // MARK: Controls — recorded so the UI can prove it wired them up

    func focusAndExpose(at point: CGPoint, in role: StreamRole) {
        Log.capture.debug("Simulated focus \(role.rawValue, privacy: .public) at \(point.x), \(point.y)")
    }

    func lockFocusAndExposure(at point: CGPoint, in role: StreamRole) {
        Log.capture.debug("Simulated AE/AF lock \(role.rawValue, privacy: .public)")
    }

    func resetFocusAndExposure(in role: StreamRole) {
        Log.capture.debug("Simulated focus reset \(role.rawValue, privacy: .public)")
    }

    func setZoomFactor(_ factor: CGFloat, for role: StreamRole, ramped: Bool) {
        animators[role]?.zoom = factor
    }

    func setExposureBias(_ bias: Float, for role: StreamRole) {
        animators[role]?.exposureBias = CGFloat(bias)
    }

    func availableZoomStops(for role: StreamRole) -> [ZoomStop] {
        let source = role == .primary
            ? configuration.primarySource
            : (configuration.secondarySource ?? .front)

        return switch source {
        case .front: [ZoomStop(label: "1x", zoomFactor: 1, source: .front)]
        case .rearUltraWide, .rearWide, .rearTelephoto:
            [
                ZoomStop(label: "0.5x", zoomFactor: 0.5, source: .rearUltraWide),
                ZoomStop(label: "1x", zoomFactor: 1, source: .rearWide),
                ZoomStop(label: "3x", zoomFactor: 3, source: .rearTelephoto),
            ]
        }
    }

    // MARK: Recording
    //
    // The simulated engine records for real. It renders genuine pixel buffers
    // and pushes them through the same `MetalCompositor`, `FramePairer` and
    // `RecordingController` the hardware path uses, so a file produced here is
    // produced by the production pipeline — only the photons are fake.

    var recordingState: RecordingController.State { recorder.state }
    var unpairedFrameFraction: Double { pairer.unpairedFraction }

    func updateComposition(_ parameters: CompositionParameters) {
        composition = parameters
        refreshUniforms()
    }

    /// Renders one synthetic frame through the real compositor and encodes it,
    /// so the photo path is exercised rather than stubbed.
    func capturePhoto() async throws -> PhotoResult {
        if compositionState.compositor == nil {
            compositionState.compositor = try MetalCompositor()
        }
        refreshUniforms()

        let phase = CACurrentMediaTime()
        guard let primary = frameSource.render(
            role: .primary, source: configuration.primarySource, phase: phase
        ) else { throw PhotoError.noOutput }

        let secondary = (configuration.mode.isDual ? configuration.secondarySource : nil)
            .flatMap { frameSource.render(role: .secondary, source: $0, phase: phase) }

        let (uniforms, size, compositor) = compositionState.snapshot()
        guard let compositor,
              let composited = compositor.composite(
                  primary: primary, secondary: secondary, uniforms: uniforms, outputSize: size
              ),
              let data = SyntheticFrameSource.jpegData(from: composited)
        else { throw PhotoError.compositingFailed }

        return PhotoResult(
            jpegData: data,
            width: CVPixelBufferGetWidth(composited),
            height: CVPixelBufferGetHeight(composited)
        )
    }

    func setManualControl(_ control: ManualControl, for role: StreamRole) {
        if case .exposureBias(let bias) = control {
            animators[role]?.exposureBias = CGFloat(bias)
        }
        Log.capture.debug("Simulated manual control \(String(describing: control), privacy: .public)")
    }

    /// Modelled rather than hard-coded `false`, so the torch control's enabled
    /// and refused states are both reviewable in the simulator.
    var isTorchAvailable: Bool {
        configuration.primarySource.position == .back
    }

    func setTorch(enabled: Bool, level: Float) {
        Log.capture.debug("Simulated torch \(enabled) at \(level)")
    }

    func setSource(_ source: CameraSource, for role: StreamRole) async {
        var updated = configuration
        switch role {
        case .primary: updated.primarySource = source
        case .secondary: updated.secondarySource = source
        }
        await apply(updated)
    }

    func startRecording() async throws -> URL {
        let free = RecordingController.availableBytes()
        guard free > 100_000_000 else { throw RecordingError.insufficientStorage(free) }

        if compositionState.compositor == nil {
            compositionState.compositor = try MetalCompositor()
        }
        pairer.reset()
        pairer.updateFrameRate(configuration.quality.frameRate)
        refreshUniforms()
        startFrameProduction()

        return try recorder.start(
            outputSize: outputSize,
            quality: configuration.quality,
            hasAudio: false
        )
    }

    func stopRecording() async -> RecordingResult? {
        frameTimerBox.cancel()
        return await recorder.finish()
    }

    func pauseRecording() {
        recorder.pause(at: CMClockGetTime(CMClockGetHostTimeClock()))
    }

    func resumeRecording() {
        recorder.resume(at: CMClockGetTime(CMClockGetHostTimeClock()))
    }

    /// Drives the pipeline at the configured frame rate.
    ///
    /// A `Timer` rather than a `CADisplayLink`: the display link is tied to the
    /// screen refresh rate, which on a 120 Hz device would produce frames at
    /// twice the rate the writer expects.
    private func startFrameProduction() {
        let interval = 1.0 / Double(configuration.quality.frameRate.rawValue)
        let start = CACurrentMediaTime()
        let primarySource = configuration.primarySource
        let secondarySource = configuration.mode.isDual ? configuration.secondarySource : nil

        let timer = DispatchSource.makeTimerSource(queue: frameQueue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            self?.produceFrame(
                start: start,
                primarySource: primarySource,
                secondarySource: secondarySource
            )
        }
        frameTimerBox.replace(with: timer)
        timer.resume()
    }

    nonisolated private func produceFrame(
        start: CFTimeInterval,
        primarySource: CameraSource,
        secondarySource: CameraSource?
    ) {
        guard recorder.state == .recording else { return }

        let elapsed = CACurrentMediaTime() - start
        let time = CMTime(seconds: elapsed, preferredTimescale: 600)

        if let secondarySource,
           let secondary = frameSource.render(role: .secondary, source: secondarySource, phase: elapsed) {
            pairer.offerSecondary(secondary, at: time)
        }

        guard let primary = frameSource.render(
            role: .primary,
            source: primarySource,
            phase: elapsed
        ) else { return }

        let (uniforms, size, compositor) = compositionState.snapshot()
        guard let compositor else { return }

        compositor.compositeAsync(
            primary: primary,
            secondary: pairer.matchSecondary(for: time),
            uniforms: uniforms,
            outputSize: size
        ) { [recorder] composited in
            guard let composited else { return }
            recorder.appendVideo(composited, at: time)
        }
    }

    private func refreshUniforms() {
        let secondarySource = configuration.mode.isDual ? configuration.secondarySource : nil

        let inputs = CompositionUniforms.Inputs(
            layout: composition.layout,
            outputSize: outputSize,
            primaryTextureSize: Self.syntheticSize,
            secondaryTextureSize: Self.syntheticSize,
            // Synthetic frames are already rendered upright, so no rotation is
            // needed — unlike a real sensor, which always delivers landscape.
            primaryRotation: 0,
            secondaryRotation: 0,
            primaryIsMirrored: configuration.primarySource.prefersMirroring && configuration.mirrorsFrontCamera,
            secondaryIsMirrored: (secondarySource?.prefersMirroring ?? false) && configuration.mirrorsFrontCamera,
            primaryFormat: .bgra,
            secondaryFormat: .bgra,
            hasSecondary: secondarySource != nil,
            overlayCentre: composition.overlayCentre,
            overlayWidthFraction: composition.overlayWidthFraction,
            splitRatio: composition.splitRatio,
            diagonalAngle: composition.diagonalAngle
        )

        compositionState.update(uniforms: CompositionUniforms(inputs), outputSize: outputSize)
    }

    private var outputSize: CGSize {
        let dims = configuration.quality.resolution.dimensions
        return CGSize(width: CGFloat(dims.height), height: CGFloat(dims.width))
    }

    // MARK: Emit

    private func emit(_ event: CaptureEngineEvent) {
        if case .statusChanged(let newStatus) = event { status = newStatus }
        continuation.yield(event)
    }
}

// MARK: - The synthetic frame

/// Draws a moving, obviously-fake "scene" so stream identity is unmistakable.
///
/// A `CALayer` rather than a SwiftUI view on purpose: it goes through exactly
/// the same `CameraPreviewView` hosting path as `AVCaptureVideoPreviewLayer`,
/// so the simulator exercises the real preview plumbing rather than a parallel
/// one that could diverge.
@MainActor
final class SyntheticStreamLayer: CALayer {
    private let gradient = CAGradientLayer()
    private let orbit = CAShapeLayer()
    private let grid = CAShapeLayer()
    private let label = CATextLayer()

    var zoom: CGFloat = 1 {
        didSet { setNeedsLayout() }
    }
    var exposureBias: CGFloat = 0 {
        didSet { gradient.opacity = Float(1 + exposureBias * 0.15) }
    }

    private var role: StreamRole = .primary
    private var source: CameraSource = .rearWide

    override init() {
        super.init()
        buildSublayers()
    }

    override init(layer: Any) {
        super.init(layer: layer)
        buildSublayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildSublayers()
    }

    private func buildSublayers() {
        masksToBounds = true

        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        addSublayer(gradient)

        grid.strokeColor = UIColor.white.withAlphaComponent(0.10).cgColor
        grid.lineWidth = 1
        grid.fillColor = nil
        addSublayer(grid)

        orbit.fillColor = UIColor.white.withAlphaComponent(0.85).cgColor
        addSublayer(orbit)

        label.alignmentMode = .center
        label.foregroundColor = UIColor.white.withAlphaComponent(0.55).cgColor
        label.fontSize = 15
        label.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        addSublayer(label)
    }

    func configure(role: StreamRole, source: CameraSource) {
        self.role = role
        self.source = source

        gradient.colors = Self.palette(for: source).map(\.cgColor)
        label.string = "\(source.displayName.uppercased())  ·  \(role.displayName.uppercased())"
        setNeedsLayout()
    }

    /// Distinct hues per lens so a mis-wired stream is obvious at a glance.
    private static func palette(for source: CameraSource) -> [UIColor] {
        switch source {
        case .front:
            [UIColor(red: 0.98, green: 0.55, blue: 0.42, alpha: 1),
             UIColor(red: 0.44, green: 0.16, blue: 0.40, alpha: 1)]
        case .rearWide:
            [UIColor(red: 0.18, green: 0.52, blue: 0.78, alpha: 1),
             UIColor(red: 0.05, green: 0.14, blue: 0.30, alpha: 1)]
        case .rearUltraWide:
            [UIColor(red: 0.22, green: 0.70, blue: 0.60, alpha: 1),
             UIColor(red: 0.04, green: 0.22, blue: 0.26, alpha: 1)]
        case .rearTelephoto:
            [UIColor(red: 0.78, green: 0.66, blue: 0.24, alpha: 1),
             UIColor(red: 0.28, green: 0.16, blue: 0.04, alpha: 1)]
        }
    }

    func startAnimating() {
        guard orbit.animation(forKey: "orbit") == nil else { return }
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = Double.pi * 2
        rotation.duration = role == .primary ? 6 : 4
        rotation.repeatCount = .infinity
        orbit.add(rotation, forKey: "orbit")
    }

    func stopAnimating() {
        orbit.removeAnimation(forKey: "orbit")
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        // Sublayer frame changes would otherwise animate on every bounds
        // change, which reads as the preview sloshing during rotation.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        gradient.frame = bounds
        grid.frame = bounds
        grid.path = Self.gridPath(in: bounds)

        let side = min(bounds.width, bounds.height) * 0.22 * zoom
        orbit.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        orbit.position = CGPoint(x: bounds.midX, y: bounds.midY)
        orbit.path = Self.orbitPath(side: side)

        // Kept in the upper third: at the bottom it lands underneath the
        // control row and muddles every screenshot of the real chrome.
        label.frame = CGRect(
            x: 0, y: bounds.minY + bounds.height * 0.22, width: bounds.width, height: 20
        )
        label.contentsScale = UIScreen.main.scale
    }

    private static func gridPath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let step: CGFloat = 44
        stride(from: 0, through: rect.width, by: step).forEach {
            path.move(to: CGPoint(x: $0, y: 0))
            path.addLine(to: CGPoint(x: $0, y: rect.height))
        }
        stride(from: 0, through: rect.height, by: step).forEach {
            path.move(to: CGPoint(x: 0, y: $0))
            path.addLine(to: CGPoint(x: rect.width, y: $0))
        }
        return path
    }

    /// A lopsided shape rather than a circle — a rotating circle looks static,
    /// which would make it useless as proof that the stream is live.
    private static func orbitPath(side: CGFloat) -> CGPath {
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY * 1.4))
        path.closeSubpath()
        return path
    }
}


/// Holds the frame-production timer so a `nonisolated` context can cancel it.
///
/// `DispatchSourceTimer` is not `Sendable`, and the timer is created on the
/// main actor but cancelled from wherever recording stops.
final class SyntheticTimerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?

    func replace(with newTimer: DispatchSourceTimer) {
        lock.withLock {
            timer?.cancel()
            timer = newTimer
        }
    }

    func cancel() {
        lock.withLock {
            timer?.cancel()
            timer = nil
        }
    }
}
