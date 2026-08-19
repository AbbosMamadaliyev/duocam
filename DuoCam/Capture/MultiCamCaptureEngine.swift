import AVFoundation
import CoreImage
import os
import QuartzCore
import UIKit

/// The real capture layer: `AVCaptureMultiCamSession` with a hand-built
/// connection graph.
///
/// Doc 3 Phase 1 calls the connection graph *"the single most error-prone part
/// of the project"*, and Doc 1 §5.3.1 explains why: in a multi-cam session,
/// `addInput(_:)` and `addOutput(_:)` **silently fail** to create working
/// connections. Every connection here is constructed explicitly, including the
/// ones for preview layers.
///
/// All session mutation happens on `sessionQueue`. The class is `@MainActor`
/// so the UI can read its published state directly, and it never performs
/// session work on that actor.
@MainActor
@Observable
final class MultiCamCaptureEngine: CaptureEngine {
    private(set) var status: CaptureEngineStatus = .idle
    private(set) var negotiatedQuality: NegotiatedQuality = .placeholder
    private(set) var configuration: CaptureConfiguration

    let events: AsyncStream<CaptureEngineEvent>
    private let continuation: AsyncStream<CaptureEngineEvent>.Continuation

    /// Doc 3 cross-phase rule 1: one dedicated serial queue, never main.
    private let sessionQueue = DispatchQueue(label: "com.altzet.DuoCam.session", qos: .userInitiated)
    private let session = AVCaptureMultiCamSession()

    private var streams: [StreamRole: Stream] = [:]
    private var sources: [StreamRole: PreviewSource] = [:]
    /// Preview layers outlive the connection graph that feeds them.
    ///
    /// A rebuilt session used to hand back brand-new layers, and a fresh
    /// `AVCaptureVideoPreviewLayer` is empty — so every lens change flashed the
    /// whole screen black before the new lens delivered its first frame. Keeping
    /// the layer means it holds its last frame across the switch, which is what
    /// the system camera does and what "smooth" actually looks like.
    private var previewLayers: [StreamRole: AVCaptureVideoPreviewLayer] = [:]
    private var rotationCoordinators: [StreamRole: AVCaptureDevice.RotationCoordinator] = [:]
    private var observers: [NSObjectProtocol] = []
    private var rotationObservations: [NSKeyValueObservation] = []

    /// What each rear lens magnifies by, measured against the wide lens.
    ///
    /// Probed once — see `rearLensFactors()` — because it is hardware, not a
    /// constant: the telephoto is 3× on one phone and 5× on the next, and a
    /// hard-coded 3 makes every handoff to it jump by the difference.
    private let lensFactors: [CameraSource: CGFloat]

    /// Every set of cameras this hardware will run simultaneously, by unique ID.
    /// Probed once — it is a property of the phone, not of the session.
    private let multiCamDeviceSets: [Set<String>]

    /// The last frame each stream delivered, kept to cover a lens change.
    /// One buffer per role, replaced as frames arrive. See `installFreezeCover`.
    nonisolated private let lastFrames = LastFrameStore()

    /// Built on first use and kept: constructing a `CIContext` is expensive and
    /// a lens change cannot afford it. `@ObservationIgnored` because no view
    /// reads it, and `lazy` is unavailable in an `@Observable` class.
    @ObservationIgnored private var freezeContext: CIContext?

    /// Powers of two per second for every zoom ramp the engine performs.
    /// 1× → 3× lands in ~0.32 s, which is close to what the system camera
    /// spends crossing the same distance.
    nonisolated private static let zoomRampRate: Float = 5
    /// No single ramp may outlast this, however far it has to travel.
    nonisolated private static let maximumRampDuration: TimeInterval = 0.5
    /// How long the frozen frame takes to give way to the live one.
    nonisolated private static let coverFadeDuration: TimeInterval = 0.16
    /// Long edge of the frozen frame, in pixels. Beyond a screen's worth of
    /// detail, a picture shown for a fifth of a second is paying for nothing.
    nonisolated private static let coverPixelWidth: CGFloat = 1440

    /// The lens change currently in flight. See `switchSource`.
    @ObservationIgnored private var sourceSwitch: Task<Void, Never>?

    /// What the last few device changes actually did, newest last.
    ///
    /// A switch either replaced one stream in place or fell back to rebuilding
    /// the whole session, and the difference is invisible from outside except
    /// as the other stream blinking. Kept so the self-check can say which
    /// happened rather than leaving it to be inferred from a preview.
    @ObservationIgnored private var switchTrace: [String] = []
    /// Session-level runtime errors, which are otherwise silent.
    @ObservationIgnored private var runtimeErrors: [String] = []

    // MARK: Recording pipeline

    nonisolated private let recorder = RecordingController()
    nonisolated private let pairer = FramePairer()
    /// Everything the frame callbacks touch. See `CompositionState`.
    nonisolated private let compositionState = CompositionState()
    /// Per-role arrival counts. A stream that silently delivers nothing looks
    /// identical to one that delivers frames nothing pairs with, and the two
    /// have completely different causes.
    nonisolated private let frameCounters = FrameCounters()
    nonisolated private let cleanRecorder = CleanSourceRecorder()
    nonisolated private let photoController: PhotoCaptureController
    let governor = ThermalGovernor()

    private var composition = CompositionParameters()

    /// One queue per stream — Doc 3 cross-phase rule: never shared.
    private let primaryQueue = DispatchQueue(label: "com.altzet.DuoCam.stream.primary", qos: .userInitiated)
    private let secondaryQueue = DispatchQueue(label: "com.altzet.DuoCam.stream.secondary", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "com.altzet.DuoCam.audio", qos: .userInitiated)

    private var streamHandlers: [StreamRole: StreamOutputHandler] = [:]
    private var audioHandler: AudioOutputHandler?
    /// Present whenever the session carries a working microphone connection.
    ///
    /// Built with the rest of the graph rather than at record time — see
    /// `buildSession` — so `startRecording` performs no session work at all.
    private var audioOutput: AVCaptureAudioDataOutput?

    var recordingState: RecordingController.State { recorder.state }
    var unpairedFrameFraction: Double { pairer.unpairedFraction }

    /// Everything belonging to one live stream.
    private struct Stream {
        let source: CameraSource
        let device: AVCaptureDevice
        let input: AVCaptureDeviceInput
        let previewLayer: AVCaptureVideoPreviewLayer
        /// The device zoom factor that shows the wide lens's own frame.
        ///
        /// One number that makes every device speak the same language. A
        /// discrete wide is 1; a discrete ultra wide is 2, because its own 1.0
        /// is half a wide frame; a triple camera is also 2, because its 1.0 is
        /// its ultra wide. Multiply the magnification the user asked for by this
        /// and the device has its answer, whatever it is made of.
        var zoomScale: CGFloat = 1
        /// A virtual device changes lens by itself, inside AVFoundation, with no
        /// session work and no gap. Worth knowing, because it is the difference
        /// between a zoom that is one ramp and a zoom that is a rebuild.
        var isVirtual: Bool = false
        var dataOutput: AVCaptureVideoDataOutput?
        var photoOutput: AVCapturePhotoOutput?
        var textureSize: CGSize = .zero
        var rotationDegrees: Double = 90
        var isMirrored: Bool = false
    }

    init(configuration: CaptureConfiguration = .default) {
        self.configuration = configuration
        self.lensFactors = Self.rearLensFactors()
        self.multiCamDeviceSets = Self.supportedDeviceSets()
        // `lazy` is unavailable inside an `@Observable` class, so the
        // controller is built here rather than on first use.
        self.photoController = PhotoCaptureController(compositionState: compositionState)
        (events, continuation) = AsyncStream.makeStream()
        registerInterruptionObservers()
        registerMemoryPressureObserver()
        wireGovernor()
    }

    /// Doc 3 Phase 2 tasks 12–15: the ladder is applied by the engine, and the
    /// user sees one toast and an updated quality pill — never a dialog.
    private func wireGovernor() {
        governor.onStepChanged = { [weak self] step in
            guard let self else { return }
            if step == .stopRecording {
                Task { _ = await self.stopRecording() }
                return
            }
            // Doc 3 Phase 4 task 22: shed the clean sources before touching
            // anything the user is actually watching.
            if step >= .secondaryResolution, self.cleanRecorder.isRecording {
                self.cleanRecorder.abandon()
                return
            }
            Task { await self.applyDegradation(step) }
        }
        governor.onUserVisibleDegradation = { [weak self] reason in
            self?.emit(.degraded(reason))
        }
    }

    /// Re-negotiates formats under the governor's current step.
    ///
    /// Reconfiguring mid-recording is legitimate here precisely because the
    /// alternative is iOS terminating the session (Doc 1 §5.3.8): a visible
    /// quality drop beats a lost take.
    private func applyDegradation(_ step: ThermalGovernor.Step) async {
        var degraded = configuration
        degraded.quality = governor.degraded(configuration.quality)
        guard degraded.quality != configuration.quality else { return }

        do {
            let result = try await configureSession(for: degraded)
            apply(result)
        } catch {
            Log.thermal.error("Degradation step \(step.rawValue) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    deinit {
        continuation.finish()
    }

    // MARK: Lifecycle

    func start() async {
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            emit(.statusChanged(.failed(message: CaptureError.multiCamUnsupported.localizedDescription)))
            return
        }

        emit(.statusChanged(.configuring))

        // Before the graph is built, not when the shutter is pressed. Activating
        // the audio session changes the route, and a route change on a *running*
        // capture session pauses both video streams for the best part of a
        // second — which, done at record time, is the first second of the take.
        AudioSessionConfigurator.configureForRecording()
        AudioSessionConfigurator.selectDataSource(matching: configuration.primarySource.position)

        do {
            let result = try await configureSession(for: configuration)
            apply(result)
            // Compiling the Metal pipeline and allocating the output pool takes
            // tens of milliseconds. Paying that here means the first frame of a
            // recording is composited by a warm compositor rather than being the
            // one that builds it.
            if compositionState.compositor == nil {
                compositionState.compositor = try? MetalCompositor()
            }
            await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
                sessionQueue.async { [session] in
                    if !session.isRunning { session.startRunning() }
                    resume.resume()
                }
            }
            emit(.statusChanged(.running))
        } catch {
            Log.capture.error("Session start failed: \(error.localizedDescription, privacy: .public)")
            emit(.statusChanged(.failed(message: error.localizedDescription)))
        }
    }

    func stop() async {
        await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
            sessionQueue.async { [session] in
                if session.isRunning { session.stopRunning() }
                resume.resume()
            }
        }
        // Released with the session, not after each take: deactivating between
        // recordings forces a route change on the next one, which is the same
        // stall this pipeline moved the audio setup out of `startRecording` to
        // avoid.
        AudioSessionConfigurator.deactivate()
        emit(.statusChanged(.idle))
    }

    func apply(_ newConfiguration: CaptureConfiguration) async {
        let previous = configuration
        let needsReconfiguration = newConfiguration.requiresSessionReconfiguration(comparedTo: previous)
        configuration = newConfiguration

        // Doc 3 Phase 2 task 11: the microphone follows whichever side the
        // primary camera is on. Never while a take is running — this changes the
        // audio route, and a route change mid-recording is a gap in the track.
        if newConfiguration.primarySource.position != previous.primarySource.position,
           recorder.state == .idle {
            AudioSessionConfigurator.selectDataSource(matching: newConfiguration.primarySource.position)
        }

        guard needsReconfiguration else {
            remapRoles(for: newConfiguration)
            applyMirroring()

            // A new canvas shape reaches both the preview and the file through
            // the uniforms, and through nothing else: no input, output or
            // connection changes, so the streams never stop.
            if newConfiguration.aspectRatio != previous.aspectRatio { refreshUniforms() }

            // A magnification can outgrow the device serving it: the dual wide
            // covers 0.5–1×, the dual 1–3×, and asking one of them for the
            // other's half of the range means changing device even though the
            // *source* — "the rear camera" — never changed. Handled by the same
            // path a lens change goes through, which knows how to hand one
            // device to the next without a cut.
            if status.isRunning,
               let primary = streams[.primary],
               let wanted = desiredDeviceID(for: newConfiguration, role: .primary),
               wanted != primary.device.uniqueID {
                await switchSource(to: newConfiguration.primarySource, for: .primary)
                return
            }

            // Reached both by a plain zoom change on the device already on
            // screen and by a swap that moved a differently-zoomed stream into
            // the primary role. Ramped in the first case, because a
            // magnification the user asked for should travel there rather than
            // appear.
            applyZoom(ramped: previous.primarySource == newConfiguration.primarySource)
            return
        }

        // One stream changed lens and the other did not: rebuild only that
        // stream. The full path below tears down *both* streams, so switching
        // the rear lens used to interrupt the front preview as well.
        if status.isRunning,
           let change = Self.singleSourceChange(from: previous, to: newConfiguration),
           streams[change.role] != nil {
            await switchSource(to: change.source, for: change.role)
            return
        }

        emit(.statusChanged(.configuring))
        do {
            let result = try await configureSession(for: newConfiguration)
            apply(result)
            emit(.statusChanged(.running))
        } catch {
            Log.capture.error("Reconfiguration failed: \(error.localizedDescription, privacy: .public)")
            emit(.recoverableFailure(error.localizedDescription))
            emit(.statusChanged(.running))
        }
    }

    /// The one role whose lens changed, when nothing else about the session did.
    ///
    /// A swap is deliberately *not* one of these: it changes both roles at once
    /// and needs no session work at all — see `remapRoles(for:)`.
    nonisolated private static func singleSourceChange(
        from old: CaptureConfiguration,
        to new: CaptureConfiguration
    ) -> (role: StreamRole, source: CameraSource)? {
        guard old.mode == new.mode,
              old.quality.resolution == new.quality.resolution,
              old.quality.frameRate == new.quality.frameRate
        else { return nil }

        let primaryChanged = old.primarySource != new.primarySource
        let secondaryChanged = old.secondarySource != new.secondarySource

        if primaryChanged, !secondaryChanged {
            return (.primary, new.primarySource)
        }
        if secondaryChanged, !primaryChanged, let secondary = new.secondarySource {
            return (.secondary, secondary)
        }
        return nil
    }

    /// Follows a stream swap in the role map.
    ///
    /// Doc 2 §5.6 is right that a swap needs no session reconfiguration — but
    /// the engine still has to move the two live streams between roles, because
    /// *the role is what decides which preview layer the screen shows and which
    /// stream the compositor treats as the background*. Without this the swap
    /// control changed the configuration and nothing else: both previews stayed
    /// exactly where they were, which is how it read as a dead button.
    private func remapRoles(for configuration: CaptureConfiguration) {
        guard let primary = streams[.primary],
              let secondary = streams[.secondary],
              primary.source == configuration.secondarySource,
              secondary.source == configuration.primarySource
        else { return }

        // Written out rather than `swap(&dict[a], &dict[b])`: two subscripts of
        // the same dictionary are overlapping accesses, which traps.
        let carriedSources = sources
        let carriedLayers = previewLayers
        let carriedCoordinators = rotationCoordinators

        streams[.primary] = secondary
        streams[.secondary] = primary
        sources[.primary] = carriedSources[.secondary]
        sources[.secondary] = carriedSources[.primary]
        previewLayers[.primary] = carriedLayers[.secondary]
        previewLayers[.secondary] = carriedLayers[.primary]
        rotationCoordinators[.primary] = carriedCoordinators[.secondary]
        rotationCoordinators[.secondary] = carriedCoordinators[.primary]

        // A swap is legal mid-take, so the frozen angles travel with the streams
        // they belong to rather than staying pinned to the role.
        if !lockedRotations.isEmpty {
            let carriedRotations = lockedRotations
            lockedRotations[.primary] = carriedRotations[.secondary]
            lockedRotations[.secondary] = carriedRotations[.primary]
        }

        // The KVO closures and the sample-buffer delegates both capture a role,
        // so both have to be re-registered against the streams' new roles.
        observeRotation()
        attachOutputHandlers()
        refreshUniforms()
    }

    /// Rebuilds one stream's slice of the connection graph in place.
    ///
    /// Doc 3 Phase 4 task 14's requirement, honoured literally: the other
    /// stream's input, outputs and connections are never touched, and this
    /// stream's preview layer survives, so the switch reads as the lens
    /// changing rather than the session restarting.
    ///
    /// The switch itself is a cut — the incoming lens needs a couple of hundred
    /// milliseconds to deliver anything at all — so three things happen around
    /// it, and together they are what makes a zoom read as a zoom:
    ///
    /// 1. the outgoing lens is ridden digitally to the framing the incoming one
    ///    will start at, so the two never differ in field of view at the moment
    ///    of the handoff;
    /// 2. the last frame of the outgoing lens covers the rebuild, because a
    ///    preview layer whose connection was just removed is black;
    /// 3. the incoming lens is already at the handoff framing before its first
    ///    frame is delivered, and only then ramps on to what was asked for.
    ///
    /// Serialised against itself. A switch now spends the better part of a
    /// second suspended — riding one lens out, waiting for the next to deliver —
    /// and two of them overlapping would each try to retire the same input,
    /// leaving the session with a duplicate of one lens and none of the other.
    /// Tapping three pills in a row runs three switches in order, and each reads
    /// the configuration as it finds it.
    private func switchSource(to source: CameraSource, for role: StreamRole) async {
        let inFlight = sourceSwitch
        let task = Task { @MainActor [weak self] in
            await inFlight?.value
            await self?.performSwitch(to: source, for: role)
        }
        sourceSwitch = task
        await task.value
    }

    private func performSwitch(to source: CameraSource, for role: StreamRole) async {
        guard let previous = streams[role] else { return }

        // What this stream should be running on now — a virtual device covering
        // the magnification in hand, or the lens the source names.
        var wanted = configuration
        if role == .primary { wanted.primarySource = source } else { wanted.secondarySource = source }
        let chosen = desiredDevice(for: wanted, role: role)

        // An earlier switch in the queue may already have arrived here — or the
        // user may have come back to where they started. Either way the graph is
        // right and only the magnification can still be wrong.
        guard previous.device.uniqueID != desiredDeviceID(for: wanted, role: role) else {
            applyZoom(ramped: true)
            return
        }

        // The tier the ladder already settled on, not the requested one: this
        // stream has to fit the budget the other stream is currently spending.
        let resolution = negotiatedQuality.resolution
        let frameRate = negotiatedQuality.frameRate
        let isMultiCam = configuration.mode.isDual

        // The overlay has no zoom control, so a secondary lens change simply
        // wants that lens's own full frame — and riding a lens out to a
        // magnification nobody asked for would only make it soft on the way.
        let target = role == .primary ? configuration.primaryZoom : lensFactor(source)
        // Where the incoming device's own widest frame sits. Riding past it
        // would crop the outgoing lens to something the incoming one shows
        // optically, so this is exactly how far the ride is worth taking.
        let crossover = chosen.map(widestMagnification) ?? lensFactor(source)
        let handoff = role == .primary
            ? await rideOut(previous, toward: crossover, target: target, for: role)
            : target
        let cover = installFreezeCover(for: role)

        // The *other* stream is covered too, and this is not belt and braces.
        // `beginConfiguration`/`commitConfiguration` on a live multi-cam session
        // suspends every stream in it, not only the one being edited — measured
        // at around 0.4 s of lost frames on the front module for a rear device
        // change. Its preview is a connection that briefly has nothing arriving
        // on it, which is to say black, and the overlay going black next to a
        // zoom is exactly what makes the zoom look broken.
        let companionRole: StreamRole = role == .primary ? .secondary : .primary
        let companionCover = installFreezeCover(for: companionRole)

        let initialZoom = max(1, handoff * prospectiveZoomScale(for: chosen, source: source))

        do {
            let stream: Stream = try await withCheckedThrowingContinuation { continuation in
                sessionQueue.async { [session] in
                    do {
                        continuation.resume(returning: try Self.replaceStream(
                            in: session,
                            previous: previous,
                            with: source,
                            resolution: resolution,
                            frameRate: frameRate,
                            isMultiCam: isMultiCam,
                            using: chosen,
                            initialZoom: initialZoom
                        ))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            adopt(stream, for: role)

            // Uncover first, ramp second, and in that order for a reason: the
            // frozen frame cannot follow a ramp, so anything the live picture
            // does underneath it becomes a jump at the moment it fades. The
            // rest of the journey therefore starts once the cover is gone —
            // which is also the only way it can be seen at all.
            //
            // Each stream is uncovered on its own frames: they come back at
            // different times, and holding the one that recovered first until
            // the other catches up would make each switch as slow as its
            // slowest half.
            async let held = uncover(cover, for: role)
            async let companionHeld = uncover(companionCover, for: companionRole)
            let ownHold = await held
            setZoomFactor(deviceZoom(forUser: target, on: role), for: role, ramped: true)
            let companionHold = await companionHeld

            trace("\(previous.device.localizedName)→\(stream.device.localizedName)"
                  + " handoff=\(String(format: "%.2f", handoff))× init=\(String(format: "%.2f", initialZoom))"
                  + " target=\(String(format: "%.2f", target))× in-place"
                  + " covered \(role.rawValue)=\(Self.milliseconds(ownHold))"
                  + " \(companionRole.rawValue)=\(companionCover == nil ? "—" : Self.milliseconds(companionHold))")
        } catch {
            // The targeted path is an optimisation, never the only way through:
            // anything it cannot do — a lens the pairing cannot afford, a device
            // that refuses its format — falls back to the full rebuild, which
            // owns the degradation ladder.
            Log.capture.notice(
                "In-place lens switch to \(source.rawValue, privacy: .public) failed (\(error.localizedDescription, privacy: .public)); rebuilding session"
            )
            trace("\(previous.device.localizedName)→\(chosen?.localizedName ?? source.displayName)"
                  + " handoff=\(String(format: "%.2f", handoff))× init=\(String(format: "%.2f", initialZoom))"
                  + " FELL BACK: \(error.localizedDescription)")
            emit(.statusChanged(.configuring))
            do {
                apply(try await configureSession(for: configuration))
                emit(.statusChanged(.running))
            } catch {
                Log.capture.error("Reconfiguration failed: \(error.localizedDescription, privacy: .public)")
                emit(.recoverableFailure(error.localizedDescription))
                emit(.statusChanged(.running))
            }
            // Held across the fallback too: a full rebuild is a longer blackout
            // than the one it is recovering from, not a shorter one.
            async let uncovered = uncover(cover, for: role)
            async let companionUncovered = uncover(companionCover, for: companionRole)
            _ = await (uncovered, companionUncovered)
        }
    }

    nonisolated private static func milliseconds(_ duration: Duration) -> String {
        "\(Int(duration / .milliseconds(1)))ms"
    }

    /// Records one device change for the self-check. Bounded, newest last.
    private func trace(_ entry: String) {
        switchTrace.append(entry)
        if switchTrace.count > 8 { switchTrace.removeFirst() }
    }

    /// Installs a stream rebuilt by `switchSource` without disturbing the other
    /// role.
    private func adopt(_ stream: Stream, for role: StreamRole) {
        streams[role] = stream
        previewLayers[role] = stream.previewLayer
        if sources[role]?.layer !== stream.previewLayer {
            sources[role] = PreviewSource(layer: stream.previewLayer)
        }

        let coordinator = AVCaptureDevice.RotationCoordinator(
            device: stream.device,
            previewLayer: stream.previewLayer
        )
        rotationCoordinators[role] = coordinator
        streams[role]?.rotationDegrees = Self.compositionRotation(
            coordinator.videoRotationAngleForHorizonLevelPreview
        )

        if role == .secondary { pairer.reset() }

        calibrateZoomScales()
        applyRotation()
        observeRotation()
        applyMirroring()
        attachOutputHandlers()
        refreshUniforms()

        // The frames the old lens left behind are the wrong picture at the
        // wrong size to cover anything from here on.
        lastFrames.clear(role)
    }

    // MARK: Configuration

    /// What a successful configuration produced, carried back to the main actor.
    private struct ConfigurationResult {
        let streams: [StreamRole: Stream]
        let quality: NegotiatedQuality
        /// `nil` when the device has no usable microphone, which degrades to a
        /// silent recording rather than failing the session.
        let audioOutput: AVCaptureAudioDataOutput?
    }

    private func apply(_ result: ConfigurationResult) {
        let carried = sources
        streams = result.streams
        previewLayers = result.streams.mapValues(\.previewLayer)
        // A reused layer keeps its `PreviewSource` box too, so the host view
        // sees the same layer identity and never detaches it mid-switch.
        sources = result.streams.mapValues { stream in
            carried.values.first { $0.layer === stream.previewLayer }
                ?? PreviewSource(layer: stream.previewLayer)
        }
        negotiatedQuality = result.quality

        rotationCoordinators = result.streams.mapValues { stream in
            AVCaptureDevice.RotationCoordinator(
                device: stream.device,
                previewLayer: stream.previewLayer
            )
        }
        for (role, coordinator) in rotationCoordinators {
            streams[role]?.rotationDegrees = Self.compositionRotation(
                coordinator.videoRotationAngleForHorizonLevelPreview
            )
        }
        // The frames in the pairer's hand were produced by a graph that no
        // longer exists, and their dimensions no longer match the uniforms about
        // to be published. Holding one now would paste a frame from the old lens
        // into the overlay.
        pairer.reset()

        applyRotation()
        observeRotation()
        applyMirroring()
        attachOutputHandlers()
        attachAudioHandler(to: result.audioOutput)
        refreshUniforms()

        // Devices remember the zoom the last session left them at, so a rebuild
        // that does not restate it comes back cropped.
        calibrateZoomScales()
        applyZoom(ramped: false, resettingSecondary: true)

        emit(.qualityNegotiated(result.quality))
        if let reason = result.quality.degradationReason {
            emit(.degraded(reason))
        }
    }

    private func configureSession(
        for configuration: CaptureConfiguration
    ) async throws -> ConfigurationResult {
        // Decided here, on the main actor, where the configuration and the
        // hardware's device sets both live — the builder runs on the session
        // queue and is given the answer rather than the question.
        var chosen: [StreamRole: AVCaptureDevice] = [:]
        if let device = desiredDevice(for: configuration, role: .primary) {
            chosen[.primary] = device
        }

        return try await withCheckedThrowingContinuation { [previewLayers] continuation in
            sessionQueue.async { [session] in
                do {
                    let result = try Self.buildSession(
                        session, for: configuration, reusing: previewLayers, using: chosen
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Builds the entire connection graph inside one configuration transaction.
    ///
    /// `nonisolated` and `static` deliberately: this runs on `sessionQueue` and
    /// must not touch main-actor state, so it is given no way to.
    nonisolated private static func buildSession(
        _ session: AVCaptureMultiCamSession,
        for configuration: CaptureConfiguration,
        reusing previewLayers: [StreamRole: AVCaptureVideoPreviewLayer],
        using chosenDevices: [StreamRole: AVCaptureDevice]
    ) throws -> ConfigurationResult {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // Start from a clean graph — leftover inputs from the previous mode
        // would silently inflate hardware cost.
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        session.connections.forEach(session.removeConnection)

        var roles: [(StreamRole, CameraSource)] = [(.primary, configuration.primarySource)]
        if configuration.mode.isDual, let secondary = configuration.secondarySource {
            roles.append((.secondary, secondary))
        }

        var built: [StreamRole: Stream] = [:]

        for (role, source) in roles {
            built[role] = try makeStream(
                in: session,
                for: source,
                reusing: previewLayers[role],
                using: chosenDevices[role]
            )
        }

        // Doc 1 §5.3.3 — only `isMultiCamSupported` formats, enumerated at
        // runtime. Never a hard-coded resolution assumption.
        let quality = try selectFormats(
            session: session,
            streams: built,
            requested: configuration.quality,
            isMultiCam: configuration.mode.isDual
        )

        // Only now is `activeFormat` settled, and the compositor scales by these
        // dimensions — reading them before the ladder ran reported whatever
        // format the device happened to be left in by the previous session.
        for (role, stream) in built {
            built[role]?.textureSize = textureSize(of: stream.device)
        }

        return ConfigurationResult(
            streams: built,
            quality: quality,
            audioOutput: makeAudioOutput(in: session)
        )
    }

    /// Adds the microphone to the graph, inside the caller's configuration
    /// transaction.
    ///
    /// Doc 1 §5.3.6: **one** audio input per session, even with two video
    /// streams. What matters more here is *when* it is added. This used to run
    /// from `startRecording`, on the main actor, against an already-running
    /// session — `beginConfiguration`/`commitConfiguration` on a live multi-cam
    /// session tears its streams down and brings them back up, and the front
    /// module in particular takes seconds to redeliver. The visible result was
    /// exactly the reported symptom: an overlay that was missing for the first
    /// few seconds of every recording and blinked while the stream restabilised.
    /// Building it with the rest of the graph means pressing record performs no
    /// session work whatsoever.
    ///
    /// A missing or rejected microphone returns `nil` and the take is silent —
    /// Doc 3's error rule is to degrade, never to fail.
    nonisolated private static func makeAudioOutput(
        in session: AVCaptureMultiCamSession
    ) -> AVCaptureAudioDataOutput? {
        guard let device = AVCaptureDevice.default(for: .audio) else { return nil }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { return nil }
            session.addInputWithNoConnections(input)

            let output = AVCaptureAudioDataOutput()
            guard session.canAddOutput(output) else { return nil }
            session.addOutputWithNoConnections(output)

            guard let port = input.ports(
                for: .audio, sourceDeviceType: nil, sourceDevicePosition: .unspecified
            ).first else { return nil }

            let connection = AVCaptureConnection(inputPorts: [port], output: output)
            guard session.canAddConnection(connection) else { return nil }
            session.addConnection(connection)

            return output
        } catch {
            Log.recording.error("Audio attach failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Builds one stream's slice of the graph: input, preview connection, data
    /// output, photo output.
    ///
    /// Shared by the full rebuild and the in-place lens switch so the two
    /// cannot drift — a connection graph assembled two slightly different ways
    /// is exactly the failure Doc 3 Phase 1 warns about.
    ///
    /// The outputs are reused when the caller has a pair going spare, which a
    /// lens change always does. Adding an `AVCapturePhotoOutput` to a live
    /// multi-cam session is one of the most expensive things in this file — it
    /// allocates the still pipeline — and doing it inside the transaction that
    /// changes lens is what made a zoom cost the better part of a second of
    /// frames on *both* streams. Only the connections need to change.
    nonisolated private static func makeStream(
        in session: AVCaptureMultiCamSession,
        for source: CameraSource,
        reusing existingPreviewLayer: AVCaptureVideoPreviewLayer?,
        using chosenDevice: AVCaptureDevice? = nil,
        recyclingOutputsFrom retired: Stream? = nil
    ) throws -> Stream {
        // The caller's choice when it has one — a virtual device covering the
        // magnification in hand — and the lens the source names otherwise. See
        // `desiredDevice(for:role:zoom:)`, which is where that is decided.
        guard let device = chosenDevice ?? AVCaptureDevice.default(
            source.deviceType, for: .video, position: source.position
        ) else {
            throw CaptureError.deviceUnavailable(source)
        }

        let input = try AVCaptureDeviceInput(device: device)

        // Doc 1 §5.3.1 — the `WithNoConnections` variant is mandatory.
        guard session.canAddInput(input) else {
            throw CaptureError.connectionRejected("input for \(source.displayName)")
        }
        session.addInputWithNoConnections(input)

        // Doc 1 §5.3.2 — preview layers need manual connections too. The layer
        // itself is reused when there is one: see `previewLayers`.
        let previewLayer = existingPreviewLayer
            ?? AVCaptureVideoPreviewLayer(sessionWithNoConnection: session)
        previewLayer.videoGravity = .resizeAspectFill

        // The device's own type, not the source's: asking a virtual device for
        // one of its constituents' ports would pin the stream to that single
        // lens and throw away the lens switching this was chosen for.
        guard let port = input.ports(
            for: .video,
            sourceDeviceType: device.deviceType,
            sourceDevicePosition: device.position
        ).first else {
            throw CaptureError.connectionRejected("no video port for \(source.displayName)")
        }

        let connection = AVCaptureConnection(inputPort: port, videoPreviewLayer: previewLayer)
        guard session.canAddConnection(connection) else {
            throw CaptureError.connectionRejected("preview connection for \(source.displayName)")
        }
        session.addConnection(connection)

        // A second, independent connection carries the same port to a data
        // output. Doc 2 §15.2: the preview is *not* composited — it is two
        // live layers for lowest latency — so the recording path needs its
        // own tap on the stream rather than a read-back of the screen.
        let dataOutput = retired?.dataOutput ?? AVCaptureVideoDataOutput()
        dataOutput.alwaysDiscardsLateVideoFrames = true
        dataOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]

        if !session.outputs.contains(dataOutput) {
            guard session.canAddOutput(dataOutput) else {
                throw CaptureError.connectionRejected("data output for \(source.displayName)")
            }
            session.addOutputWithNoConnections(dataOutput)
        }

        let dataConnection = AVCaptureConnection(inputPorts: [port], output: dataOutput)
        guard session.canAddConnection(dataConnection) else {
            throw CaptureError.connectionRejected("data connection for \(source.displayName)")
        }
        session.addConnection(dataConnection)

        // The recorded frame must be mirrored the same way the preview is,
        // or a front-camera take plays back reversed from what was framed.
        dataConnection.automaticallyAdjustsVideoMirroring = false
        if dataConnection.isVideoMirroringSupported {
            dataConnection.isVideoMirrored = false
        }

        // Doc 3 Phase 4 task 1: a photo output per stream, also manually
        // connected. Doc 1 §5.3.7 is why nothing else is configured on it —
        // Night Mode, Deep Fusion and ProRAW are all unavailable in
        // multi-cam, so requesting them would fail silently.
        let photoOutput = retired?.photoOutput ?? AVCapturePhotoOutput()
        var attachedPhotoOutput: AVCapturePhotoOutput?
        if session.outputs.contains(photoOutput) || session.canAddOutput(photoOutput) {
            if !session.outputs.contains(photoOutput) {
                session.addOutputWithNoConnections(photoOutput)
            }
            let photoConnection = AVCaptureConnection(inputPorts: [port], output: photoOutput)
            if session.canAddConnection(photoConnection) {
                session.addConnection(photoConnection)
                attachedPhotoOutput = photoOutput
            }
        }

        return Stream(
            source: source,
            device: device,
            input: input,
            previewLayer: previewLayer,
            zoomScale: zoomScale(of: device),
            isVirtual: device.constituentDevices.count > 1,
            dataOutput: dataOutput,
            photoOutput: attachedPhotoOutput,
            textureSize: textureSize(of: device)
        )
    }

    /// The device zoom factor at which a device shows the wide lens's frame.
    /// See `Stream.zoomScale`.
    nonisolated private static func zoomScale(of device: AVCaptureDevice) -> CGFloat {
        let constituents = device.constituentDevices
        // A discrete lens is corrected on the main actor from the probed lens
        // factors — see `calibrateZoomScales` — since those are measured rather
        // than assumed. This is the placeholder until then.
        guard constituents.count > 1 else { return 1 }

        let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        guard switchOvers.count == constituents.count - 1,
              let wideIndex = constituents.firstIndex(where: { $0.deviceType == .builtInWideAngleCamera })
        else { return 1 }
        return wideIndex == 0 ? 1 : switchOvers[wideIndex - 1]
    }

    /// Detaches one stream and builds its replacement, leaving every other
    /// stream in the session running.
    ///
    /// Runs on `sessionQueue`, inside a single configuration transaction, so the
    /// session is never seen with the old lens gone and the new one not yet
    /// added.
    nonisolated private static func replaceStream(
        in session: AVCaptureMultiCamSession,
        previous: Stream,
        with source: CameraSource,
        resolution: Resolution,
        frameRate: FrameRate,
        isMultiCam: Bool,
        using chosenDevice: AVCaptureDevice?,
        initialZoom: CGFloat
    ) throws -> Stream {
        guard let device = chosenDevice ?? AVCaptureDevice.default(
            source.deviceType, for: .video, position: source.position
        ) else {
            throw CaptureError.deviceUnavailable(source)
        }

        // Everything that can be done to the incoming device before the session
        // is touched, is. A configuration transaction on a live multi-cam
        // session suspends *every* stream in it — the front module loses about
        // 0.4 s of frames to one — so the transaction is kept to the graph edits
        // that genuinely have to be inside it, and the format negotiation, which
        // is the expensive half, happens on a device the session does not yet
        // know about.
        //
        // Not any *earlier* than this, though. Doing it before the freeze goes
        // up, while the outgoing lens is still delivering, looks like free
        // hiding and measured as the opposite: these devices share sensors, so
        // configuring one disturbs the other, and the two streams lost more
        // frames overall (113 against 96 across five switches) for the trouble.
        try applyFormat(
            to: device,
            resolution: resolution,
            frameRate: frameRate,
            isMultiCam: isMultiCam,
            source: source
        )

        // Before the first frame, not after: this lens is taking over from one
        // that was just ridden to the same framing, and a device that starts at
        // its own 1.0 and is corrected afterwards delivers however many frames
        // it takes to notice at the wrong magnification — a visible snap in the
        // middle of what should be one continuous movement.
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.videoZoomFactor = initialZoom.clamped(
                to: device.minAvailableVideoZoomFactor...device.maxAvailableVideoZoomFactor
            )
        } catch {
            Log.capture.error("Initial zoom failed: \(error.localizedDescription, privacy: .public)")
        }

        session.beginConfiguration()
        var committed = false
        defer { if !committed { session.commitConfiguration() } }

        // Connections first: an input removed while connections still reference
        // its ports leaves the graph in a state the session will not accept a
        // new connection into.
        let retiredPorts = previous.input.ports
        for connection in session.connections
        where connection.inputPorts.contains(where: { port in retiredPorts.contains(port) }) {
            session.removeConnection(connection)
        }
        session.removeInput(previous.input)
        // The outputs stay. Only the input and the connections into them are
        // this stream's identity; the outputs are plumbing, and re-laying it
        // costs frames on every stream in the session.

        var stream = try makeStream(
            in: session,
            for: source,
            reusing: previous.previewLayer,
            using: device,
            recyclingOutputsFrom: previous
        )

        // `hardwareCost` is only meaningful once the transaction is committed,
        // and a lens that does not fit the budget has to go back through the
        // ladder rather than be left in a session iOS will terminate.
        session.commitConfiguration()
        committed = true

        guard session.hardwareCost <= 1.0 else {
            throw CaptureError.hardwareCostExceeded(session.hardwareCost)
        }

        // After the format is active, not before: the compositor scales by this
        // and the new lens rarely delivers the same dimensions as the old one.
        stream.textureSize = textureSize(of: stream.device)
        return stream
    }

    /// Picks a format per device, then walks the degradation ladder until
    /// `hardwareCost` fits.
    ///
    /// Doc 1 §5.3.4 fixes the recovery order: secondary resolution first, then
    /// primary, then frame rate. Degrading the stream the user is *looking at*
    /// before the one in the corner would be backwards.
    nonisolated private static func selectFormats(
        session: AVCaptureMultiCamSession,
        streams: [StreamRole: Stream],
        requested: QualityProfile,
        isMultiCam: Bool
    ) throws -> NegotiatedQuality {
        var primaryResolution = requested.resolution
        var secondaryResolution = requested.resolution
        var frameRate = requested.frameRate
        var reason: DegradationReason?

        /// Applies one candidate combination and reports the resulting cost.
        func attempt() throws -> Float {
            for (role, stream) in streams {
                try applyFormat(
                    to: stream.device,
                    resolution: role == .primary ? primaryResolution : secondaryResolution,
                    frameRate: frameRate,
                    isMultiCam: isMultiCam,
                    source: stream.source
                )
            }
            return session.hardwareCost
        }

        var cost = try attempt()
        Log.capture.info("hardwareCost after initial format selection: \(cost, format: .fixed(precision: 3))")

        // Step 1: secondary down. Step 2: primary down. Step 3: frame rate down.
        while cost > 1.0 {
            if let lowered = secondaryResolution.loweredOneTier, lowered < primaryResolution {
                secondaryResolution = lowered
            } else if let lowered = primaryResolution.loweredOneTier {
                primaryResolution = lowered
                secondaryResolution = min(secondaryResolution, lowered)
            } else if let lowered = frameRate.loweredOneTier {
                frameRate = lowered
            } else {
                throw CaptureError.hardwareCostExceeded(cost)
            }

            reason = .hardwareCostExceeded
            cost = try attempt()
            Log.capture.info(
                "Degraded to primary=\(primaryResolution.rawValue, privacy: .public) secondary=\(secondaryResolution.rawValue, privacy: .public) fps=\(frameRate.rawValue) → cost \(cost, format: .fixed(precision: 3))"
            )
        }

        return NegotiatedQuality(
            resolution: primaryResolution,
            frameRate: frameRate,
            hardwareCost: cost,
            degradationReason: reason
        )
    }

    /// Activates the best format for one device and pins its frame rate.
    nonisolated private static func applyFormat(
        to device: AVCaptureDevice,
        resolution: Resolution,
        frameRate: FrameRate,
        isMultiCam: Bool,
        source: CameraSource
    ) throws {
        guard let format = bestFormat(
            on: device,
            resolution: resolution,
            frameRate: frameRate,
            requiringMultiCam: isMultiCam
        ) else {
            throw CaptureError.noMultiCamFormat(source)
        }

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        // Only when it is not already the one in force: this is called twice on
        // a lens change — once to warm the device up before the freeze, once
        // inside the replacement — and re-applying a format that is already
        // active costs the same as applying a new one.
        if device.activeFormat != format {
            device.activeFormat = format
        }

        // Pin both cameras to the same rate.
        //
        // Without this they free-run within their format's supported range and
        // settle at *different* rates — the front module in particular drops to
        // a lower rate in dim light. Measured effect: 29% of primary frames
        // arrived with no secondary frame within one frame of skew, so nearly a
        // third of the recording had no overlay. Doc 3 Phase 2 task 2's
        // one-frame tolerance only means something if both streams are actually
        // running at the rate it is a tolerance for.
        let duration = CMTime(value: 1, timescale: CMTimeScale(frameRate.rawValue))
        if format.videoSupportedFrameRateRanges.contains(where: {
            $0.minFrameDuration <= duration && duration <= $0.maxFrameDuration
        }) {
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        }
    }

    /// The closest available format at or below the requested tier.
    nonisolated private static func bestFormat(
        on device: AVCaptureDevice,
        resolution: Resolution,
        frameRate: FrameRate,
        requiringMultiCam: Bool
    ) -> AVCaptureDevice.Format? {
        let target = resolution.dimensions

        let candidates = device.formats.filter { format in
            guard !requiringMultiCam || format.isMultiCamSupported else { return false }
            let supportsRate = format.videoSupportedFrameRateRanges.contains {
                $0.maxFrameRate >= Double(frameRate.rawValue)
            }
            return supportsRate
        }

        // Prefer the format nearest the target without exceeding it; fall back
        // to the smallest that does exceed it, so a device that only offers
        // larger formats still works rather than failing outright.
        let dimensioned = candidates.map { format -> (AVCaptureDevice.Format, CMVideoDimensions) in
            (format, CMVideoFormatDescriptionGetDimensions(format.formatDescription))
        }

        let atOrBelow = dimensioned
            .filter { $0.1.width <= target.width && $0.1.height <= target.height }
            .max { lhs, rhs in Int(lhs.1.width) * Int(lhs.1.height) < Int(rhs.1.width) * Int(rhs.1.height) }

        if let atOrBelow { return atOrBelow.0 }

        return dimensioned
            .min { lhs, rhs in Int(lhs.1.width) * Int(lhs.1.height) < Int(rhs.1.width) * Int(rhs.1.height) }?
            .0
    }

    // MARK: Orientation and mirroring

    /// Doc 3 Phase 1 task 8: rotation through `RotationCoordinator`, which
    /// accounts for the physical device orientation rather than the interface
    /// orientation — the two disagree whenever rotation lock is on.
    private func applyRotation() {
        for (role, coordinator) in rotationCoordinators {
            guard let connection = streams[role]?.previewLayer.connection else { continue }
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        }
    }

    /// Keeps the preview upright as the device turns.
    ///
    /// The coordinator publishes its angle asynchronously and keeps updating
    /// it: applying it once at configuration time leaves the preview correct
    /// only for whichever way the phone happened to be facing at launch, and
    /// silently wrong after the first rotation. Doc 3 Phase 1's criterion is
    /// *"rotating the device updates both previews correctly"*, which is an
    /// ongoing obligation, not a one-off assignment.
    private func observeRotation() {
        rotationObservations.removeAll()

        for (role, coordinator) in rotationCoordinators {
            let observation = coordinator.observe(
                \.videoRotationAngleForHorizonLevelPreview,
                options: [.initial, .new]
            ) { [weak self] _, change in
                guard let angle = change.newValue else { return }
                MainActor.assumeIsolated {
                    self?.updateCompositionRotation(angle, for: role)
                    guard let connection = self?.streams[role]?.previewLayer.connection,
                          connection.isVideoRotationAngleSupported(angle)
                    else { return }
                    // The preview layer is a CALayer: without disabling actions
                    // the rotation change animates as a rotate-and-scale, which
                    // reads as the image lurching rather than staying level.
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    connection.videoRotationAngle = angle
                    CATransaction.commit()
                }
            }
            rotationObservations.append(observation)
        }
    }

    /// The angle the compositor should rotate a source by, given the angle the
    /// preview is using.
    ///
    /// Two corrections live here, and they are the reason a take could come out
    /// on its side despite the phone being held upright the whole time.
    ///
    /// The first is *which* angle to read. `RotationCoordinator` publishes two:
    /// `…ForHorizonLevelPreview`, which keeps the picture upright as it is
    /// displayed, and `…ForHorizonLevelCapture`, which keeps it level with
    /// respect to gravity so a still shot in landscape comes out landscape. The
    /// composite used the capture angle, but the composited canvas is
    /// unconditionally portrait — `outputSize(for:)` swaps the tier's dimensions
    /// — and the app is portrait-only. So the moment the phone tilted far
    /// enough for the capture angle to flip to 0° or 180°, the recording started
    /// laying a landscape frame into a portrait canvas: on its side, heavily
    /// cropped, while the preview stayed upright because *it* reads the preview
    /// angle. The two must agree, and the canvas decides which one is right.
    ///
    /// The second is the fallback. An angle is only usable here if it is an odd
    /// quarter turn; anything else is a coordinator that has not settled yet
    /// (Core Motion has no orientation for a phone lying flat) or a device
    /// orientation this app does not lay out for. 90° — portrait — is the only
    /// answer that can be right for a portrait-locked interface.
    nonisolated private static func compositionRotation(_ angle: CGFloat) -> Double {
        let normalized = (angle.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
        let quarterTurns = Int((normalized / 90).rounded()) % 4
        return quarterTurns % 2 == 1 ? Double(quarterTurns) * 90 : 90
    }

    /// Angles frozen for the duration of a take, keyed by role.
    ///
    /// Non-empty means recording. Without this, a mid-take orientation update
    /// rewrites the uniforms and the rest of the file is rotated relative to its
    /// beginning — a single recording with two orientations in it, which no
    /// player can correct for.
    private var lockedRotations: [StreamRole: Double] = [:]

    private func updateCompositionRotation(_ previewAngle: CGFloat, for role: StreamRole) {
        guard lockedRotations.isEmpty else { return }
        let rotation = Self.compositionRotation(previewAngle)
        guard streams[role]?.rotationDegrees != rotation else { return }
        streams[role]?.rotationDegrees = rotation
        refreshUniforms()
    }

    private func lockRotationForRecording() {
        lockedRotations = streams.mapValues(\.rotationDegrees)
    }

    private func releaseRotationLock() {
        lockedRotations.removeAll()
        // Whatever the device did during the take is applied now, in one step,
        // so the next recording starts from the current orientation.
        for (role, coordinator) in rotationCoordinators {
            updateCompositionRotation(coordinator.videoRotationAngleForHorizonLevelPreview, for: role)
        }
    }

    /// Doc 3 Phase 1 task 7: the front preview is mirrored, the rear is not.
    private func applyMirroring() {
        for (role, stream) in streams {
            guard let connection = stream.previewLayer.connection else { continue }
            let shouldMirror = stream.source.prefersMirroring && configuration.mirrorsFrontCamera
            connection.automaticallyAdjustsVideoMirroring = false
            if connection.isVideoMirroringSupported {
                connection.isVideoMirrored = shouldMirror
            }
            _ = role
        }
    }

    // MARK: Interruptions (Doc 3 Phase 1 task 10)

    private func registerInterruptionObservers() {
        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: session, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
            let reason = raw.flatMap(AVCaptureSession.InterruptionReason.init(rawValue:))
            MainActor.assumeIsolated {
                self?.emit(.statusChanged(.interrupted(reason: Self.describe(reason))))
            }
        })

        observers.append(center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: session, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.emit(.statusChanged(.running))
            }
        })

        // A session that hits a runtime error stops delivering and says nothing
        // about it. Without this the symptom is a preview that simply stopped,
        // with no record anywhere of why.
        observers.append(center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session, queue: .main
        ) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            let message = error?.localizedDescription ?? "unknown"
            MainActor.assumeIsolated {
                guard let self else { return }
                self.runtimeErrors.append("\(message) (code \(error?.code ?? 0))")
                Log.capture.error("Session runtime error: \(message, privacy: .public)")
                self.emit(.recoverableFailure(message))
            }
        })

        observers.append(center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            let state = ProcessInfo.processInfo.thermalState
            MainActor.assumeIsolated {
                self?.emit(.thermalStateChanged(state))
            }
        })
    }

    nonisolated private static func describe(_ reason: AVCaptureSession.InterruptionReason?) -> String {
        switch reason {
        case .videoDeviceNotAvailableInBackground: "App is in the background"
        case .audioDeviceInUseByAnotherClient: "Microphone in use by another app"
        case .videoDeviceInUseByAnotherClient: "Camera in use by another app"
        case .videoDeviceNotAvailableWithMultipleForegroundApps: "Camera unavailable in Split View"
        case .videoDeviceNotAvailableDueToSystemPressure: "Camera paused by system pressure"
        default: "Camera paused"
        }
    }

    // MARK: Previews and controls

    func previewSource(for role: StreamRole) -> PreviewSource? {
        sources[role]
    }

    func focusAndExpose(at point: CGPoint, in role: StreamRole) {
        configureDevice(role) { device, devicePoint in
            if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                device.focusPointOfInterest = devicePoint
                device.focusMode = .autoFocus
            }
            if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.autoExpose) {
                device.exposurePointOfInterest = devicePoint
                device.exposureMode = .autoExpose
            }
        } convertingPoint: { point }
    }

    func lockFocusAndExposure(at point: CGPoint, in role: StreamRole) {
        configureDevice(role) { device, devicePoint in
            if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.locked) {
                device.focusPointOfInterest = devicePoint
                device.focusMode = .locked
            }
            if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.locked) {
                device.exposurePointOfInterest = devicePoint
                device.exposureMode = .locked
            }
        } convertingPoint: { point }
    }

    func resetFocusAndExposure(in role: StreamRole) {
        configureDevice(role) { device, _ in
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
        } convertingPoint: { CGPoint(x: 0.5, y: 0.5) }
    }

    func setZoomFactor(_ factor: CGFloat, for role: StreamRole, ramped: Bool) {
        guard let device = streams[role]?.device else { return }
        let clamped = factor.clamped(to: device.minAvailableVideoZoomFactor...device.maxAvailableVideoZoomFactor)
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                // Doc 3 Phase 4 task 15/16: ramp rather than jump, so discrete
                // stops and pinch feel like the same mechanism.
                if ramped {
                    // A ramp already under way is abandoned, not queued behind:
                    // two ramps fighting over one device is how a zoom ends up
                    // somewhere neither of them asked for.
                    if device.isRampingVideoZoom { device.cancelVideoZoomRamp() }
                    device.ramp(toVideoZoomFactor: clamped, withRate: Self.zoomRampRate)
                } else {
                    device.videoZoomFactor = clamped
                }
            } catch {
                Log.capture.error("Zoom failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func setExposureBias(_ bias: Float, for role: StreamRole) {
        guard let device = streams[role]?.device else { return }
        let clamped = bias.clamped(to: device.minExposureTargetBias...device.maxExposureTargetBias)
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                device.setExposureTargetBias(clamped)
            } catch {
                Log.capture.error("Exposure bias failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func availableZoomStops(for role: StreamRole) -> [ZoomStop] {
        guard let stream = streams[role] else { return [] }

        // Only rear stacks have multiple stops, and only lenses this device
        // actually has may be offered.
        guard stream.source != .front else {
            return [ZoomStop(label: "1x", zoomFactor: 1, source: .front)]
        }

        let present = [CameraSource.rearUltraWide, .rearWide, .rearTelephoto].filter { source in
            AVCaptureDevice.default(source.deviceType, for: .video, position: .back) != nil
        }

        // Whether a stop is also a *source*. It is not, whenever the engine is
        // free to choose the rear device for itself: then a stop is purely a
        // magnification, the engine finds the hardware that reaches it, and on
        // most phones most of the range is covered by a virtual device changing
        // its own lenses with no session work at all. It is, when the user has
        // pinned a lens from the Lenses picker, or in Rear + Rear where the
        // overlay's lens decides what the main stream may hold — there the pill
        // has to move the pin, and the view model is the only place that knows
        // what the other stream is using.
        let choosesOwnDevice = role == .primary
            && configuration.primarySource == .rearWide
            && configuration.mode != .dualRear

        return present.map { source in
            let stop = Self.roundedStop(lensFactor(source))
            return ZoomStop(
                label: Self.zoomLabel(stop),
                zoomFactor: stop,
                source: choosesOwnDevice ? nil : source
            )
        }
    }

    /// Where one constituent of a virtual device sits, in wide-relative terms.
    nonisolated private static func constituentMagnification(
        _ constituent: AVCaptureDevice,
        of virtual: AVCaptureDevice,
        scale: CGFloat
    ) -> CGFloat? {
        let constituents = virtual.constituentDevices
        let switchOvers = virtual.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        guard scale > 0,
              switchOvers.count == constituents.count - 1,
              let index = constituents.firstIndex(of: constituent)
        else { return nil }
        return (index == 0 ? 1 : switchOvers[index - 1]) / scale
    }

    // MARK: Zoom

    /// How much this lens magnifies relative to the wide lens, at its own 1.0.
    private func lensFactor(_ source: CameraSource) -> CGFloat {
        lensFactors[source] ?? 1
    }

    /// The device that should back a stream, or `nil` for the plain discrete
    /// lens the source names.
    ///
    /// Doc 1 §5.3.5 assumed a virtual device was never available in a multi-cam
    /// session, which is why every stop in this app started life as a physical
    /// lens and every lens change as a rebuilt connection graph. That is a
    /// per-device fact rather than a rule, and this phone disagrees with it: an
    /// iPhone 14 Pro runs its dual wide *or* its dual camera alongside the front
    /// one. Where the hardware allows it, the crossover between lenses happens
    /// inside AVFoundation, at the zoom factors the module is calibrated for,
    /// with no input swap and no gap in the preview — which is the entire
    /// difference between a zoom and a cut.
    ///
    /// This is where a magnification becomes hardware. The rear stack offers
    /// several devices covering overlapping parts of the zoom range — on an
    /// iPhone 14 Pro the triple camera spans all of it but will not run
    /// alongside the front one, while the dual wide (0.5–1×) and the dual
    /// (1–3×) both will — so the choice depends on where the user is zoomed to
    /// and on what the other stream is holding. Whichever is chosen covers its
    /// span optically, switching its own lenses inside AVFoundation, and the one
    /// place a change of device can be forced is 1×, where both of them are
    /// showing the same wide lens at the same field of view.
    ///
    /// `nil` when no virtual device covers the magnification — which is the
    /// honest answer for 3× on a phone that will only pair its dual wide with
    /// the front camera, and sends that stop back to the discrete telephoto.
    private func desiredDevice(
        for configuration: CaptureConfiguration,
        role: StreamRole
    ) -> AVCaptureDevice? {
        // Only the main stream, only when it asked for the plain rear camera,
        // and never in Rear + Rear — where the overlay holds one of the very
        // lenses a virtual device would claim, and a session will not open two
        // inputs on the same hardware. Asking for Ultra Wide or Telephoto by
        // name, from the Lenses picker, is honoured literally: that is a request
        // to be pinned to one lens rather than to zoom.
        guard role == .primary,
              configuration.primarySource == .rearWide,
              configuration.mode != .dualRear
        else { return nil }

        let companion: AVCaptureDevice? = configuration.mode.isDual
            ? configuration.secondarySource.flatMap {
                AVCaptureDevice.default($0.deviceType, for: .video, position: $0.position)
            }
            : nil

        let usable = { [self] (device: AVCaptureDevice) in
            device.constituentDevices.count > 1
                && canRunTogether(device, companion)
                && spansOptically(configuration.primaryZoom, on: device)
                && (!configuration.mode.isDual || device.formats.contains(where: \.isMultiCamSupported))
        }

        // Whatever is already running, if it still reaches. The dual wide and
        // the dual camera overlap at 1×, and changing between them there would
        // rebuild the graph to show the very same lens — so the range each one
        // owns is decided by which one the user arrived on, and the crossing
        // happens once, at the edge, rather than every time 1× is passed.
        if let live = streams[role], live.isVirtual, usable(live.device) {
            return live.device
        }

        let candidates: [AVCaptureDevice.DeviceType] =
            [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera]

        if let virtual = candidates.lazy.compactMap({ type in
            AVCaptureDevice.default(type, for: .video, position: .back)
        }).first(where: usable) {
            return virtual
        }

        // No virtual device reaches it — either this phone has none it can pair,
        // or the magnification is past the longest lens any of them contains.
        // The stop is still a magnification, so it still has to land on the lens
        // that owns it; that is a discrete input, switched by hand, with the
        // ride and the cover doing what the hardware would have done itself.
        return discreteLens(owning: configuration.primaryZoom)
    }

    /// The rear lens a magnification belongs to: the longest one that is still
    /// no longer than what was asked for, so anything between two lenses is
    /// reached by cropping the shorter one rather than by falling back to the
    /// widest.
    private func discreteLens(owning zoom: CGFloat) -> AVCaptureDevice? {
        let present = [CameraSource.rearUltraWide, .rearWide, .rearTelephoto]
            .compactMap { source in
                AVCaptureDevice.default(source.deviceType, for: .video, position: .back)
                    .map { (source: source, device: $0) }
            }
            .sorted { lensFactor($0.source) < lensFactor($1.source) }

        let owner = present.last { lensFactor($0.source) <= zoom * 1.05 }
            ?? present.first { $0.source == .rearWide }
            ?? present.first
        return owner?.device
    }

    /// Which physical device a role should be running on, virtual or discrete.
    /// The one comparison that decides whether the graph needs rebuilding at
    /// all — the source alone cannot answer it, since "the rear camera" is
    /// served by different hardware at different magnifications.
    private func desiredDeviceID(
        for configuration: CaptureConfiguration,
        role: StreamRole
    ) -> String? {
        if let virtual = desiredDevice(for: configuration, role: role) { return virtual.uniqueID }
        let source = role == .primary ? configuration.primarySource : configuration.secondarySource
        guard let source else { return nil }
        return AVCaptureDevice.default(
            source.deviceType, for: .video, position: source.position
        )?.uniqueID
    }

    /// Whether a magnification falls inside what a device's own lenses cover.
    ///
    /// Beyond the top of that range a virtual device is only cropping its
    /// longest lens, which a discrete one would do just as well and with one
    /// less thing to go wrong. Below the bottom it cannot go at all.
    private func spansOptically(_ zoom: CGFloat, on device: AVCaptureDevice) -> Bool {
        let scale = zoomScale(of: device)
        guard scale > 0 else { return false }
        let widest = widestMagnification(of: device)
        let longest = device.constituentDevices
            .compactMap { Self.constituentMagnification($0, of: device, scale: scale) }
            .max() ?? 1
        // A hair of tolerance either side: the stops are rounded for the label's
        // sake and must not fall outside the range they were rounded from.
        return zoom >= widest * 0.95 && zoom <= longest * 1.05
    }

    /// Whether the hardware will run two devices at the same time.
    ///
    /// Answered from `supportedMultiCamDeviceSets` rather than by building a
    /// session and seeing whether it complains — which is how a triple camera
    /// with 35 multi-cam formats still ends up rejecting the front camera's
    /// input halfway through a rebuild, leaving no session at all.
    private func canRunTogether(_ device: AVCaptureDevice, _ companion: AVCaptureDevice?) -> Bool {
        guard let companion else { return true }
        let required: Set<String> = [device.uniqueID, companion.uniqueID]
        return multiCamDeviceSets.contains { $0.isSuperset(of: required) }
    }

    /// The scale a stream *would* have if it were built for this source now.
    /// Needed before the stream exists — see `performSwitch`, which has to know
    /// what zoom to hand the incoming device before its first frame.
    private func prospectiveZoomScale(for device: AVCaptureDevice?, source: CameraSource) -> CGFloat {
        guard let device else { return 1 / lensFactor(source) }
        return zoomScale(of: device)
    }

    /// Gives every discrete stream the scale its lens was measured to have.
    ///
    /// Virtual devices arrive knowing their own — it is read straight off their
    /// switch-over factors, in the builder, where the device is. A discrete lens
    /// is the reciprocal of what it magnifies by, and *that* comes from the
    /// probe, so it is filled in here rather than assumed there.
    private func calibrateZoomScales() {
        for (role, stream) in streams {
            streams[role]?.zoomScale = zoomScale(of: stream.device)
        }
    }

    /// The device zoom factor at which a device shows the wide lens's frame,
    /// whatever it is made of. See `Stream.zoomScale`.
    ///
    /// A virtual device answers for itself, from switch-over factors read off
    /// the hardware. A discrete one is the reciprocal of what its lens
    /// magnifies by — and that is the lens the *device* is, not the one the
    /// stream asked for, since a request for the rear camera is served by
    /// whichever lens owns the magnification in hand.
    private func zoomScale(of device: AVCaptureDevice) -> CGFloat {
        guard device.constituentDevices.count <= 1 else { return Self.zoomScale(of: device) }
        return 1 / lensFactor(CameraSource(deviceType: device.deviceType) ?? .rearWide)
    }

    /// The widest magnification a device can show — the point at which it takes
    /// over from anything wider than itself.
    private func widestMagnification(of device: AVCaptureDevice) -> CGFloat {
        device.minAvailableVideoZoomFactor / max(zoomScale(of: device), 0.001)
    }

    /// The device zoom factor that puts a stream at a wide-relative
    /// magnification. Never below 1: no lens shows more than its own frame.
    private func deviceZoom(forUser user: CGFloat, on role: StreamRole) -> CGFloat {
        guard let stream = streams[role] else { return 1 }
        return max(1, user * stream.zoomScale)
    }

    /// Puts each live stream at the magnification its role calls for.
    ///
    /// A device object is shared process-wide and remembers the zoom it was last
    /// left at, so this runs after every rebuild as well — otherwise a lens
    /// returned to still carries the crop it was wearing when it was left.
    private func applyZoom(ramped: Bool, resettingSecondary: Bool = false) {
        if let primary = streams[.primary] {
            let wanted = deviceZoom(forUser: configuration.primaryZoom, on: .primary)
            if abs(primary.device.videoZoomFactor - wanted) > 0.01 {
                setZoomFactor(wanted, for: .primary, ramped: ramped)
            }
        }
        // Only for a stream that was just built. The overlay has no zoom control
        // and starts at its lens's own full frame, but it does *keep* whatever
        // framing it arrives with — a swap moves a stream between roles without
        // changing what it is looking at, and rescaling the demoted one would
        // make the swap reframe both pictures instead of exchanging them.
        if resettingSecondary,
           let secondary = streams[.secondary],
           abs(secondary.device.videoZoomFactor - 1) > 0.01 {
            setZoomFactor(1, for: .secondary, ramped: false)
        }
    }

    /// Rides the outgoing lens toward the framing the incoming one will start
    /// at, and reports the magnification the handoff should happen at.
    ///
    /// Only a zoom *in* can be ridden. Going wider means asking a lens for more
    /// than its widest frame, so a zoom out hands over immediately and travels
    /// the rest of the distance on the incoming lens, which does have the frame
    /// to give.
    private func rideOut(
        _ previous: Stream,
        toward crossover: CGFloat,
        target: CGFloat,
        for role: StreamRole
    ) async -> CGFloat {
        let scale = previous.zoomScale
        guard scale > 0 else { return target }
        let current = previous.device.videoZoomFactor / scale
        guard target > current else { return current }

        // Never past the point the incoming lens takes over at, and never past
        // what the outgoing one can actually reach.
        let ceiling = previous.device.maxAvailableVideoZoomFactor / scale
        let handoff = min(target, max(crossover, current), ceiling)
        guard handoff > current * 1.02 else { return current }

        setZoomFactor(handoff * scale, for: role, ramped: true)
        try? await Task.sleep(for: .seconds(Self.rampDuration(from: current, to: handoff)))
        return handoff
    }

    /// How long `ramp(toVideoZoomFactor:withRate:)` needs, given that the rate
    /// is in powers of two per second.
    nonisolated private static func rampDuration(from: CGFloat, to: CGFloat) -> TimeInterval {
        guard from > 0, to > 0 else { return 0 }
        let octaves = abs(log2(Double(to / from)))
        return min(maximumRampDuration, octaves / Double(zoomRampRate))
    }

    /// What each rear lens magnifies by, relative to the wide lens.
    ///
    /// The virtual devices are the calibrated answer even on hardware that will
    /// not run them in a multi-cam session: their switch-over factors are the
    /// exact zoom values at which the system itself hands one constituent lens
    /// to the next, which is precisely the number a seamless handoff needs.
    /// Field of view is the fallback, and the marketing figures the last resort.
    nonisolated private static func rearLensFactors() -> [CameraSource: CGFloat] {
        var factors: [CameraSource: CGFloat] = [.front: 1, .rearWide: 1]

        let virtualTypes: [AVCaptureDevice.DeviceType] =
            [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera]

        for type in virtualTypes {
            guard let virtual = AVCaptureDevice.default(type, for: .video, position: .back) else { continue }
            let constituents = virtual.constituentDevices
            let switchOvers = virtual.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
            guard switchOvers.count == constituents.count - 1,
                  let wideIndex = constituents.firstIndex(where: { $0.deviceType == .builtInWideAngleCamera })
            else { continue }

            // The first constituent is the virtual device's own 1.0; every other
            // one begins where its switch-over factor says it does.
            func scale(_ index: Int) -> CGFloat { index == 0 ? 1 : switchOvers[index - 1] }
            let wideScale = scale(wideIndex)
            guard wideScale > 0 else { continue }

            for (index, device) in constituents.enumerated() {
                if let source = CameraSource(deviceType: device.deviceType) {
                    factors[source] = scale(index) / wideScale
                }
            }
            break
        }

        // Anything the virtual devices did not describe — a phone with no
        // virtual device at all, or a lens outside the one it covers.
        let wideFOV = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)?
            .activeFormat.videoFieldOfView
        for source in [CameraSource.rearUltraWide, .rearTelephoto] where factors[source] == nil {
            guard let wideFOV, wideFOV > 0,
                  let device = AVCaptureDevice.default(source.deviceType, for: .video, position: .back),
                  device.activeFormat.videoFieldOfView > 0
            else {
                factors[source] = source == .rearUltraWide ? 0.5 : 3
                continue
            }
            // Magnification is the ratio of the half-angle tangents, not of the
            // angles themselves.
            let halfAngle = { (degrees: Float) in tan(Double(degrees) * .pi / 360) }
            factors[source] = CGFloat(halfAngle(wideFOV) / halfAngle(device.activeFormat.videoFieldOfView))
        }

        return factors
    }

    /// The magnification a stop should ask for, given what the lens delivers.
    ///
    /// A lens's true factor is rarely the round number it is sold as — an ultra
    /// wide is nearer 0.43× than 0.5× — and the pills have to read the way the
    /// rest of the phone reads. Snapping to the nearby round figure costs a
    /// sliver of crop and buys a label the user recognises.
    nonisolated private static func roundedStop(_ factor: CGFloat) -> CGFloat {
        let nice: [CGFloat] = [0.5, 1, 2, 3, 5, 10]
        guard let candidate = nice.min(by: { abs($0 - factor) < abs($1 - factor) }),
              abs(candidate - factor) / factor <= 0.2
        else { return (factor * 10).rounded() / 10 }
        return candidate
    }

    /// Every combination of cameras this hardware will run at the same time.
    ///
    /// The authoritative answer to a question that otherwise has to be asked by
    /// trial and error: a device may well offer multi-cam formats on its triple
    /// camera and still refuse to pair it with the front one, and `canAddInput`
    /// only says so after a session has been half built.
    nonisolated private static func supportedDeviceSets() -> [Set<String>] {
        discovery().supportedMultiCamDeviceSets.map { set in
            Set(set.map(\.uniqueID))
        }
    }

    /// The same sets, named, for the self-check.
    nonisolated static func multiCamDeviceSets() -> [String] {
        discovery()
            .supportedMultiCamDeviceSets
            .map { set in set.map(\.localizedName).sorted().joined(separator: " + ") }
            .sorted()
    }

    nonisolated private static func discovery() -> AVCaptureDevice.DiscoverySession {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera,
                .builtInWideAngleCamera, .builtInUltraWideCamera,
                .builtInTelephotoCamera, .builtInTrueDepthCamera,
            ],
            mediaType: .video,
            position: .unspecified
        )
    }

    nonisolated private static func virtualMultiCamSupport() -> String {
        let types: [AVCaptureDevice.DeviceType] =
            [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera]
        let answers = types.compactMap { type -> String? in
            guard let device = AVCaptureDevice.default(type, for: .video, position: .back) else { return nil }
            let supported = device.formats.filter(\.isMultiCamSupported).count
            return "\(type.rawValue)=\(supported)/\(device.formats.count)"
        }
        return answers.isEmpty ? "no virtual devices" : answers.joined(separator: "  ")
    }

    nonisolated private static func zoomLabel(_ factor: CGFloat) -> String {
        factor == factor.rounded()
            ? "\(Int(factor))x"
            : String(format: "%.1fx", Double(factor))
    }

    // MARK: Covering a lens change

    /// Freezes the last frame of a stream over its preview layer.
    ///
    /// Removing an input takes the preview layer's connection with it, and a
    /// connectionless preview layer is not the last frame — it is black. The
    /// incoming lens then takes a couple of hundred milliseconds to deliver
    /// anything, and that gap is the flash the user sees. Since the outgoing
    /// lens was just ridden to the same framing the incoming one starts at, its
    /// final frame is very nearly the picture that is about to appear.
    private func installFreezeCover(for role: StreamRole) -> CALayer? {
        guard let stream = streams[role],
              let pixels = lastFrames.latest(for: role)
        else { return nil }

        let context = freezeContext ?? CIContext(options: [.cacheIntermediates: false])
        freezeContext = context

        // Downscaled to roughly what the screen can show. Rendering a 4K frame
        // to a `CGImage` costs tens of milliseconds on the main thread, and
        // spending them here would put a stutter at the exact moment this
        // exists to smooth over.
        let full = CIImage(cvPixelBuffer: pixels)
        let scale = min(1, Self.coverPixelWidth / max(full.extent.width, full.extent.height))
        let image = full
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .oriented(Self.freezeOrientation(rotationDegrees: stream.rotationDegrees))
        guard let rendered = context.createCGImage(image, from: image.extent) else { return nil }

        let cover = CALayer()
        cover.contents = rendered
        cover.contentsGravity = .resizeAspectFill
        cover.masksToBounds = true
        cover.frame = stream.previewLayer.bounds
        // The preview mirrors the front camera through its connection; the data
        // output never does, so the frozen copy has to be flipped to match.
        if stream.source.prefersMirroring, configuration.mirrorsFrontCamera {
            cover.transform = CATransform3DMakeScale(-1, 1, 1)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stream.previewLayer.addSublayer(cover)
        CATransaction.commit()
        return cover
    }

    /// Holds the cover until the new lens is genuinely delivering, then fades it.
    ///
    /// Two frames rather than one: the first arrival can still be the tail of
    /// the old lens's pipeline, and uncovering onto it would show the very cut
    /// the cover exists to hide. The deadline is what keeps a lens that never
    /// starts from leaving a still photograph on the screen for ever.
    @discardableResult
    private func uncover(_ cover: CALayer?, for role: StreamRole) async -> Duration {
        guard let cover else { return .zero }
        let baseline = frameCounters.count(for: role)

        let start = ContinuousClock.now
        let deadline = start + .seconds(1.5)
        while frameCounters.count(for: role) < baseline + 2, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(16))
        }
        let held = ContinuousClock.now - start

        // Short, and a fade rather than a cut: whatever moved in front of the
        // camera during the switch is the difference between these two frames.
        CATransaction.begin()
        CATransaction.setAnimationDuration(Self.coverFadeDuration)
        cover.opacity = 0
        CATransaction.commit()

        try? await Task.sleep(for: .seconds(Self.coverFadeDuration))
        cover.removeFromSuperlayer()
        return held
    }

    /// How a sensor-space frame has to be turned to match what the preview
    /// layer is showing. The app is portrait-locked, so 90° is the ordinary
    /// case and the others are only reached mid-rotation.
    nonisolated private static func freezeOrientation(rotationDegrees: Double) -> CGImagePropertyOrientation {
        switch Int(rotationDegrees.rounded()) % 360 {
        case 90: .right
        case 180: .down
        case 270: .left
        default: .up
        }
    }

    /// Runs a device mutation on the session queue with the lock held.
    private func configureDevice(
        _ role: StreamRole,
        _ body: @escaping @Sendable (AVCaptureDevice, CGPoint) -> Void,
        convertingPoint: () -> CGPoint
    ) {
        guard let stream = streams[role] else { return }
        // The preview layer owns the mapping from screen space to device space;
        // doing this arithmetic by hand is how tap-to-focus ends up off-centre
        // under `.resizeAspectFill`.
        let viewPoint = CGPoint(
            x: convertingPoint().x * stream.previewLayer.bounds.width,
            y: convertingPoint().y * stream.previewLayer.bounds.height
        )
        let devicePoint = stream.previewLayer.captureDevicePointConverted(fromLayerPoint: viewPoint)
        let device = stream.device

        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                body(device, devicePoint)
            } catch {
                Log.capture.error("Device configuration failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Recording

    nonisolated private static func textureSize(of device: AVCaptureDevice) -> CGSize {
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        return CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height))
    }

    /// Attaches the sample-buffer delegates. Separate from `buildSession`
    /// because delegates are main-actor-owned objects and `buildSession` runs
    /// on the session queue with no access to them.
    private func attachOutputHandlers() {
        streamHandlers.removeAll()

        for (role, stream) in streams {
            guard let output = stream.dataOutput else { continue }
            let handler = StreamOutputHandler(role: role) { [weak self] role, sample, pixels, time in
                self?.handleFrame(role: role, sample: sample, pixels: pixels, time: time)
            }
            output.setSampleBufferDelegate(
                handler,
                queue: role == .primary ? primaryQueue : secondaryQueue
            )
            streamHandlers[role] = handler
        }
    }

    /// Points the microphone output at the recorder.
    ///
    /// Separate from `makeAudioOutput` for the same reason `attachOutputHandlers`
    /// is separate from `buildSession`: delegates are main-actor-owned objects
    /// and the graph is assembled on `sessionQueue`, which has no access to them.
    private func attachAudioHandler(to output: AVCaptureAudioDataOutput?) {
        audioOutput = output
        guard let output else {
            audioHandler = nil
            return
        }

        let handler = AudioOutputHandler { [recorder] sample in
            recorder.appendAudio(sample)
        }
        output.setSampleBufferDelegate(handler, queue: audioQueue)
        audioHandler = handler
        Log.recording.info("Audio input attached")
    }

    /// Called on the primary or secondary stream queue. Never touches the main
    /// actor — everything it reads is behind `compositionLock`.
    nonisolated private func handleFrame(
        role: StreamRole,
        sample: CMSampleBuffer,
        pixels: CVPixelBuffer,
        time: CMTime
    ) {
        frameCounters.record(role: role, time: time)
        // One buffer per role, held only until the next one arrives — the cost
        // of the lens change having something to hide behind. See
        // `installFreezeCover`.
        lastFrames.store(pixels, for: role)

        // Order matters. The pairer is latency-critical — a secondary frame
        // offered late is a frame the primary has already given up waiting for
        // — while the clean writer only needs the buffer eventually. Appending
        // first pushed 82% of frames past the one-frame skew tolerance, so the
        // composited file lost its overlay for most of its length.
        guard role == .primary else {
            pairer.offerSecondary(pixels, at: time)
            cleanRecorder.append(sample, for: role)
            return
        }

        guard recorder.state == .recording else {
            cleanRecorder.append(sample, for: role)
            return
        }

        let (uniforms, outputSize, compositor) = compositionState.snapshot()
        let secondary = pairer.matchSecondary(for: time)

        guard let compositor else { return }

        // Non-blocking: the capture queue is released immediately and the
        // frame is appended from the GPU's completion handler. Blocking here
        // costs 75% of the frames at 4K.
        compositor.compositeAsync(
            primary: pixels,
            secondary: secondary,
            uniforms: uniforms,
            outputSize: outputSize
        ) { [recorder] composited in
            guard let composited else { return }
            recorder.appendVideo(composited, at: time)
        }

        cleanRecorder.append(sample, for: role)
    }

    func updateComposition(_ parameters: CompositionParameters) {
        composition = parameters
        refreshUniforms()
    }

    /// Rebuilds the uniform block from current state.
    ///
    /// Called on every change that can affect the composition — layout, overlay
    /// position, split ratio, stream sources, negotiated quality. Recomputing
    /// per frame would be wasted work; recomputing too rarely is how a recorded
    /// file stops matching the preview.
    private func refreshUniforms(photoFormat: StreamPixelFormat? = nil) {
        let outputSize = outputSize(for: negotiatedQuality.resolution)

        let primary = streams[.primary]
        let secondary = streams[.secondary]

        let inputs = CompositionUniforms.Inputs(
            layout: composition.layout,
            outputSize: outputSize,
            primaryTextureSize: primary?.textureSize ?? CGSize(width: 1920, height: 1080),
            secondaryTextureSize: secondary?.textureSize ?? CGSize(width: 1920, height: 1080),
            // Per-device, from `RotationCoordinator` — see
            // `compositionRotation(_:)`. While a take is running the angle
            // frozen at its start wins over anything a reconfiguration
            // (thermal degradation, a lens switch) would otherwise write, so one
            // file can never contain two orientations.
            primaryRotation: lockedRotations[.primary] ?? primary?.rotationDegrees ?? 90,
            secondaryRotation: lockedRotations[.secondary] ?? secondary?.rotationDegrees ?? 90,
            primaryIsMirrored: primary?.source.prefersMirroring == true && configuration.mirrorsFrontCamera,
            secondaryIsMirrored: secondary?.source.prefersMirroring == true && configuration.mirrorsFrontCamera,
            primaryFormat: photoFormat ?? .biplanar,
            secondaryFormat: photoFormat ?? .biplanar,
            hasSecondary: secondary != nil,
            overlayCentre: composition.overlayCentre,
            overlayWidthFraction: composition.overlayWidthFraction,
            overlayHeightFraction: composition.overlayHeightFraction,
            splitRatio: composition.splitRatio,
            diagonalAngle: composition.diagonalAngle,
            border: composition.border
        )

        compositionState.update(uniforms: CompositionUniforms(inputs), outputSize: outputSize)
    }

    /// Portrait output at the negotiated tier, in the shape the user chose.
    ///
    /// The app is portrait-only until Doc 3 Phase 8, so the canvas is always
    /// taller than it is wide; `AspectRatio` decides by how much. 16:9 at 1080p
    /// is the tier's own dimensions swapped, 4:3 is 1080×1440 — a shorter
    /// canvas cropped from the same sensor frame, which is why the change costs
    /// a uniform update and not a session rebuild.
    private func outputSize(for resolution: Resolution) -> CGSize {
        configuration.aspectRatio.outputSize(for: resolution)
    }

    // MARK: Phase F — photo, manual controls, torch, lens switching

    func capturePhoto() async throws -> PhotoResult {
        guard let primaryOutput = streams[.primary]?.photoOutput else {
            throw PhotoError.noOutput
        }

        if compositionState.compositor == nil {
            compositionState.compositor = try MetalCompositor()
        }
        // Stills arrive as BGRA while video arrives as 420f, so the uniforms
        // used for the photo composite differ from the ones the video path is
        // running with.
        refreshUniforms(photoFormat: .bgra)
        defer { refreshUniforms() }

        let flashMode = configuration.flashMode
        let hasFlash = streams[.primary]?.device.isFlashAvailable ?? false

        return try await photoController.capture(
            primaryOutput: primaryOutput,
            secondaryOutput: streams[.secondary]?.photoOutput
        ) {
            // An uncompressed format is required: `AVCapturePhoto.pixelBuffer`
            // is nil for compressed output, and the compositor needs pixels,
            // not JPEG bytes. Requesting the default settings here silently
            // yields nil buffers and a capture that never completes.
            let settings = AVCapturePhotoSettings(format: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            settings.flashMode = hasFlash ? Self.avFlashMode(flashMode) : .off
            return settings
        }
    }

    nonisolated private static func avFlashMode(_ mode: FlashMode) -> AVCaptureDevice.FlashMode {
        switch mode {
        case .off: .off
        case .on: .on
        case .auto: .auto
        }
    }

    func setManualControl(_ control: ManualControl, for role: StreamRole) {
        guard let device = streams[role]?.device else { return }
        DeviceManualControls.apply(control, to: device, on: sessionQueue)
    }

    var isTorchAvailable: Bool {
        guard let stream = streams[.primary], stream.source.position == .back else { return false }
        return stream.device.hasTorch && stream.device.isTorchAvailable
    }

    func setTorch(enabled: Bool, level: Float) {
        // Doc 2 §4.2: torch is rear-primary only. A front-primary session uses
        // the screen flash instead, which is a UI concern rather than a device
        // one.
        guard let stream = streams[.primary], stream.source.position == .back else { return }
        DeviceManualControls.setTorch(
            enabled: enabled, level: level, on: stream.device, queue: sessionQueue
        )
    }

    /// Doc 3 Phase 4 task 14: switching one stream's lens reconfigures **that
    /// stream's connection only**, inside a configuration transaction, so the
    /// other stream keeps running.
    func setSource(_ source: CameraSource, for role: StreamRole) async {
        var updated = configuration
        switch role {
        case .primary: updated.primarySource = source
        case .secondary: updated.secondarySource = source
        }
        await apply(updated)
    }

    func startRecording() async throws -> URL {
        // Doc 3 Phase 2 task 18: refuse below 100 MB, warn below 500 MB.
        let free = RecordingController.availableBytes()
        guard free > 100_000_000 else {
            throw RecordingError.insufficientStorage(free)
        }
        if free < 500_000_000 {
            emit(.recoverableFailure("Storage is running low"))
        }

        if compositionState.compositor == nil {
            compositionState.compositor = try MetalCompositor()
        }

        // Nothing below touches the capture session. The microphone, the audio
        // session and the sample-buffer delegates are all established when the
        // graph is built, precisely so that pressing record cannot interrupt the
        // streams it is about to record.

        pairer.resetStatistics()
        pairer.updateFrameRate(negotiatedQuality.frameRate)

        // The angle the composite uses is fixed here for the whole take, and the
        // rotation observer stops writing to it until the take ends — see
        // `observeRotation`.
        lockRotationForRecording()
        refreshUniforms()

        governor.isRecording = true
        governor.observe(devices: streams.values.map(\.device))

        if configuration.quality.savesCleanSources {
            cleanRecorder.start(
                roles: streams.reduce(into: [:]) { result, entry in
                    result[entry.key] = (entry.value.textureSize, entry.value.rotationDegrees)
                },
                quality: configuration.quality
            )
        }

        let url = try recorder.start(
            outputSize: outputSize(for: negotiatedQuality.resolution),
            quality: configuration.quality,
            hasAudio: audioOutput != nil
        )
        return url
    }

    func stopRecording() async -> RecordingResult? {
        let cleanSources = await cleanRecorder.finish()
        var result = await recorder.finish()
        result?.cleanSourceFileNames = cleanSources
        governor.resetAfterRecording()

        // The audio session is deliberately *not* deactivated here: it belongs
        // to the capture session's lifetime now, not to a single take.
        releaseRotationLock()

        if result != nil {
            Log.recording.info(
                "Pairing: \(self.pairer.pairedCount) paired, \(self.pairer.unpairedCount) unpaired (\(String(format: "%.2f", self.pairer.unpairedFraction * 100))%), \(self.pairer.heldCount) held, \(String(format: "%.3f", self.pairer.blankFraction * 100))% with no overlay"
            )
        }
        return result
    }

    func pauseRecording() {
        recorder.pause(at: CMClockGetTime(CMClockGetHostTimeClock()))
    }

    func resumeRecording() {
        recorder.resume(at: CMClockGetTime(CMClockGetHostTimeClock()))
    }

    // MARK: Performance

    nonisolated struct PerformanceSnapshot: Sendable {
        var gpuMilliseconds: Double
        var appended: Int
        var dropped: Int
        var hardwareCost: Float
    }

    func performanceSnapshot() -> PerformanceSnapshot {
        PerformanceSnapshot(
            gpuMilliseconds: (compositionState.compositor?.lastGPUTime ?? 0) * 1000,
            appended: recorder.framesAppended,
            dropped: recorder.framesDropped,
            hardwareCost: session.hardwareCost
        )
    }

    /// Doc 3 Phase 5 task 7. Releasing the texture cache and the buffer pool is
    /// safe mid-recording — both rebuild on the next frame — and is far
    /// preferable to the alternative, which is the system terminating the app
    /// and losing the take entirely.
    private func registerMemoryPressureObserver() {
        observers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.compositionState.compositor?.releaseCaches()
                    Log.composition.notice(
                        "Memory warning at \(String(format: "%.0f", PerformanceMonitor.footprintMegabytes())) MB"
                    )
                }
            }
        )
    }

    /// Doc 3 Phase 5 task 6: cinematic stabilisation is frequently unavailable
    /// in multi-cam and must not be offered when it is not.
    func supportedStabilizationModes() -> [StabilizationMode] {
        guard let format = streams[.primary]?.device.activeFormat else { return [.off] }
        return StabilizationMode.allCases.filter { mode in
            mode == .off || format.isVideoStabilizationModeSupported(mode.avMode)
        }
    }

    // MARK: Hardware self-check

    /// A plain-text account of the live connection graph, for
    /// `devicectl --console`.
    ///
    /// Doc 3 Phase 1's acceptance criteria are about things that cannot be
    /// asserted from the simulator and cannot be screenshotted from the command
    /// line either: that both previews have real connections, that the front
    /// one is mirrored and the rear one is not, that rotation is applied, and
    /// that `hardwareCost` stayed within budget. This prints exactly those
    /// facts so a hardware run produces evidence rather than an impression.
    func hardwareSelfCheck() -> String {
        var lines: [String] = []
        lines.append("═══ DuoCam multi-cam self-check ═══")
        lines.append("status:        \(status)")
        lines.append("mode:          \(configuration.mode.displayName)")
        lines.append("session:       inputs=\(session.inputs.count) outputs=\(session.outputs.count) connections=\(session.connections.count)")
        lines.append("hardwareCost:  \(String(format: "%.3f", session.hardwareCost))  (budget 1.000)")
        lines.append("pressureCost:  \(String(format: "%.3f", session.systemPressureCost))")
        lines.append("frames in:     \(frameCounters.summary)")
        lines.append("negotiated:    \(negotiatedQuality.resolution.displayName) @ \(negotiatedQuality.frameRate.displayName) fps"
                     + (negotiatedQuality.degradationReason.map { " — degraded: \($0.rawValue)" } ?? ""))
        lines.append("thermal:       \(ProcessInfo.processInfo.thermalState)")
        // What the zoom maths is working from. A handoff between lenses is only
        // seamless if these are the real ratios, so they are worth reading back
        // rather than assuming.
        let factors = [CameraSource.rearUltraWide, .rearWide, .rearTelephoto]
            .compactMap { source in lensFactors[source].map { "\(source.rawValue)=\(String(format: "%.3f", $0))×" } }
        lines.append("lens factors:  \(factors.joined(separator: "  "))")
        lines.append("virtual multi-cam: \(Self.virtualMultiCamSupport())")
        lines.append("device sets:")
        for set in Self.multiCamDeviceSets() { lines.append("   \(set)") }
        lines.append("switches:")
        for entry in switchTrace { lines.append("   \(entry)") }
        lines.append("runtime errors: \(runtimeErrors.isEmpty ? "none" : runtimeErrors.joined(separator: " | "))")

        for role in StreamRole.allCases {
            guard let stream = streams[role] else {
                lines.append("\(role.rawValue): —")
                continue
            }
            let dims = CMVideoFormatDescriptionGetDimensions(stream.device.activeFormat.formatDescription)
            let connection = stream.previewLayer.connection
            let expectedMirror = stream.source.prefersMirroring && configuration.mirrorsFrontCamera
            let actualMirror = connection?.isVideoMirrored ?? false
            let verdict = actualMirror == expectedMirror ? "OK" : "MISMATCH"

            lines.append("── \(role.rawValue) · \(stream.source.displayName) ──")
            lines.append("   device:     \(stream.device.localizedName)"
                         + (stream.isVirtual
                            ? "  [virtual: \(stream.device.constituentDevices.count) lenses]"
                            : "  [discrete]"))
            lines.append("   zoomScale:  \(String(format: "%.2f", stream.zoomScale))"
                         + "  stops=\(availableZoomStops(for: role).map(\.label).joined(separator: ","))")
            lines.append("   format:     \(dims.width)×\(dims.height)"
                         + "  multiCam=\(stream.device.activeFormat.isMultiCamSupported)")
            lines.append("   connection: \(connection == nil ? "MISSING" : "present")"
                         + "  active=\(connection?.isActive ?? false)"
                         + "  enabled=\(connection?.isEnabled ?? false)")
            lines.append("   mirrored:   \(actualMirror)  expected=\(expectedMirror)  [\(verdict)]")
            lines.append("   rotation:   \(String(format: "%.0f", connection?.videoRotationAngle ?? -1))°")
            lines.append("   zoom:       \(String(format: "%.2f", stream.device.videoZoomFactor))×")
        }

        lines.append("═══════════════════════════════════")
        return lines.joined(separator: "\n")
    }

    // MARK: Emit

    private func emit(_ event: CaptureEngineEvent) {
        if case .statusChanged(let newStatus) = event { status = newStatus }
        continuation.yield(event)
    }
}


/// Keeps the most recent frame from each stream, and nothing more.
///
/// Exactly one buffer per role is retained: enough to paint over a lens change,
/// shallow enough that the video data output's pool is never starved. The
/// pairer already holds a frame on the same terms.
nonisolated final class LastFrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [StreamRole: CVPixelBuffer] = [:]

    /// Called from a stream's own queue.
    func store(_ pixels: CVPixelBuffer, for role: StreamRole) {
        lock.withLock { frames[role] = pixels }
    }

    func latest(for role: StreamRole) -> CVPixelBuffer? {
        lock.withLock { frames[role] }
    }

    func clear(_ role: StreamRole) {
        lock.withLock { frames[role] = nil }
    }
}

/// Counts arrivals per stream and remembers the last timestamp seen on each.
nonisolated final class FrameCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [StreamRole: Int] = [:]
    private var lastTimes: [StreamRole: CMTime] = [:]

    func record(role: StreamRole, time: CMTime) {
        lock.withLock {
            counts[role, default: 0] += 1
            lastTimes[role] = time
        }
    }

    /// How many frames a stream has delivered. Read while waiting for a lens
    /// change to produce its first picture — see `releaseCover`.
    func count(for role: StreamRole) -> Int {
        lock.withLock { counts[role] ?? 0 }
    }

    var summary: String {
        lock.withLock {
            StreamRole.allCases.map { role in
                let count = counts[role] ?? 0
                let time = lastTimes[role].map { String(format: "%.3f", $0.seconds) } ?? "—"
                return "\(role.rawValue)=\(count) (last PTS \(time)s)"
            }.joined(separator: "  ")
        }
    }

    func reset() {
        lock.withLock {
            counts.removeAll()
            lastTimes.removeAll()
        }
    }
}
