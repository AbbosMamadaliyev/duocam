import AVFoundation
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
    private var audioInput: AVCaptureDeviceInput?

    var recordingState: RecordingController.State { recorder.state }
    var unpairedFrameFraction: Double { pairer.unpairedFraction }

    /// Everything belonging to one live stream.
    private struct Stream {
        let source: CameraSource
        let device: AVCaptureDevice
        let input: AVCaptureDeviceInput
        let previewLayer: AVCaptureVideoPreviewLayer
        var dataOutput: AVCaptureVideoDataOutput?
        var photoOutput: AVCapturePhotoOutput?
        var textureSize: CGSize = .zero
        var rotationDegrees: Double = 90
        var isMirrored: Bool = false
    }

    init(configuration: CaptureConfiguration = .default) {
        self.configuration = configuration
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

        do {
            let result = try await configureSession(for: configuration)
            apply(result)
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
        emit(.statusChanged(.idle))
    }

    func apply(_ newConfiguration: CaptureConfiguration) async {
        let previous = configuration
        let needsReconfiguration = newConfiguration.requiresSessionReconfiguration(comparedTo: previous)
        configuration = newConfiguration

        guard needsReconfiguration else {
            remapRoles(for: newConfiguration)
            applyMirroring()
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
    private func switchSource(to source: CameraSource, for role: StreamRole) async {
        guard let previous = streams[role] else { return }

        // The tier the ladder already settled on, not the requested one: this
        // stream has to fit the budget the other stream is currently spending.
        let resolution = negotiatedQuality.resolution
        let frameRate = negotiatedQuality.frameRate
        let isMultiCam = configuration.mode.isDual

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
                            isMultiCam: isMultiCam
                        ))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            adopt(stream, for: role)
        } catch {
            // The targeted path is an optimisation, never the only way through:
            // anything it cannot do — a lens the pairing cannot afford, a device
            // that refuses its format — falls back to the full rebuild, which
            // owns the degradation ladder.
            Log.capture.notice(
                "In-place lens switch to \(source.rawValue, privacy: .public) failed (\(error.localizedDescription, privacy: .public)); rebuilding session"
            )
            emit(.statusChanged(.configuring))
            do {
                apply(try await configureSession(for: configuration))
                emit(.statusChanged(.running))
            } catch {
                Log.capture.error("Reconfiguration failed: \(error.localizedDescription, privacy: .public)")
                emit(.recoverableFailure(error.localizedDescription))
                emit(.statusChanged(.running))
            }
        }
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
        streams[role]?.rotationDegrees = coordinator.videoRotationAngleForHorizonLevelCapture

        applyRotation()
        observeRotation()
        applyMirroring()
        attachOutputHandlers()
        refreshUniforms()

        // A device object is shared process-wide and remembers the zoom factor
        // it was last left at. Each stop *is* a lens here, so the new one starts
        // at its own nominal 1× — otherwise returning to 1× after 3× shows the
        // wide lens still cropped to the telephoto's framing.
        setZoomFactor(1, for: role, ramped: false)
    }

    // MARK: Configuration

    /// What a successful configuration produced, carried back to the main actor.
    private struct ConfigurationResult {
        let streams: [StreamRole: Stream]
        let quality: NegotiatedQuality
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
            streams[role]?.rotationDegrees = coordinator.videoRotationAngleForHorizonLevelCapture
        }
        applyRotation()
        observeRotation()
        applyMirroring()
        attachOutputHandlers()
        refreshUniforms()

        emit(.qualityNegotiated(result.quality))
        if let reason = result.quality.degradationReason {
            emit(.degraded(reason))
        }
    }

    private func configureSession(
        for configuration: CaptureConfiguration
    ) async throws -> ConfigurationResult {
        try await withCheckedThrowingContinuation { [previewLayers] continuation in
            sessionQueue.async { [session] in
                do {
                    let result = try Self.buildSession(
                        session, for: configuration, reusing: previewLayers
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
        reusing previewLayers: [StreamRole: AVCaptureVideoPreviewLayer]
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
                in: session, for: source, reusing: previewLayers[role]
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

        return ConfigurationResult(streams: built, quality: quality)
    }

    /// Builds one stream's slice of the graph: input, preview connection, data
    /// output, photo output.
    ///
    /// Shared by the full rebuild and the in-place lens switch so the two
    /// cannot drift — a connection graph assembled two slightly different ways
    /// is exactly the failure Doc 3 Phase 1 warns about.
    nonisolated private static func makeStream(
        in session: AVCaptureMultiCamSession,
        for source: CameraSource,
        reusing existingPreviewLayer: AVCaptureVideoPreviewLayer?
    ) throws -> Stream {
        guard let device = AVCaptureDevice.default(
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

        guard let port = input.ports(
            for: .video,
            sourceDeviceType: source.deviceType,
            sourceDevicePosition: source.position
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
        let dataOutput = AVCaptureVideoDataOutput()
        dataOutput.alwaysDiscardsLateVideoFrames = true
        dataOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]

        guard session.canAddOutput(dataOutput) else {
            throw CaptureError.connectionRejected("data output for \(source.displayName)")
        }
        session.addOutputWithNoConnections(dataOutput)

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
        let photoOutput = AVCapturePhotoOutput()
        var attachedPhotoOutput: AVCapturePhotoOutput?
        if session.canAddOutput(photoOutput) {
            session.addOutputWithNoConnections(photoOutput)
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
            dataOutput: dataOutput,
            photoOutput: attachedPhotoOutput,
            textureSize: textureSize(of: device)
        )
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
        isMultiCam: Bool
    ) throws -> Stream {
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
        if let dataOutput = previous.dataOutput { session.removeOutput(dataOutput) }
        if let photoOutput = previous.photoOutput { session.removeOutput(photoOutput) }

        var stream = try makeStream(in: session, for: source, reusing: previous.previewLayer)
        try applyFormat(
            to: stream.device,
            resolution: resolution,
            frameRate: frameRate,
            isMultiCam: isMultiCam,
            source: source
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
        device.activeFormat = format

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
                    // The *capture* angle differs from the preview angle on the
                    // front module, and the recorded file needs the capture one.
                    if let captureAngle = self?.rotationCoordinators[role]?
                        .videoRotationAngleForHorizonLevelCapture {
                        self?.streams[role]?.rotationDegrees = captureAngle
                        self?.refreshUniforms()
                    }
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
                    device.ramp(toVideoZoomFactor: clamped, withRate: 8)
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
        return present.map { ZoomStop(label: $0.zoomLabel, zoomFactor: nominalZoom(for: $0), source: $0) }
    }

    nonisolated private func nominalZoom(for source: CameraSource) -> CGFloat {
        switch source {
        case .rearUltraWide: 0.5
        case .rearWide, .front: 1
        case .rearTelephoto: 3
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

    /// Doc 1 §5.3.6: one audio input per session.
    private func attachAudio() {
        guard audioInput == nil, let device = AVCaptureDevice.default(for: .audio) else { return }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { return }

            session.beginConfiguration()
            defer { session.commitConfiguration() }

            session.addInputWithNoConnections(input)

            let output = AVCaptureAudioDataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutputWithNoConnections(output)

            guard let port = input.ports(for: .audio, sourceDeviceType: nil, sourceDevicePosition: .unspecified).first
            else { return }

            let connection = AVCaptureConnection(inputPorts: [port], output: output)
            guard session.canAddConnection(connection) else { return }
            session.addConnection(connection)

            let handler = AudioOutputHandler { [weak self] sample in
                self?.recorder.appendAudio(sample)
            }
            output.setSampleBufferDelegate(handler, queue: audioQueue)

            audioInput = input
            audioHandler = handler
            Log.recording.info("Audio input attached")
        } catch {
            // Doc 3 error-handling rule: a missing microphone degrades to a
            // silent recording, it does not fail the session.
            Log.recording.error("Audio attach failed: \(error.localizedDescription, privacy: .public)")
        }
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
            // Per-device, from `RotationCoordinator`. Hard-coding 90° works for
            // the rear module and lands the front one upside down, because the
            // two sensors are not mounted in the same orientation.
            primaryRotation: primary?.rotationDegrees ?? 90,
            secondaryRotation: secondary?.rotationDegrees ?? 90,
            primaryIsMirrored: primary?.source.prefersMirroring == true && configuration.mirrorsFrontCamera,
            secondaryIsMirrored: secondary?.source.prefersMirroring == true && configuration.mirrorsFrontCamera,
            primaryFormat: photoFormat ?? .biplanar,
            secondaryFormat: photoFormat ?? .biplanar,
            hasSecondary: secondary != nil,
            overlayCentre: composition.overlayCentre,
            overlayWidthFraction: composition.overlayWidthFraction,
            splitRatio: composition.splitRatio,
            diagonalAngle: composition.diagonalAngle
        )

        compositionState.update(uniforms: CompositionUniforms(inputs), outputSize: outputSize)
    }

    /// Portrait output at the negotiated tier. The app is portrait-only until
    /// Doc 3 Phase 8, so the composited frame is the tier's dimensions swapped.
    private func outputSize(for resolution: Resolution) -> CGSize {
        let dims = resolution.dimensions
        return CGSize(width: CGFloat(dims.height), height: CGFloat(dims.width))
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

        AudioSessionConfigurator.configureForRecording()
        AudioSessionConfigurator.selectDataSource(
            matching: configuration.primarySource.position
        )
        attachAudio()
        attachOutputHandlers()

        pairer.reset()
        pairer.updateFrameRate(negotiatedQuality.frameRate)
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
            hasAudio: audioInput != nil
        )
        return url
    }

    func stopRecording() async -> RecordingResult? {
        let cleanSources = await cleanRecorder.finish()
        var result = await recorder.finish()
        result?.cleanSourceFileNames = cleanSources
        governor.resetAfterRecording()
        AudioSessionConfigurator.deactivate()

        if let result {
            Log.recording.info(
                "Pairing: \(self.pairer.pairedCount) paired, \(self.pairer.unpairedCount) unpaired (\(String(format: "%.2f", self.pairer.unpairedFraction * 100))%)"
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
            lines.append("   device:     \(stream.device.localizedName)")
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
