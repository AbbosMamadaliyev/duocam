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
            // Suppressed only while the *engine's* answer is being written back
            // — see `reconcileRequestedQuality`. Handing that straight back to
            // `apply` would ask for a session rebuild to reach the state the
            // session is already in.
            guard !isReconcilingWithEngine else { return }
            Task { await engine.apply(configuration) }
        }
    }

    @ObservationIgnored private var isReconcilingWithEngine = false

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

    /// The overlay's size, as fractions of the picture. See `OverlayMetrics`.
    ///
    /// Written through `setOverlayWidth`/`setOverlayHeight` from the sheet and
    /// through `scaleOverlay` from the pinch; both clamp. Deliberately *not*
    /// persisted, unlike `overlayBorder`: a size only means something next to
    /// the layout it was chosen for, and the layout resets to `pipRounded` at
    /// every launch, so a restored size would arrive attached to the wrong
    /// shape.
    var overlayWidthFraction: CGFloat = 0.32
    var overlayHeightFraction: CGFloat = 0.24

    /// The overlay's border — corner radius, thickness and colour.
    ///
    /// Persisted, like `savesToPhotoLibrary`: it is a look the user chose for
    /// their footage, not a per-session mood, and re-picking it at every launch
    /// would make it not worth picking at all.
    ///
    /// Pushing it to the compositor is `CameraScreen`'s job rather than this
    /// setter's, because the push needs the live `LayoutGeometry` and the view
    /// is what owns that.
    var overlayBorder: OverlayBorderStyle = CameraViewModel.storedOverlayBorder {
        didSet {
            guard overlayBorder != oldValue else { return }
            let encoded = try? JSONEncoder().encode(overlayBorder)
            UserDefaults.standard.set(encoded, forKey: Self.overlayBorderKey)
        }
    }

    private static let overlayBorderKey = "overlay.borderStyle"

    private static var storedOverlayBorder: OverlayBorderStyle {
        guard let data = UserDefaults.standard.data(forKey: overlayBorderKey),
              let decoded = try? JSONDecoder().decode(OverlayBorderStyle.self, from: data)
        else { return .default }
        return decoded.sanitized
    }

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
    /// feature may be used. Views ask this, never the store.
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

    /// In-flight debounced analytics writes, keyed by control. See
    /// `analyticsSettled`.
    @ObservationIgnored var pendingSettledLogs: [String: Task<Void, Never>] = [:]

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
        if let aspectRatio = DebugFlags.forcedAspectRatio {
            configuration.aspectRatio = aspectRatio
        }
        // After the aspect ratio and through the conforming step, not by
        // assigning `configuration.layout` directly: the overlay's height is
        // the layout's to set now, and writing the layout past `select(layout:)`
        // would leave a forced `pipWide` wearing the default 3:4 proportions.
        if let layout = DebugFlags.forcedLayout {
            configuration.layout = layout
            conformOverlayToLayout()
        }
        // Through the ungated primitives: a debug launch override must not be
        // refused by the Pro gate, and must not raise the paywall on launch.
        if let width = DebugFlags.forcedOverlayWidth {
            applyOverlayWidth(width)
        }
        if let height = DebugFlags.forcedOverlayHeight {
            applyOverlayHeight(height)
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
        if DebugFlags.swapTest {
            runSwapTest()
        }
        if DebugFlags.dumpsCaptureGate {
            dumpCaptureGate()
        }
    }

    /// Runs the free-tier shutter gate over a series of presses and reports what
    /// it decided, capturing nothing.
    ///
    /// What to read in the output: `Single` must be all `pass`. `Rear + Rear`
    /// must be all `PAYWALL`. `Front + Back` must refuse the third press of each
    /// row and no other — and the photo row must not be shortened by the video
    /// row above it, which is the whole reason the two counters are separate.
    ///
    /// The ledger is left as it was found. A diagnostic that spends the user's
    /// free captures is a diagnostic that changes the thing it measures.
    private func dumpCaptureGate() {
        guard let entitlements else { return }

        let restore = entitlements.freeTier.captureAttempts

        var lines = [
            "═══ DuoCam capture gate ═══",
            "entitlement: \(entitlements.isPro ? "Pro" : "Free")",
        ]

        for mode in CaptureMode.allCases {
            lines.append("── \(mode.displayName) ──")
            for kind in CaptureKind.allCases {
                entitlements.freeTier.setCaptureAttempts([:])
                let outcomes = (1...9).map { _ in
                    entitlements.requireCapture(kind, mode: mode) ? "pass" : "PAYWALL"
                }
                lines.append("   \(kind.displayName.padding(toLength: 5, withPad: " ", startingAt: 0)) "
                             + outcomes.joined(separator: " · "))
            }
        }

        lines.append("launch reminder: every \(FreeTierLedger.launchesPerPaywall) launches, "
                     + "count now \(entitlements.freeTier.launches)")
        lines.append("═══════════════════════════")

        entitlements.freeTier.setCaptureAttempts(restore)
        // The gate raised the paywall as it went, which is the correct answer to
        // a refused press and the wrong thing to leave on screen after a print.
        entitlements.isShowingPaywall = false
        entitlements.pendingFeature = nil

        print(lines.joined(separator: "\n"))
        fflush(stdout)
    }

    /// Taps Swap twice on a running session and reports what the graph did.
    ///
    /// What to read in the output: the two streams' devices must simply trade
    /// roles. An input count that dips, a `FELL BACK` line in the switch trace,
    /// or a device that comes back the same on both sides of the swap all mean
    /// the same thing — the swap went through a session rebuild, which is the
    /// black frame the user sees.
    private func runSwapTest() {
        Task {
            try? await Task.sleep(for: .seconds(3))
            guard let multiCam = engine as? MultiCamCaptureEngine else { return }

            for pass in 1...2 {
                print("═══ swap test · before pass \(pass) ═══")
                print("config: primary=\(configuration.primarySource.rawValue) "
                      + "secondary=\(configuration.secondarySource?.rawValue ?? "none") "
                      + "zoom=\(String(format: "%.2f", configuration.primaryZoom))")
                print(multiCam.hardwareSelfCheck())
                fflush(stdout)

                swapStreams()
                try? await Task.sleep(for: .seconds(3))

                print("═══ swap test · after pass \(pass) ═══")
                print("config: primary=\(configuration.primarySource.rawValue) "
                      + "secondary=\(configuration.secondarySource?.rawValue ?? "none") "
                      + "zoom=\(String(format: "%.2f", configuration.primaryZoom))")
                print(multiCam.hardwareSelfCheck())
                fflush(stdout)
            }
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
                    analyticsEvent(AnalyticsEvent.captureSessionInterrupted, [
                        AnalyticsParam.reason: reason,
                        AnalyticsParam.duringRecording: isRecording,
                    ])
                }
                if case .failed(let message) = newStatus {
                    toasts.show(message, systemImage: "exclamationmark.triangle.fill", isWarning: true)
                    analyticsEvent(AnalyticsEvent.captureSessionFailed, [
                        AnalyticsParam.reason: message,
                        AnalyticsParam.duringRecording: isRecording,
                    ])
                }

            case .qualityNegotiated(let quality):
                negotiatedQuality = quality
                reconcileRequestedQuality(with: quality)

            case .degraded(let reason):
                // Doc 2 §13: the ladder runs silently; only the final result is
                // surfaced, via the pill and exactly one toast.
                toasts.show(reason.userFacingMessage, systemImage: "arrow.down.circle", isWarning: true)
                HapticEngine.shared.warning()
                // What the device *actually* gave, per model. This is the
                // evidence behind whether 4K/60 is worth offering at all on a
                // given class of hardware, and it exists nowhere else.
                analyticsEvent(AnalyticsEvent.qualityDegraded, [
                    AnalyticsParam.reason: String(describing: reason),
                    AnalyticsParam.duringRecording: isRecording,
                ])

            case .thermalStateChanged(let state):
                handleThermalState(state)

            case .recoverableFailure(let message):
                toasts.show(message, systemImage: "exclamationmark.triangle.fill", isWarning: true)
                HapticEngine.shared.error()
                analyticsEvent(AnalyticsEvent.captureRecoverableFailure, [
                    AnalyticsParam.reason: message,
                    AnalyticsParam.duringRecording: isRecording,
                ])
            }
        }
    }

    private func handleThermalState(_ state: ProcessInfo.ThermalState) {
        // Every transition, not only the two that act. `.fair` arriving mid-take
        // is the early warning that `.serious` is coming, and the distribution
        // across device models is what says whether the quality ceiling is set
        // too high for the hardware.
        analyticsEvent(AnalyticsEvent.thermalStateChanged, [
            AnalyticsParam.thermalState: Self.thermalName(state),
            AnalyticsParam.duringRecording: isRecording,
            AnalyticsParam.durationSeconds: elapsed,
        ])

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

    /// `ProcessInfo.ThermalState` has no `String` form, and
    /// `String(describing:)` gives an integer for an `@objc` enum — which is the
    /// kind of value that turns a dashboard row into a puzzle.
    private static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    /// Folds the engine's answer back into the request, so every surface that
    /// shows quality shows the same numbers.
    ///
    /// There used to be two truths on screen at once. The quality pill reads
    /// `negotiatedQuality` — what the hardware granted — while the Quality sheet
    /// and Settings both read `configuration.quality`, what was asked for. On any
    /// pairing that cannot deliver the request, the pill said 1080p while both
    /// lists kept a tick beside 4K: change it in one place, and the other two
    /// disagreed. Neither reading was wrong on its own, which is exactly why the
    /// mismatch was impossible to interpret.
    ///
    /// Thermal and system pressure are excluded. Those are *transient* — the
    /// governor puts the quality back when the device cools — and writing them
    /// into the request would make a warm pocket permanently lower the ceiling
    /// the user chose.
    private func reconcileRequestedQuality(with quality: NegotiatedQuality) {
        switch quality.degradationReason {
        case .thermalPressure, .systemPressure:
            return
        case nil, .hardwareCostExceeded, .formatUnavailable:
            break
        }

        guard configuration.quality.resolution != quality.resolution
                || configuration.quality.frameRate != quality.frameRate
        else { return }

        isReconcilingWithEngine = true
        configuration.quality.resolution = quality.resolution
        configuration.quality.frameRate = quality.frameRate
        isReconcilingWithEngine = false
    }

    // MARK: Derived presentation state

    /// The red button's state.
    ///
    /// Video-only now that the two shutters are separate controls: the red
    /// button records and the white one takes stills, so neither has to encode
    /// which mode the app is in. `photoIdle` therefore never appears here — it
    /// belongs to the white button, which has one appearance.
    var shutterState: ShutterState {
        guard status.isRunning || isRecording else { return .disabled }
        if isRecording { return isPaused ? .videoPaused : .videoRecording }
        return .videoIdle
    }

    /// `1080p · 30 fps`, for the one place quality is summarised rather than
    /// chosen — the Settings row that pushes the option list.
    ///
    /// Reads `negotiatedQuality`, the same value the quality pill shows, so the
    /// two cannot say different things about the same session.
    var qualitySummary: String {
        "\(negotiatedQuality.resolution.displayName) · \(negotiatedQuality.frameRate.displayName) fps"
    }

    /// The white button is live whenever the session is: during a take it
    /// captures a still without interrupting the recording (Doc 2 §7.2).
    var isPhotoButtonEnabled: Bool { status.isRunning || isRecording }

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
            aspectRatio: configuration.aspectRatio,
            overlayWidthFraction: overlayWidthFraction,
            overlayHeightFraction: overlayHeightFraction,
            showsZoomPills: areZoomPillsVisible && !zoomStops.isEmpty
        )
    }

    /// The picture's own width-to-height ratio — the conversion factor between a
    /// fraction of the frame's width and a fraction of its height.
    private var pictureAspect: CGFloat { configuration.aspectRatio.portraitAspect }

    // MARK: Actions — mode, layout, sources

    func select(mode: CaptureMode) {
        guard mode != configuration.mode else { return }
        let previous = configuration.mode
        configuration.apply(mode: mode)
        extinguishTorchIfUnavailable()
        HapticEngine.shared.modeChanged()

        Analytics.log(AnalyticsEvent.captureModeChanged, [
            AnalyticsParam.mode: mode.rawValue,
            AnalyticsParam.previousMode: previous.rawValue,
        ])
        // A user property as well as an event: which mode people *live* in is a
        // segment for every other number, and an event alone can only answer it
        // by replaying each session's history.
        Analytics.setUserProperty(mode.rawValue, for: AnalyticsUserProperty.preferredMode)
    }

    /// Every layout, free.
    ///
    /// Split and diagonal used to be gated, and the card wore a lock to say so.
    /// The gate has moved to the shutter: in both dual modes the *capture* is
    /// what is paid for now, so charging for the arrangement as well refused the
    /// same user twice for one recording — once for choosing how to frame it and
    /// again for pressing record. Arranging the two streams is also the one thing
    /// the preview exists to demonstrate, and a lock on it hides the product.
    func select(layout: LayoutType) {
        guard layout != configuration.layout else { return }
        let previous = configuration.layout
        configuration.layout = layout
        conformOverlayToLayout()
        HapticEngine.shared.layoutSelected()

        Analytics.log(AnalyticsEvent.layoutSelected, [
            AnalyticsParam.layout: layout.rawValue,
            AnalyticsParam.previousLayout: previous.rawValue,
            AnalyticsParam.mode: configuration.mode.rawValue,
        ])
        Analytics.setUserProperty(layout.rawValue, for: AnalyticsUserProperty.preferredLayout)
    }

    /// Installs the size the chosen layout stands for.
    ///
    /// Both fractions, not just the height. Each card now carries its own
    /// width as well — Wide and Circle are far larger than the tall shapes,
    /// because a 16:9 box at the tall shapes' 32% is a tenth of the frame high
    /// and a circle in the same box is a badge. Carrying the previous width
    /// across would have made choosing a card produce a different size
    /// depending on where the user had last left the slider, which is not what
    /// a preset is.
    private func conformOverlayToLayout() {
        guard configuration.layout.isPiP else { return }
        let size = OverlayMetrics.defaultSize(
            for: configuration.layout,
            pictureAspect: pictureAspect
        )
        overlayWidthFraction = size.width
        overlayHeightFraction = size.height
    }

    /// Applies a quality change through the gate.
    ///
    /// Routed here rather than mutating `configuration.quality` from the sheet
    /// so 4K and 60 fps cannot be reached by a code path that forgot to check.
    /// The three quality setters log *after* the gate, not before.
    ///
    /// A refusal already has its own event — the gate raises
    /// `feature_gate_blocked` on the way to the paywall — so logging the
    /// selection here as well would count one refused tap as both a block and a
    /// change, and 4K adoption would read as high among users who never got it.
    func selectResolution(_ resolution: Resolution) {
        if resolution == .uhd4K, entitlements?.require(.resolution4K) == false { return }
        configuration.quality.resolution = resolution
        Analytics.log(AnalyticsEvent.resolutionSelected, [
            AnalyticsParam.resolution: resolution.rawValue,
            AnalyticsParam.mode: configuration.mode.rawValue,
        ])
    }

    func selectFrameRate(_ frameRate: FrameRate) {
        if frameRate == .fps60, entitlements?.require(.frameRate60) == false { return }
        configuration.quality.frameRate = frameRate
        Analytics.log(AnalyticsEvent.frameRateSelected, [
            AnalyticsParam.frameRate: frameRate.rawValue,
            AnalyticsParam.mode: configuration.mode.rawValue,
        ])
    }

    func selectCodec(_ codec: VideoCodec) {
        guard codec != configuration.quality.codec else { return }
        configuration.quality.codec = codec
        Analytics.log(AnalyticsEvent.codecSelected, [AnalyticsParam.codec: codec.rawValue])
    }

    func setSavesCleanSources(_ enabled: Bool) {
        if enabled, entitlements?.require(.cleanSourceFiles) == false { return }
        configuration.quality.savesCleanSources = enabled
        Analytics.log(AnalyticsEvent.cleanSourcesToggled, [AnalyticsParam.enabled: enabled])
    }

    /// Doc 2 §5.6: a pure presentation change. Both streams stay live, so this
    /// deliberately does *not* go through a session reconfiguration — and it
    /// works identically during recording.
    func swapStreams(source: String = AnalyticsValue.sourceCameraChrome) {
        guard hasSecondaryStream else {
            HapticEngine.shared.error()
            // A control that is on screen and refuses is worth counting: in
            // Single mode the swap button is disabled, so every one of these is
            // a dual session whose second stream never came up.
            Analytics.log(AnalyticsEvent.streamsSwapBlocked, [
                AnalyticsParam.source: source,
                AnalyticsParam.mode: configuration.mode.rawValue,
            ])
            return
        }
        configuration.swapStreams()
        extinguishTorchIfUnavailable()
        HapticEngine.shared.streamsSwapped()

        analyticsEvent(AnalyticsEvent.streamsSwapped, [
            AnalyticsParam.source: source,
            AnalyticsParam.duringRecording: isRecording,
        ])
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
        Analytics.log(AnalyticsEvent.flashModeToggled, [
            AnalyticsParam.flashMode: configuration.flashMode.rawValue,
            AnalyticsParam.primarySource: configuration.primarySource.rawValue,
        ])
    }

    /// Whether the torch can be lit for the stream that is currently primary.
    var isTorchAvailable: Bool { engine.isTorchAvailable }

    /// The video-mode counterpart to `toggleFlash`.
    ///
    /// It refuses out loud rather than silently. `setTorch` is a no-op on a
    /// front-primary session — there is no LED the front camera can see — and
    /// a control that lights up while doing nothing is worse than one that
    /// explains why it can't.
    func toggleTorch(source: String = AnalyticsValue.sourceCameraChrome) {
        guard isTorchAvailable else {
            Analytics.log(AnalyticsEvent.torchUnavailable, [
                AnalyticsParam.source: source,
                AnalyticsParam.primarySource: configuration.primarySource.rawValue,
            ])
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
        Analytics.log(AnalyticsEvent.torchToggled, [
            AnalyticsParam.source: source,
            AnalyticsParam.enabled: configuration.isTorchOn,
            AnalyticsParam.duringRecording: isRecording,
        ])
    }

    /// Cycles the frame shape, 16:9 ↔ 4:3.
    ///
    /// Refused mid-take rather than silently ignored: the writer is committed to
    /// one canvas size for the whole file, and a control that appears to work
    /// and changes nothing is worse than one that says why it can't.
    func toggleAspectRatio() {
        guard !isRecording else {
            Analytics.log(AnalyticsEvent.aspectRatioBlocked, [
                AnalyticsParam.reason: "recording_in_progress",
                AnalyticsParam.aspectRatio: configuration.aspectRatio.rawValue,
            ])
            toasts.show(
                "The frame shape can't change while recording",
                systemImage: "aspectratio",
                isWarning: true
            )
            HapticEngine.shared.error()
            return
        }
        // The height fraction is a fraction of the *picture's* height, and
        // switching 16:9 → 4:3 makes the picture shorter. Left alone, the
        // overlay would keep its share of a frame that changed underneath it and
        // come out visibly squatter. Rescaling by the ratio of the two picture
        // aspects keeps its shape — and its size in points — exactly as it was.
        let outgoing = pictureAspect
        configuration.aspectRatio = configuration.aspectRatio.toggled
        overlayHeightFraction = (overlayHeightFraction * pictureAspect / outgoing)
            .clamped(to: OverlayMetrics.heightRange)
        HapticEngine.shared.modeChanged()

        Analytics.log(AnalyticsEvent.aspectRatioToggled, [
            AnalyticsParam.aspectRatio: configuration.aspectRatio.rawValue,
            AnalyticsParam.layout: configuration.layout.rawValue,
        ])
    }

    func setPhotoVideoMode(_ mode: PhotoVideoMode) {
        guard !isRecording, mode != configuration.photoVideoMode else { return }
        let previous = configuration.photoVideoMode
        configuration.photoVideoMode = mode
        Analytics.log(AnalyticsEvent.photoVideoModeChanged, [
            AnalyticsParam.subMode: mode.rawValue,
            AnalyticsParam.previousMode: previous.rawValue,
        ])
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

    /// The red button. Starts or stops a take, and leaves the app in Video mode
    /// so the chrome that depends on it — the torch, the transient label —
    /// agrees with what just happened.
    ///
    /// Only *starting* passes the gate. Stopping is checked first and never
    /// gated: a paywall that can appear between record and stop is a paywall
    /// that can strand a user inside their own recording.
    func triggerRecord() {
        if isRecording {
            setPhotoVideoMode(.video)
            stopRecording()
            return
        }

        guard entitlements?.requireCapture(.video, mode: configuration.mode) != false else { return }

        setPhotoVideoMode(.video)
        startRecording()
    }

    /// The white button. Takes a still, and during a take takes it *without*
    /// interrupting the recording.
    ///
    /// The still-during-video path is gated too, and counted as a photo. It
    /// writes its own file to its own library entry, so leaving it open would
    /// have made "start a take, then press the white button" the free way past
    /// the photo allowance.
    func triggerPhoto() {
        guard isPhotoButtonEnabled else {
            HapticEngine.shared.error()
            return
        }
        guard entitlements?.requireCapture(.photo, mode: configuration.mode) != false else { return }
        guard !isRecording else {
            captureStillDuringVideo()
            return
        }
        setPhotoVideoMode(.photo)
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

            analyticsEvent(AnalyticsEvent.photoCaptured, [
                AnalyticsParam.duringRecording: isRecording,
                AnalyticsParam.selfTimer: selfTimer.rawValue,
                AnalyticsParam.flashMode: configuration.flashMode.rawValue,
                // The front camera's only light source. Whether the screen flash
                // is ever actually used is the question behind having built it.
                AnalyticsParam.value: usesScreenFlash ? "screen_flash" : "none",
            ])

            if let url = lastCapture?.compositedURL {
                await copyToPhotoLibrary(url, isPhoto: true)
            }
        } catch {
            toasts.show(error.localizedDescription, systemImage: "exclamationmark.triangle.fill", isWarning: true)
            HapticEngine.shared.error()
            analyticsEvent(AnalyticsEvent.photoCaptureFailed, [
                AnalyticsParam.reason: error.localizedDescription,
                AnalyticsParam.duringRecording: isRecording,
            ])
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

    /// Manual exposure, ISO, shutter, white balance and focus.
    ///
    /// Debounced, because every one of these arrives from a slider that writes
    /// on each frame of a drag. What matters is which controls people reach for
    /// and whether they leave automatic — not the path a thumb took to get
    /// there.
    func applyManualControl(_ control: ManualControl, to role: StreamRole) {
        engine.setManualControl(control, for: role)

        let (name, value, isAuto) = Self.describe(control)
        guard name != "reset_all" else {
            Analytics.log(AnalyticsEvent.manualControlsReset, [
                AnalyticsParam.streamRole: role.rawValue,
            ])
            return
        }
        analyticsSettled(
            AnalyticsEvent.manualControlChanged,
            key: "manual.\(role.rawValue).\(name)",
            [
                AnalyticsParam.control: name,
                AnalyticsParam.streamRole: role.rawValue,
                AnalyticsParam.value: value,
                AnalyticsParam.enabled: !isAuto,
            ]
        )
    }

    /// `(control name, value, is automatic)`. `nil` in every associated value
    /// means "restore automatic", which is the one thing about these controls
    /// worth counting on its own — a manual control returned to auto is a manual
    /// control that did not work for the user.
    private static func describe(_ control: ManualControl) -> (String, Double, Bool) {
        switch control {
        case .exposureBias(let value): ("exposure_bias", Double(value), false)
        case .iso(let value): ("iso", Double(value ?? 0), value == nil)
        case .shutterSpeed(let value): ("shutter_speed", value ?? 0, value == nil)
        case .whiteBalance(let value): ("white_balance", Double(value ?? 0), value == nil)
        case .focus(let value): ("focus", Double(value ?? 0), value == nil)
        case .resetAll: ("reset_all", 0, true)
        }
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
        Analytics.log(AnalyticsEvent.lensSourceChanged, [
            AnalyticsParam.streamRole: role.rawValue,
            AnalyticsParam.value: source.rawValue,
            AnalyticsParam.source: AnalyticsValue.sourceSettings,
        ])
    }

    func toggleGrid() {
        configuration.showsGrid.toggle()
        HapticEngine.shared.sliderDetent()
        Analytics.log(AnalyticsEvent.gridToggled, [
            AnalyticsParam.enabled: configuration.showsGrid,
        ])
    }

    func toggleLevel() {
        configuration.showsLevel.toggle()
        if configuration.showsLevel { level.start() } else { level.stop() }
        HapticEngine.shared.sliderDetent()
        Analytics.log(AnalyticsEvent.levelToggled, [
            AnalyticsParam.enabled: configuration.showsLevel,
        ])
    }

    func setMirrorsFrontCamera(_ enabled: Bool) {
        guard enabled != configuration.mirrorsFrontCamera else { return }
        configuration.mirrorsFrontCamera = enabled
        Analytics.log(AnalyticsEvent.mirrorFrontToggled, [AnalyticsParam.enabled: enabled])
    }

    func setSelfTimer(_ timer: SelfTimer) {
        guard timer != selfTimer else { return }
        selfTimer = timer
        Analytics.log(AnalyticsEvent.selfTimerChanged, [AnalyticsParam.selfTimer: timer.rawValue])
    }

    func setSavesToPhotoLibrary(_ enabled: Bool) {
        guard enabled != savesToPhotoLibrary else { return }
        savesToPhotoLibrary = enabled
        Analytics.log(AnalyticsEvent.saveToPhotosToggled, [AnalyticsParam.enabled: enabled])
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
                analyticsEvent(AnalyticsEvent.recordingStartFailed, [
                    AnalyticsParam.reason: error.localizedDescription,
                ])
                return
            }

            isRecording = true
            isPaused = false
            elapsed = 0
            HapticEngine.shared.recordingStarted()
            startElapsedTimer()

            // Logged where the writer actually came up, not where the button was
            // pressed. A `startRecording` that throws never reaches here, and a
            // "started" count that included failed starts would make the
            // start-to-save ratio unreadable — which is the one ratio that says
            // whether the pipeline is working for real users.
            analyticsEvent(AnalyticsEvent.recordingStarted, [
                AnalyticsParam.isPro: entitlements?.isPro ?? false,
                AnalyticsParam.hasCleanSources: configuration.quality.savesCleanSources,
                AnalyticsParam.codec: configuration.quality.codec.rawValue,
            ])
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

        // The take's length, captured before the writer is asked to finalize:
        // this is the number the take was *intended* to be, and it is the only
        // one available if finalization then fails.
        let takeLength = elapsed
        analyticsEvent(AnalyticsEvent.recordingStopped, [
            AnalyticsParam.durationSeconds: takeLength,
        ])

        Task {
            guard let result = await engine.stopRecording() else {
                toasts.show("Recording could not be saved", systemImage: "exclamationmark.triangle.fill", isWarning: true)
                analyticsEvent(AnalyticsEvent.recordingSaveFailed, [
                    AnalyticsParam.durationSeconds: takeLength,
                    AnalyticsParam.reason: "writer_returned_no_result",
                ])
                return
            }

            lastCapture = await library?.save(
                result,
                mode: configuration.mode,
                layout: configuration.layout,
                quality: negotiatedQuality
            )

            toasts.show("Recording saved", systemImage: "checkmark.circle.fill")

            // Separate from `recording_stopped` on purpose. Stopping is a user
            // action; saving is the pipeline's answer to it, and the gap between
            // the two counts is the failure rate of everything downstream of the
            // shutter. The drop rate rides along because Doc 3 budgets it at
            // 0.1% — a budget nobody can hold the app to without the field
            // number.
            analyticsEvent(AnalyticsEvent.recordingSaved, [
                AnalyticsParam.durationSeconds: result.duration,
                AnalyticsParam.dropPercent: result.dropFraction * 100,
                AnalyticsParam.framesAppended: result.framesAppended,
                AnalyticsParam.hasCleanSources: !result.cleanSourceFileNames.isEmpty,
            ])

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
        let mediaType = isPhoto ? AnalyticsValue.mediaPhoto : AnalyticsValue.mediaVideo
        guard !saved else {
            Analytics.log(AnalyticsEvent.savedToPhotoLibrary, [
                AnalyticsParam.mediaType: mediaType,
                AnalyticsParam.source: AnalyticsValue.sourceCameraChrome,
            ])
            return
        }
        // Almost always a photo-library permission the user declined, which is
        // silent everywhere else in the app — the capture still succeeded, so
        // nothing else marks it.
        Analytics.log(AnalyticsEvent.photoLibrarySaveFailed, [
            AnalyticsParam.mediaType: mediaType,
            AnalyticsParam.source: AnalyticsValue.sourceCameraChrome,
        ])
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
        Analytics.log(AnalyticsEvent.recordingPauseToggled, [
            AnalyticsParam.enabled: isPaused,
            AnalyticsParam.durationSeconds: elapsed,
        ])
    }

    /// Doc 2 §7.2: a full-resolution still without interrupting the recording.
    func captureStillDuringVideo() {
        HapticEngine.shared.stillDuringVideo()
        flashCapture()
        analyticsEvent(AnalyticsEvent.stillDuringVideoCaptured, [
            AnalyticsParam.durationSeconds: elapsed,
        ])
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
            overlayHeightFraction: overlayHeightFraction,
            splitRatio: splitRatio,
            diagonalAngle: diagonalAngle,
            border: overlayBorder
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
        // Debounced: a tap-to-focus is one event, but people tap repeatedly
        // while a scene settles, and three taps in a second is one intention.
        analyticsSettled(AnalyticsEvent.focusTapped, key: "focus.\(role.rawValue)", [
            AnalyticsParam.streamRole: role.rawValue,
            AnalyticsParam.duringRecording: isRecording,
        ])
    }

    func lockFocus(at point: CGPoint, normalized: CGPoint, in role: StreamRole) {
        engine.lockFocusAndExposure(at: normalized, in: role)
        focusIndicator = FocusIndicator(point: point, role: role, isLocked: true)
        HapticEngine.shared.focusLocked()
        scheduleFocusIndicatorDismissal()
        Analytics.log(AnalyticsEvent.focusLocked, [
            AnalyticsParam.streamRole: role.rawValue,
            AnalyticsParam.duringRecording: isRecording,
        ])
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

        Analytics.log(AnalyticsEvent.zoomStopSelected, [
            AnalyticsParam.zoomLabel: stop.label,
            AnalyticsParam.zoomFactor: stop.zoomFactor,
            AnalyticsParam.primarySource: updated.primarySource.rawValue,
            AnalyticsParam.mode: updated.mode.rawValue,
            AnalyticsParam.duringRecording: isRecording,
        ])
    }

    // MARK: Actions — overlay

    /// Commits a finished drag. One observable write, at the end of the gesture.
    func placeOverlay(atUnit unit: CGPoint) {
        overlayCentreUnit = unit
        HapticEngine.shared.overlayPlaced()
        // At the *end* of the drag, which is the one moment the position means
        // anything. `trackOverlayDrag` deliberately logs nothing — it runs at the
        // display's refresh rate.
        Analytics.log(AnalyticsEvent.overlayRepositioned, [
            AnalyticsParam.overlayX: unit.x,
            AnalyticsParam.overlayY: unit.y,
            AnalyticsParam.layout: configuration.layout.rawValue,
            AnalyticsParam.duringRecording: isRecording,
        ])
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

    /// Closes Settings and opens the PiP Parameter sheet in its place.
    ///
    /// Two steps with a gap between them, rather than one assignment. Both
    /// sheets are presented through the same `.sheet(item:)` slot, and swapping
    /// the item while the first is on screen makes UIKit dismiss and re-present
    /// inside one transaction — which it drops often enough that the second
    /// sheet simply never appears. The delay is the dismissal's own duration.
    ///
    /// Settings has to go rather than stack, because the point of the parameter
    /// sheet is watching the overlay change behind it, and a full-height
    /// Settings sheet is exactly what is covering it.
    func presentPiPParameterSheet() {
        activeSheet = nil
        Analytics.log(AnalyticsEvent.sheetOpened, [
            AnalyticsParam.name: CameraSheet.pipParameters.rawValue,
            AnalyticsParam.source: AnalyticsValue.sourceSettings,
            AnalyticsParam.locked: isPiPParameterLocked,
        ])
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            activeSheet = .pipParameters
        }
    }

    /// The one way a sheet is opened, so every open carries where it came from.
    ///
    /// The Quality sheet is reachable from the pill and from Settings, and the
    /// two are completely different moments — one is mid-setup, the other is a
    /// user who went looking. Assigning `activeSheet` directly at the call sites
    /// lost that distinction, and lost the open entirely for any sheet whose
    /// screen view happened not to fire.
    func presentSheet(_ sheet: CameraSheet, from source: String) {
        Analytics.log(AnalyticsEvent.sheetOpened, [
            AnalyticsParam.name: sheet.rawValue,
            AnalyticsParam.source: source,
            AnalyticsParam.mode: configuration.mode.rawValue,
        ])
        activeSheet = sheet
    }

    /// Doc 2 §7.4: the library, opened from the bottom cluster.
    func openGallery() {
        Analytics.log(AnalyticsEvent.galleryOpened, [
            AnalyticsParam.source: AnalyticsValue.sourceCameraChrome,
        ])
        isShowingGallery = true
    }

    /// Double-tap on the preview (Doc 2 §8). Counted because it is the app's one
    /// completely invisible gesture — nothing on screen advertises it, so how
    /// often it is found at all is the question.
    func toggleChromeHidden() {
        isChromeHidden.toggle()
        Analytics.log(AnalyticsEvent.chromeVisibilityToggled, [
            AnalyticsParam.enabled: !isChromeHidden,
            AnalyticsParam.duringRecording: isRecording,
        ])
    }

    /// Restores every PiP parameter: the shipped border — 20pt corners, a 3pt
    /// white stroke at 90% — and the size the current layout stands for.
    func resetPiPParameters() {
        overlayBorder = .default
        conformOverlayToLayout()
        HapticEngine.shared.success()
        Analytics.log(AnalyticsEvent.pipParametersReset, [
            AnalyticsParam.layout: configuration.layout.rawValue,
        ])
    }

    /// Whether anything on the parameter sheet has been moved off its default,
    /// which is the only time a Reset control has something to offer.
    ///
    /// The size half is measured against the *current layout's* preset, not a
    /// fixed number: Wide's default is 60 × 30 and Circle's 50 × 28, so a
    /// single hard-coded pair would have shown Reset permanently on four of the
    /// six cards.
    var hasCustomPiPParameters: Bool {
        let size = OverlayMetrics.defaultSize(
            for: configuration.layout,
            pictureAspect: pictureAspect
        )
        return overlayBorder != .default
            || abs(overlayWidthFraction - size.width) > 0.001
            || abs(overlayHeightFraction - size.height) > 0.001
    }

    // MARK: Actions — PiP parameters (Pro)

    /// The gate every PiP parameter goes through.
    ///
    /// The *sheet* is deliberately not gated — a control panel a free user
    /// cannot open is a feature they never find out exists — so the refusal
    /// happens at the moment of change instead. Every writer below funnels
    /// through here, including the pinch on the overlay itself: leaving that one
    /// open would be a free route to the same result, which makes the gate on
    /// the sliders pointless rather than lenient.
    private var allowsPiPParameterChange: Bool {
        entitlements?.require(.pipParameters) != false
    }

    /// Whether the parameter controls should read as locked. A question about
    /// *appearance*, so unlike `allowsPiPParameterChange` it raises nothing.
    var isPiPParameterLocked: Bool {
        entitlements.map { !$0.isPro } ?? false
    }

    /// Every setter below is debounced through `analyticsSettled`.
    ///
    /// These are all slider bindings, written on every frame of a drag — the one
    /// place in the app where naïve logging would genuinely matter, since a
    /// single sweep of the width slider is over a hundred writes. What the
    /// dashboard needs is the value the user stopped on.
    func setOverlayWidth(_ fraction: CGFloat) {
        guard allowsPiPParameterChange else { return }
        applyOverlayWidth(fraction)
        logPiPParameter(AnalyticsValue.pipWidth, overlayWidthFraction)
    }

    func setOverlayHeight(_ fraction: CGFloat) {
        guard allowsPiPParameterChange else { return }
        applyOverlayHeight(fraction)
        logPiPParameter(AnalyticsValue.pipHeight, overlayHeightFraction)
    }

    func setOverlayCornerRadius(_ radius: CGFloat) {
        guard allowsPiPParameterChange else { return }
        overlayBorder.cornerRadius = radius.clamped(to: 0...OverlayBorderStyle.maximumCornerRadius)
        logPiPParameter(AnalyticsValue.pipCornerRadius, overlayBorder.cornerRadius)
    }

    func setOverlayBorderWidth(_ width: CGFloat) {
        guard allowsPiPParameterChange else { return }
        overlayBorder.width = width.clamped(to: 0...OverlayBorderStyle.maximumWidth)
        logPiPParameter(AnalyticsValue.pipThickness, overlayBorder.width)
    }

    /// The preset swatches. `name` is the swatch's own, or `custom` from the
    /// colour picker — which is the split worth knowing, since seven presets
    /// exist precisely to make the picker unnecessary.
    func setOverlayBorderColor(
        red: Double, green: Double, blue: Double, opacity: Double,
        name: String = AnalyticsValue.pipColorCustom
    ) {
        guard allowsPiPParameterChange else { return }
        overlayBorder.setColor(red: red, green: green, blue: blue, opacity: opacity)
        Analytics.log(AnalyticsEvent.pipBorderColorSelected, [
            AnalyticsParam.name: name,
            AnalyticsParam.value: opacity,
        ])
    }

    func applyOverlayBorderColor(_ color: Color) {
        guard allowsPiPParameterChange else { return }
        overlayBorder.apply(color)
        // Debounced: the system colour picker writes continuously while a finger
        // is on its wheel.
        analyticsSettled(
            AnalyticsEvent.pipBorderColorSelected,
            key: "pip.\(AnalyticsValue.pipColor)",
            [
                AnalyticsParam.name: AnalyticsValue.pipColorCustom,
                AnalyticsParam.value: overlayBorder.opacity,
            ]
        )
    }

    private func logPiPParameter(_ parameter: String, _ value: CGFloat) {
        analyticsSettled(AnalyticsEvent.pipParameterChanged, key: "pip.\(parameter)", [
            AnalyticsParam.parameter: parameter,
            AnalyticsParam.value: value,
            AnalyticsParam.layout: configuration.layout.rawValue,
        ])
    }

    /// The ungated primitives.
    ///
    /// Used by the debug launch overrides and by `conformOverlayToLayout`, both
    /// of which install a size rather than accept one from the user — the first
    /// is how the sliders' effect is reviewed at all in a simulator that cannot
    /// be tapped, and the second is the layout's own preset.
    private func applyOverlayWidth(_ fraction: CGFloat) {
        let clamped = fraction.clamped(to: OverlayMetrics.widthRange)
        guard clamped != overlayWidthFraction else { return }
        overlayWidthFraction = clamped
    }

    private func applyOverlayHeight(_ fraction: CGFloat) {
        let clamped = fraction.clamped(to: OverlayMetrics.heightRange)
        guard clamped != overlayHeightFraction else { return }
        overlayHeightFraction = clamped
    }

    /// The pinch: one magnification applied to both axes at once.
    ///
    /// The scale is limited *before* it is applied rather than each axis being
    /// clamped afterwards. Clamping afterwards is what would let a pinch past
    /// the width ceiling keep stretching the height, so the overlay would change
    /// shape at the limit instead of simply stopping.
    func scaleOverlay(from base: CGSize, by magnification: CGFloat) {
        guard allowsPiPParameterChange else { return }
        var scale = min(
            magnification,
            OverlayMetrics.maximumWidthFraction / max(base.width, 0.01),
            OverlayMetrics.maximumHeightFraction / max(base.height, 0.01)
        )
        scale = max(
            scale,
            OverlayMetrics.minimumWidthFraction / max(base.width, 0.01),
            OverlayMetrics.minimumHeightFraction / max(base.height, 0.01)
        )

        let width = base.width * scale
        let height = base.height * scale
        guard width != overlayWidthFraction || height != overlayHeightFraction else { return }

        if abs(scale - magnification) > 0.001 { HapticEngine.shared.resizeLimit() }
        overlayWidthFraction = width
        overlayHeightFraction = height

        // The pinch and the two sliders reach the same numbers by different
        // routes, and which route people use decides whether the parameter sheet
        // is worth its place in Settings. Separate event, same debounce.
        analyticsSettled(AnalyticsEvent.overlayPinchResized, key: "pip.pinch", [
            AnalyticsParam.widthFraction: width,
            AnalyticsParam.heightFraction: height,
            AnalyticsParam.layout: configuration.layout.rawValue,
        ])
    }
}

// MARK: - Analytics

extension CameraViewModel {
    /// The shape of the capture, as every camera event reports it.
    ///
    /// One helper rather than seven literals per call site: `recording_started`
    /// and `photo_captured` have to be comparable on the same axes, and they only
    /// are if both spell the axes identically. Quality is read from
    /// `negotiatedQuality` — what the hardware granted — because what was
    /// *requested* is not what got recorded.
    var analyticsCaptureShape: [String: Any] {
        [
            AnalyticsParam.mode: configuration.mode.rawValue,
            AnalyticsParam.layout: configuration.layout.rawValue,
            AnalyticsParam.aspectRatio: configuration.aspectRatio.rawValue,
            AnalyticsParam.resolution: negotiatedQuality.resolution.rawValue,
            AnalyticsParam.frameRate: negotiatedQuality.frameRate.rawValue,
            AnalyticsParam.primarySource: configuration.primarySource.rawValue,
            AnalyticsParam.secondarySource: configuration.secondarySource?.rawValue ?? "none",
        ]
    }

    func analyticsEvent(_ event: String, _ parameters: [String: Any] = [:]) {
        Analytics.log(event, analyticsCaptureShape.merging(parameters) { _, new in new })
    }

    /// Logs the value a control *settled* on, not every value it passed through.
    ///
    /// Sliders and pinches deliver a change per display frame. Logged directly,
    /// one drag of the width slider is a hundred and twenty events describing a
    /// number nobody chose — it floods the quota, and the histogram it builds is
    /// of the journey rather than of the destination. Each key keeps its own
    /// pending task, so moving width and then height records both rather than
    /// letting the second cancel the first.
    func analyticsSettled(_ event: String, key: String, _ parameters: [String: Any]) {
        pendingSettledLogs[key]?.cancel()
        pendingSettledLogs[key] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            Analytics.log(event, parameters)
            self?.pendingSettledLogs[key] = nil
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
    case pipParameters

    var id: String { rawValue }
}
