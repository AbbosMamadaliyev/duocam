import Observation
import os
import SwiftUI

/// Everything the camera screen needs to know, and the only thing that talks to
/// the capture engine.
///
/// Doc 3 cross-phase rule: view models are `@MainActor` observable objects; the
/// capture layer is isolated behind `CaptureEngine`. Views read this and never
/// reach past it.
@MainActor
@Observable
final class CameraViewModel {
    // MARK: Capture state

    private(set) var engine: any CaptureEngine
    private(set) var status: CaptureEngineStatus = .idle
    private(set) var negotiatedQuality: NegotiatedQuality = .placeholder
    private(set) var availableModes: [CaptureMode] = [.single]

    var configuration: CaptureConfiguration {
        didSet {
            guard configuration != oldValue else { return }
            Task { await engine.apply(configuration) }
        }
    }

    // MARK: Recording state

    private(set) var isRecording = false
    private(set) var isPaused = false
    private(set) var elapsed: TimeInterval = 0
    private var recordingTimer: Task<Void, Never>?

    // MARK: Chrome state

    /// Where the user parked the floating overlay, in unit coordinates of the
    /// screen (0…1). `nil` until they move it, which resolves to the
    /// control-aware default corner.
    ///
    /// Unit rather than absolute so the placement survives a rotation, a pinch
    /// resize, and a different device class.
    var overlayCentreUnit: CGPoint?
    var overlayWidthFraction: CGFloat = 0.32

    /// 0.3…0.7 (Doc 2 §5.7).
    var splitRatio: CGFloat = 0.5
    /// −30°…+30°.
    var diagonalAngle: Double = 0

    var activeSheet: CameraSheet?
    var isShowingGallery = false
    var focusIndicator: FocusIndicator?
    var isChromeDimmed = false
    var areZoomPillsVisible = true
    var subModeLabelVisible = false

    let toasts = ToastCenter()

    /// The media library. Optional because a failed SwiftData stack must not
    /// prevent the camera from running — Doc 3's rule is that failures degrade.
    /// Doc 3 Phase 7 task 3: the *only* thing that decides whether a Pro
    /// feature may be used. Views ask this, never StoreKit.
    var entitlements: EntitlementGate?

    private(set) var library: CaptureLibrary?
    private(set) var lastCapture: CaptureRecord?
    /// Untracked on purpose: it is written on every frame of an overlay drag,
    /// and no view reads it.
    @ObservationIgnored private var lastComposition: CompositionParameters?

    /// Whether finished captures are copied into the system photo library as
    /// well as the in-app one. On by default.
    ///
    /// The in-app gallery is DuoCam's own copy; Photos is where people actually
    /// go to look for what they just shot, and a recording that never arrives
    /// there reads as a recording that was lost.
    var savesToPhotoLibrary: Bool = CameraViewModel.storedSavesToPhotoLibrary {
        didSet {
            UserDefaults.standard.set(savesToPhotoLibrary, forKey: Self.savesToPhotoLibraryKey)
        }
    }

    private static let savesToPhotoLibraryKey = "capture.savesToPhotoLibrary"

    private static var storedSavesToPhotoLibrary: Bool {
        UserDefaults.standard.object(forKey: savesToPhotoLibraryKey) as? Bool ?? true
    }

    /// Doc 3 Phase 5: what this device can genuinely record. Populated once,
    /// then read synchronously by the Quality sheet.
    private(set) var blockedCombinations: [QualityCombination: QualityBlockReason] = [:]

    /// Doc 2 §8: double-tapping the preview toggles chrome entirely.
    var isChromeHidden = false

    // MARK: Phase F state

    var selfTimer: SelfTimer = .off
    private(set) var timerRemaining: Int?
    private(set) var isCaptureFlashing = false
    private(set) var isScreenFlashing = false
    private(set) var burstProgress: Double = 0
    let level = LevelMotionProvider()
    let performance = PerformanceMonitor()

    /// Doc 3 Phase 4 task 19: the screen is the only light source a
    /// front-primary capture has.
    var usesScreenFlash: Bool {
        configuration.primarySource == .front && configuration.flashMode != .off
    }

    // MARK: Init

    /// The capability report, kept so the constraint matrix can be probed
    /// lazily rather than blocking the launch budget.
    var capabilityReport: CapabilityReport?

    init(engine: any CaptureEngine, availableModes: [CaptureMode], library: CaptureLibrary? = nil) {
        self.engine = engine
        self.configuration = Self.initialConfiguration(availableModes: availableModes)
        self.availableModes = availableModes
        self.library = library
    }

    private static func initialConfiguration(availableModes: [CaptureMode]) -> CaptureConfiguration {
        var config = CaptureConfiguration.default
        // Doc 1 §3.2 makes Front + Back the launch default, but only where the
        // hardware genuinely offers it.
        if !availableModes.contains(config.mode) {
            config.apply(mode: availableModes.first ?? .single)
        }
        return config
    }

    // MARK: Lifecycle

    func start() async {
        await engine.start()
        if DebugFlags.showsPerformanceHUD { performance.start(engine: engine) }
        applyDebugOverrides()
        await dumpSelfCheckIfRequested()
        await observeEngine()
    }

    /// Doc 3 Phase 5 task 2.
    ///
    /// Triggered when the Quality sheet opens, never at launch. Probing builds
    /// ~27 throwaway `AVCaptureMultiCamSession`s and locks each device for
    /// configuration; doing that alongside a live session starves it. Measured
    /// on a fresh install, where nothing is cached yet: recording delivered
    /// 34 frames in 6 s instead of 180. It is a one-time, per-model cost, so
    /// paying it when the user asks to *see* the table is both cheap and
    /// correctly timed.
    func probeQualityMatrix() {
        guard let capabilityReport, !isRecording, blockedCombinations.isEmpty else { return }
        Task.detached(priority: .utility) { [matrix = Self.qualityMatrix] in
            await matrix.probe(report: capabilityReport)
            let blocked = await matrix.allBlocked()
            await MainActor.run { [weak self] in
                self?.blockedCombinations = blocked
                if DebugFlags.dumpsQualityMatrix {
                    self?.dumpQualityMatrix(blocked, report: capabilityReport)
                }
            }
        }
    }

    private static let qualityMatrix = QualityConstraintMatrix()

    private func dumpQualityMatrix(
        _ blocked: [QualityCombination: QualityBlockReason],
        report: CapabilityReport
    ) {
        var lines = ["═══ DuoCam quality matrix ═══", "model: \(report.deviceModel)"]
        for mode in report.availableModes {
            lines.append("── \(mode.displayName) ──")
            for resolution in Resolution.allCases {
                let cells = FrameRate.allCases.map { rate -> String in
                    let key = QualityCombination(mode: mode, resolution: resolution, frameRate: rate)
                    return blocked[key] == nil ? "\(rate.rawValue)✓" : "\(rate.rawValue)✗"
                }
                lines.append("   \(resolution.displayName.padding(toLength: 6, withPad: " ", startingAt: 0)) \(cells.joined(separator: "  "))")
            }
        }
        for (combination, reason) in blocked.sorted(by: { encodeKey($0.key) < encodeKey($1.key) }) {
            lines.append("   ✗ \(combination.mode.rawValue) \(combination.resolution.rawValue) @\(combination.frameRate.rawValue): "
                         + reason.message(resolution: combination.resolution, frameRate: combination.frameRate, mode: combination.mode))
        }
        lines.append("═════════════════════════════")

        let text = lines.joined(separator: "\n")
        print(text)
        fflush(stdout)
        try? text.write(
            to: RecordingController.mediaDirectory.appending(path: "quality-matrix.txt"),
            atomically: true, encoding: .utf8
        )
    }

    private func encodeKey(_ c: QualityCombination) -> String {
        "\(c.mode.rawValue)|\(c.resolution.rawValue)|\(c.frameRate.rawValue)"
    }

    /// The reason a combination is unavailable, or `nil` when it is offered.
    func blockReason(resolution: Resolution, frameRate: FrameRate) -> String? {
        let combination = QualityCombination(
            mode: configuration.mode, resolution: resolution, frameRate: frameRate
        )
        return blockedCombinations[combination]?.message(
            resolution: resolution, frameRate: frameRate, mode: configuration.mode
        )
    }

    /// Hardware evidence for Doc 3 Phase 1 (DEBUG only, no-op elsewhere).
    private func dumpSelfCheckIfRequested() async {
        guard DebugFlags.dumpsSelfCheck, let multiCam = engine as? MultiCamCaptureEngine else { return }
        // Rotation is applied by `RotationCoordinator` asynchronously; reading
        // the graph immediately would report an angle that has not settled.
        try? await Task.sleep(for: .seconds(2))
        print(multiCam.hardwareSelfCheck())
        fflush(stdout)
    }

    /// Debug-only entry points into states the simulator cannot be tapped into.
    /// Inert in release builds — every flag reads `false`/`nil` there.
    private func applyDebugOverrides() {
        if let mode = DebugFlags.forcedMode, availableModes.contains(mode) {
            configuration.apply(mode: mode)
        }
        if let layout = DebugFlags.forcedLayout {
            configuration.layout = layout
        }
        if DebugFlags.startsSwapped {
            swapStreams()
        }
        if let resolution = DebugFlags.forcedResolution {
            configuration.quality.resolution = resolution
        }
        if let frameRate = DebugFlags.forcedFrameRate {
            configuration.quality.frameRate = frameRate
        }
        if DebugFlags.startsRecording || DebugFlags.startsPaused {
            startRecording()
            elapsed = 92
            if DebugFlags.startsPaused { isPaused = true }
        }
        if let sheet = DebugFlags.forcedSheet {
            activeSheet = sheet
        }
        if DebugFlags.cleanSources {
            configuration.quality.savesCleanSources = true
        }
        if DebugFlags.recordTestSeconds > 0 {
            runRecordTest(seconds: DebugFlags.recordTestSeconds)
        }
        if DebugFlags.photoTest {
            runPhotoTest()
        }
        if DebugFlags.lensSwitchTest {
            runLensSwitchTest()
        }
    }

    /// Walks every rear lens, dumping the connection graph after each switch.
    ///
    /// What to read in the output: the secondary stream's frame count must keep
    /// climbing across all three switches — that is the difference between
    /// changing one stream's lens and restarting the whole session, which is
    /// what made every zoom change flash the screen black.
    private func runLensSwitchTest() {
        Task {
            try? await Task.sleep(for: .seconds(2))
            guard let multiCam = engine as? MultiCamCaptureEngine else { return }

            print("═══ lens switch test · before ═══")
            print(multiCam.hardwareSelfCheck())

            // Every stop, up and back down, and then the two ends against each
            // other. The ends are the interesting pair: skipping the middle stop
            // is the one move that changes device *and* crosses a lens boundary
            // inside the device being left, in both directions.
            let stops = engine.availableZoomStops(for: .primary)
            let extremes = [stops.first, stops.last, stops.first, stops.last].compactMap { $0 }
            for stop in stops + stops.reversed().dropFirst() + extremes {
                selectZoom(ZoomPillGroup.Stop(label: stop.label, zoomFactor: stop.zoomFactor))
                try? await Task.sleep(for: .seconds(2))
                print("═══ lens switch test · after \(stop.label) ═══")
                print(multiCam.hardwareSelfCheck())
            }
            fflush(stdout)
        }
    }

    /// Captures one still and reports what the photo path produced.
    private func runPhotoTest() {
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            do {
                let photo = try await engine.capturePhoto()
                let record = await library?.savePhoto(
                    photo,
                    mode: configuration.mode,
                    layout: configuration.layout,
                    quality: negotiatedQuality
                )
                let report = """
                ═══ DuoCam photo test ═══
                file:       \(record?.compositedFileName ?? "not saved")
                size:       \(ByteCountFormatter.string(fromByteCount: Int64(photo.jpegData.count), countStyle: .file))
                pixels:     \(photo.width)×\(photo.height)
                mode:       \(configuration.mode.displayName)
                layout:     \(configuration.layout.rawValue)
                ═════════════════════════
                """
                print(report)
                fflush(stdout)
                try? report.write(
                    to: RecordingController.mediaDirectory.appending(path: "photo-test.txt"),
                    atomically: true, encoding: .utf8
                )
            } catch {
                print("PHOTO TEST FAILED: \(error.localizedDescription)")
                fflush(stdout)
            }
        }
    }

    /// Records for a fixed duration and reports what the pipeline produced.
    private func runRecordTest(seconds: Double) {
        Task {
            // Let the first configuration settle so the test measures steady
            // state rather than session start-up.
            try? await Task.sleep(for: .seconds(1))
            startRecording()

            try? await Task.sleep(for: .seconds(seconds))
            guard isRecording else {
                print("RECORD TEST: recording never started")
                fflush(stdout)
                return
            }

            recordingTimer?.cancel()
            isRecording = false
            let result = await engine.stopRecording()

            guard let result else {
                print("RECORD TEST: no result — writer failed")
                fflush(stdout)
                return
            }

            let record = await library?.save(
                result,
                mode: configuration.mode,
                layout: configuration.layout,
                quality: negotiatedQuality
            )

            let attributes = try? FileManager.default.attributesOfItem(atPath: result.url.path)
            let bytes = (attributes?[.size] as? Int) ?? 0

            let report = """
            ═══ DuoCam record test ═══
            file:       \(result.url.lastPathComponent)
            size:       \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
            duration:   \(String(format: "%.2f", result.duration))s (requested \(String(format: "%.1f", seconds))s)
            frames:     \(result.framesAppended) appended, \(result.framesDropped) dropped
            unpaired:   \(String(format: "%.2f", engine.unpairedFrameFraction * 100))% of frames had no overlay partner
            drop rate:  \(String(format: "%.3f", result.dropFraction * 100))%  (budget 0.100%)
            gpu/frame:  \(String(format: "%.2f", (engine as? MultiCamCaptureEngine)?.performanceSnapshot().gpuMilliseconds ?? 0)) ms  (budget 6.00 ms)
            memory:     \(String(format: "%.0f", PerformanceMonitor.footprintMegabytes())) MB  (budget 400 MB)
            layout:     \(configuration.layout.rawValue)
            mode:       \(configuration.mode.displayName)
            quality:    \(negotiatedQuality.resolution.displayName) @ \(negotiatedQuality.frameRate.displayName)
            thumbnail:  \(record?.thumbnailFileName ?? "none")
            clean src:  \(result.cleanSourceFileNames.isEmpty ? "off" : result.cleanSourceFileNames.map { "\($0.key.rawValue)=\($0.value)" }.joined(separator: ", "))
            directory:  \(RecordingController.mediaDirectory.path)
            ══════════════════════════
            """

            if let multiCam = engine as? MultiCamCaptureEngine {
                print(multiCam.hardwareSelfCheck())
            }
            print(report)
            fflush(stdout)
            // `simctl launch --console-pty` drops output unpredictably, so the
            // report is also written where it can always be read back.
            try? report.write(
                to: RecordingController.mediaDirectory.appending(path: "record-test.txt"),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    func stop() async {
        recordingTimer?.cancel()
        await engine.stop()
    }

    private func observeEngine() async {
        for await event in engine.events {
            switch event {
            case .statusChanged(let newStatus):
                status = newStatus
                if case .interrupted(let reason) = newStatus {
                    toasts.show(reason, systemImage: "pause.circle", isWarning: true)
                }
                if case .failed(let message) = newStatus {
                    toasts.show(message, systemImage: "exclamationmark.triangle.fill", isWarning: true)
                }

            case .qualityNegotiated(let quality):
                negotiatedQuality = quality

            case .degraded(let reason):
                // Doc 2 §13: the ladder runs silently; only the final result is
                // surfaced, via the pill and exactly one toast.
                toasts.show(reason.userFacingMessage, systemImage: "arrow.down.circle", isWarning: true)
                HapticEngine.shared.warning()

            case .thermalStateChanged(let state):
                handleThermalState(state)

            case .recoverableFailure(let message):
                toasts.show(message, systemImage: "exclamationmark.triangle.fill", isWarning: true)
                HapticEngine.shared.error()
            }
        }
    }

    private func handleThermalState(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .serious:
            toasts.show("Reducing quality to keep recording", systemImage: "thermometer.high", isWarning: true)
            HapticEngine.shared.warning()
        case .critical:
            if isRecording { stopRecording() }
            toasts.show("Recording stopped — device too warm", systemImage: "thermometer.high", isWarning: true)
        default:
            break
        }
    }

    // MARK: Derived presentation state

    var shutterState: ShutterState {
        guard status.isRunning || isRecording else { return .disabled }
        if isRecording { return isPaused ? .videoPaused : .videoRecording }
        return configuration.photoVideoMode == .photo ? .photoIdle : .videoIdle
    }

    var hasSecondaryStream: Bool {
        configuration.mode.isDual && engine.previewSource(for: .secondary) != nil
    }

    var zoomStops: [ZoomPillGroup.Stop] {
        engine.availableZoomStops(for: .primary).map {
            ZoomPillGroup.Stop(label: $0.label, zoomFactor: $0.zoomFactor)
        }
    }

    /// Which pill reads as chosen.
    ///
    /// Driven by the magnification rather than by the lens, so it settles the
    /// instant the tap lands instead of waiting for the hardware to finish
    /// changing lenses — and so it stays honest at magnifications no lens sits
    /// exactly at, where the nearest stop is the truthful answer.
    var selectedZoomStop: String {
        let zoom = configuration.primaryZoom
        return zoomStops
            .min { abs($0.zoomFactor - zoom) < abs($1.zoomFactor - zoom) }?
            .id ?? configuration.primarySource.zoomLabel
    }

    func geometry(screenSize: CGSize, safeTop: CGFloat, safeBottom: CGFloat) -> LayoutGeometry {
        LayoutGeometry(
            screenSize: screenSize,
            safeTop: safeTop,
            safeBottom: safeBottom,
            isRecording: isRecording,
            isDualMode: configuration.mode.isDual,
            layout: configuration.layout,
            overlayWidthFraction: overlayWidthFraction,
            showsZoomPills: areZoomPillsVisible && !zoomStops.isEmpty
        )
    }

    // MARK: Actions — mode, layout, sources

    func select(mode: CaptureMode) {
        guard mode != configuration.mode else { return }
        configuration.apply(mode: mode)
        extinguishTorchIfUnavailable()
        HapticEngine.shared.modeChanged()
    }

    func select(layout: LayoutType) {
        guard layout != configuration.layout else { return }
        // Doc 1 §4.5 gates split and diagonal behind Pro.
        if layout.isSplit, entitlements?.require(.splitLayouts) == false { return }
        configuration.layout = layout
        HapticEngine.shared.layoutSelected()
    }

    /// Applies a quality change through the gate.
    ///
    /// Routed here rather than mutating `configuration.quality` from the sheet
    /// so 4K and 60 fps cannot be reached by a code path that forgot to check.
    func selectResolution(_ resolution: Resolution) {
        if resolution == .uhd4K, entitlements?.require(.resolution4K) == false { return }
        configuration.quality.resolution = resolution
    }

    func selectFrameRate(_ frameRate: FrameRate) {
        if frameRate == .fps60, entitlements?.require(.frameRate60) == false { return }
        configuration.quality.frameRate = frameRate
    }

    func setSavesCleanSources(_ enabled: Bool) {
        if enabled, entitlements?.require(.cleanSourceFiles) == false { return }
        configuration.quality.savesCleanSources = enabled
    }

    /// Doc 2 §5.6: a pure presentation change. Both streams stay live, so this
    /// deliberately does *not* go through a session reconfiguration — and it
    /// works identically during recording.
    func swapStreams() {
        guard hasSecondaryStream else {
            HapticEngine.shared.error()
            return
        }
        configuration.swapStreams()
        extinguishTorchIfUnavailable()
        HapticEngine.shared.streamsSwapped()
    }

    /// Puts the torch out when the lens that owned it stops being primary.
    ///
    /// Without this, swapping to the front camera leaves the rear LED burning
    /// with no control on screen that can turn it off — the user's only way out
    /// is to swap back or quit the app.
    ///
    /// Tested against `configuration` rather than `engine.isTorchAvailable`:
    /// the engine is handed the new configuration asynchronously, so at this
    /// point it still reports the outgoing lens.
    private func extinguishTorchIfUnavailable() {
        guard configuration.isTorchOn, !configuration.primarySource.hasTorch else { return }
        setTorch(enabled: false)
    }

    func toggleFlash() {
        configuration.flashMode = configuration.flashMode.next
        HapticEngine.shared.sliderDetent()
    }

    /// Whether the torch can be lit for the stream that is currently primary.
    var isTorchAvailable: Bool { engine.isTorchAvailable }

    /// The video-mode counterpart to `toggleFlash`.
    ///
    /// It refuses out loud rather than silently. `setTorch` is a no-op on a
    /// front-primary session — there is no LED the front camera can see — and
    /// a control that lights up while doing nothing is worse than one that
    /// explains why it can't.
    func toggleTorch() {
        guard isTorchAvailable else {
            toasts.show(
                configuration.primarySource.hasTorch
                    ? "The torch isn't available right now"
                    : "The front camera has no torch — it uses the screen as its flash",
                systemImage: "flashlight.off.fill",
                isWarning: true
            )
            HapticEngine.shared.error()
            return
        }
        setTorch(enabled: !configuration.isTorchOn)
        HapticEngine.shared.sliderDetent()
    }

    func setPhotoVideoMode(_ mode: PhotoVideoMode) {
        guard !isRecording, mode != configuration.photoVideoMode else { return }
        configuration.photoVideoMode = mode
        // Photo mode's top control is Flash, which means the torch loses its
        // switch on the way in. Leaving the LED burning behind a control that
        // is no longer on screen is the same stranding as swapping to the front
        // camera with it on.
        if mode == .photo, configuration.isTorchOn { setTorch(enabled: false) }
        HapticEngine.shared.subModeChanged()
        showSubModeLabel()
    }

    private func showSubModeLabel() {
        subModeLabelVisible = true
        Task {
            try? await Task.sleep(for: .seconds(DC.Duration.subModeLabel))
            subModeLabelVisible = false
        }
    }

    // MARK: Actions — shutter

    func triggerShutter() {
        switch configuration.photoVideoMode {
        case .photo:
            capturePhoto()
        case .video:
            isRecording ? stopRecording() : startRecording()
        }
    }

    private func capturePhoto() {
        Task { await runCapture() }
    }

    /// Runs the self-timer, the screen flash, the capture, and the save.
    private func runCapture() async {
        if selfTimer != .off {
            for remaining in stride(from: selfTimer.rawValue, through: 1, by: -1) {
                timerRemaining = remaining
                HapticEngine.shared.sliderDetent()
                try? await Task.sleep(for: .seconds(1))
            }
            timerRemaining = nil
        }

        // The screen has to be white *before* the exposure, not after.
        if usesScreenFlash {
            isScreenFlashing = true
            try? await Task.sleep(for: .milliseconds(120))
        }
        defer { isScreenFlashing = false }

        do {
            let photo = try await engine.capturePhoto()
            HapticEngine.shared.captureTaken()
            flashCapture()
            lastCapture = await library?.savePhoto(
                photo,
                mode: configuration.mode,
                layout: configuration.layout,
                quality: negotiatedQuality
            )
            toasts.show("Photo saved", systemImage: "checkmark.circle.fill")

            if let url = lastCapture?.compositedURL {
                await copyToPhotoLibrary(url, isPhoto: true)
            }
        } catch {
            toasts.show(error.localizedDescription, systemImage: "exclamationmark.triangle.fill", isWarning: true)
            HapticEngine.shared.error()
        }
    }

    private func flashCapture() {
        isCaptureFlashing = true
        Task {
            try? await Task.sleep(for: .seconds(DC.Duration.captureFlash))
            isCaptureFlashing = false
        }
    }

    // MARK: Phase F — manual controls and lenses

    func applyManualControl(_ control: ManualControl, to role: StreamRole) {
        engine.setManualControl(control, for: role)
    }

    func setTorch(enabled: Bool, level: Float = 1) {
        configuration.isTorchOn = enabled
        engine.setTorch(enabled: enabled, level: level)
    }

    func setSource(_ source: CameraSource, for role: StreamRole) {
        switch role {
        case .primary: configuration.primarySource = source
        case .secondary: configuration.secondarySource = source
        }
        extinguishTorchIfUnavailable()
    }

    func toggleGrid() {
        configuration.showsGrid.toggle()
        HapticEngine.shared.sliderDetent()
    }

    func toggleLevel() {
        configuration.showsLevel.toggle()
        if configuration.showsLevel { level.start() } else { level.stop() }
        HapticEngine.shared.sliderDetent()
    }

    func startRecording() {
        guard !isRecording else { return }

        Task {
            do {
                _ = try await engine.startRecording()
            } catch {
                // Doc 3 error-handling rule: every failure has a user-facing
                // message and degrades rather than crashing.
                toasts.show(
                    error.localizedDescription,
                    systemImage: "exclamationmark.triangle.fill",
                    isWarning: true
                )
                HapticEngine.shared.error()
                return
            }

            isRecording = true
            isPaused = false
            elapsed = 0
            HapticEngine.shared.recordingStarted()
            startElapsedTimer()
        }
    }

    /// A wall-clock tick rather than a count of appended frames: the readout
    /// must show the take's real duration even while the governor is dropping
    /// frame rate underneath it.
    private func startElapsedTimer() {
        recordingTimer?.cancel()
        recordingTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, self.isRecording, !self.isPaused else { continue }
                self.elapsed += 0.2
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        recordingTimer?.cancel()
        recordingTimer = nil
        isRecording = false
        isPaused = false
        HapticEngine.shared.recordingStopped()

        Task {
            guard let result = await engine.stopRecording() else {
                toasts.show("Recording could not be saved", systemImage: "exclamationmark.triangle.fill", isWarning: true)
                return
            }

            lastCapture = await library?.save(
                result,
                mode: configuration.mode,
                layout: configuration.layout,
                quality: negotiatedQuality
            )

            toasts.show("Recording saved", systemImage: "checkmark.circle.fill")

            // After the toast, not before: copying a 4K take into Photos takes
            // long enough that gating the confirmation on it would read as the
            // save having hung.
            await copyToPhotoLibrary(result.url, isPhoto: false)

            if result.dropFraction > 0.001 {
                Log.recording.notice(
                    "Drop rate \(String(format: "%.2f", result.dropFraction * 100))% exceeded the 0.1% budget"
                )
            }
        }
    }

    /// Copies a finished capture into the system photo library.
    ///
    /// Only a failure is surfaced: the success case is already covered by the
    /// "saved" toast, and two confirmations for one capture is noise.
    private func copyToPhotoLibrary(_ url: URL, isPhoto: Bool) async {
        guard savesToPhotoLibrary else { return }
        let saved = await PhotoLibraryExporter.saveToPhotos(url, isPhoto: isPhoto)
        guard !saved else { return }
        toasts.show(
            "Couldn't save to Photos — check photo access in Settings",
            systemImage: "exclamationmark.triangle.fill",
            isWarning: true
        )
    }

    func togglePause() {
        guard isRecording else { return }
        isPaused.toggle()
        if isPaused { engine.pauseRecording() } else { engine.resumeRecording() }
        HapticEngine.shared.recordingPauseToggled()
    }

    /// Doc 2 §7.2: a full-resolution still without interrupting the recording.
    func captureStillDuringVideo() {
        HapticEngine.shared.stillDuringVideo()
        flashCapture()
        Task { await runCapture() }
    }

    /// Pushes the on-screen overlay geometry down to the compositor.
    ///
    /// Doc 3 Phase 2's first acceptance criterion is that the recorded file
    /// matches the on-screen preview *exactly*, and the only way to guarantee
    /// that is for both to read the same numbers. `LayoutGeometry` owns them;
    /// this hands them across.
    func syncComposition(with geometry: LayoutGeometry) {
        pushComposition(overlayCentre: geometry.overlayCentre(for: overlayCentreUnit), geometry: geometry)
    }

    private func pushComposition(overlayCentre centre: CGPoint, geometry: LayoutGeometry) {
        let parameters = CompositionParameters(
            layout: configuration.layout,
            overlayCentre: geometry.unitCentre(for: centre),
            overlayWidthFraction: overlayWidthFraction,
            splitRatio: splitRatio,
            diagonalAngle: diagonalAngle
        )
        guard parameters != lastComposition else { return }
        lastComposition = parameters
        engine.updateComposition(parameters)
    }

    // MARK: Actions — focus and zoom

    func focus(at point: CGPoint, normalized: CGPoint, in role: StreamRole) {
        engine.focusAndExpose(at: normalized, in: role)
        focusIndicator = FocusIndicator(point: point, role: role, isLocked: false)
        scheduleFocusIndicatorDismissal()
    }

    func lockFocus(at point: CGPoint, normalized: CGPoint, in role: StreamRole) {
        engine.lockFocusAndExposure(at: normalized, in: role)
        focusIndicator = FocusIndicator(point: point, role: role, isLocked: true)
        HapticEngine.shared.focusLocked()
        scheduleFocusIndicatorDismissal()
    }

    func setExposureBias(_ bias: Float) {
        engine.setExposureBias(bias, for: .primary)
        focusIndicator?.exposureBias = bias
    }

    private func scheduleFocusIndicatorDismissal() {
        Task { [id = focusIndicator?.id] in
            try? await Task.sleep(for: .seconds(DC.Duration.reticleDwell))
            guard focusIndicator?.id == id, focusIndicator?.isLocked == false else { return }
            focusIndicator = nil
        }
    }

    /// A stop is a *magnification*, and the lens is how the engine reaches it.
    ///
    /// The distinction is the whole fix for the zoom that changed by going
    /// black. A stop used to be a lens and nothing else, so tapping one was a
    /// source change: teardown, rebuild, and a screen that cut from one field
    /// of view to another with a black frame in between. Asking for a
    /// magnification instead lets the engine ride the lens it already has to
    /// meet the one taking over, and hand off between two identical frames.
    ///
    /// The lens is still named here, because only the view model knows what the
    /// *other* stream is holding — and a rear + rear session cannot open a
    /// second input on a device it already has open.
    func selectZoom(_ stop: ZoomPillGroup.Stop) {
        let source = engine.availableZoomStops(for: .primary)
            .first { $0.label == stop.label }?
            .source

        // One write, so the engine sees the lens and the magnification together
        // and can plan a single continuous movement between them.
        var updated = configuration

        if let source, source == updated.secondarySource {
            // Rear + Rear, where the requested lens is already live as the
            // other stream. A session will not accept a second input for one
            // device, so this is a swap rather than a lens change: the
            // requested lens takes the screen and the current one moves to the
            // overlay. Assigning it to both roles instead fails `canAddInput`
            // and leaves the session with no streams at all.
            updated.swapStreams()
        } else if let source {
            updated.primarySource = source
        }
        updated.primaryZoom = stop.zoomFactor

        configuration = updated
        extinguishTorchIfUnavailable()
        HapticEngine.shared.sliderDetent()
    }

    // MARK: Actions — overlay

    /// Commits a finished drag. One observable write, at the end of the gesture.
    func placeOverlay(atUnit unit: CGPoint) {
        overlayCentreUnit = unit
        HapticEngine.shared.overlayPlaced()
    }

    /// Keeps the *recorded* composition following the finger during a drag.
    ///
    /// Deliberately writes nothing observable. A drag delivers events at the
    /// display's refresh rate, and mutating `@Observable` state on every one of
    /// them re-runs the camera screen's body — geometry, scrims, both preview
    /// hosts — sixty to a hundred and twenty times a second. That is the stutter
    /// the overlay used to have; the drag now lives in the view's own `@State`
    /// and only the compositor is told, which costs a uniform update.
    func trackOverlayDrag(centre: CGPoint, in geometry: LayoutGeometry) {
        pushComposition(overlayCentre: centre, geometry: geometry)
    }

    func resizeOverlay(to fraction: CGFloat) {
        let clamped = fraction.clamped(to: 0.25...0.5)
        if clamped != overlayWidthFraction {
            if clamped == 0.25 || clamped == 0.5 {
                HapticEngine.shared.resizeLimit()
            }
            overlayWidthFraction = clamped
        }
    }
}

/// The tap-to-focus reticle and its follow-up exposure track (Doc 2 §8).
nonisolated struct FocusIndicator: Identifiable, Equatable {
    let id = UUID()
    let point: CGPoint
    let role: StreamRole
    var isLocked: Bool
    var exposureBias: Float = 0
}

/// The modal surfaces the camera screen can present (Doc 2 §6).
nonisolated enum CameraSheet: String, Identifiable {
    case adjustments
    case layout
    case quality
    case settings

    var id: String { rawValue }
}
