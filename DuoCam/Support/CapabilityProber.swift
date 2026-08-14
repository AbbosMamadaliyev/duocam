import AVFoundation
import Foundation
import os

// MARK: - Report types

/// One `AVCaptureDevice.Format` that is genuinely usable in a multi-cam session.
nonisolated struct MultiCamFormatInfo: Identifiable, Sendable, Hashable {
    let id = UUID()
    let width: Int32
    let height: Int32
    let maxFrameRate: Float64
    let minFrameRate: Float64
    let isBinned: Bool
    let supportsStabilization: Bool

    var dimensionLabel: String { "\(width)×\(height)" }
    var frameRateLabel: String {
        minFrameRate == maxFrameRate
            ? "\(Int(maxFrameRate)) fps"
            : "\(Int(minFrameRate))–\(Int(maxFrameRate)) fps"
    }

    /// The `Resolution` tier this format satisfies, if any. A format is only
    /// credited with a tier when it meets or exceeds that tier's dimensions.
    var resolutionTier: Resolution? {
        Resolution.allCases
            .sorted(by: >)
            .first { width >= $0.dimensions.width && height >= $0.dimensions.height }
    }
}

/// Everything discovered about one physical camera.
nonisolated struct DeviceCapability: Identifiable, Sendable {
    let id: String
    let source: CameraSource?
    let localizedName: String
    let position: AVCaptureDevice.Position
    let totalFormatCount: Int
    let multiCamFormats: [MultiCamFormatInfo]
    let minZoomFactor: CGFloat
    let maxZoomFactor: CGFloat

    var hasMultiCamFormats: Bool { !multiCamFormats.isEmpty }

    var bestMultiCamFormat: MultiCamFormatInfo? {
        multiCamFormats.max { lhs, rhs in
            (Int(lhs.width) * Int(lhs.height), lhs.maxFrameRate)
                < (Int(rhs.width) * Int(rhs.height), rhs.maxFrameRate)
        }
    }
}

/// The measured cost of running two specific cameras at once.
///
/// Doc 1 §5.3.4: `hardwareCost` above 1.0 means the configuration is rejected
/// outright. Probing pairings up front is what lets the Quality sheet avoid
/// ever offering a combination that will subsequently fail.
nonisolated struct PairingCost: Identifiable, Sendable {
    let id = UUID()
    let primary: CameraSource
    let secondary: CameraSource
    let hardwareCost: Float
    let systemPressureCost: Float
    let succeeded: Bool
    let failureReason: String?

    var isWithinBudget: Bool { succeeded && hardwareCost <= 1.0 }

    var label: String { "\(primary.displayName) + \(secondary.displayName)" }
}

/// The complete ground-truth report. Doc 3 Phase 0 exists to produce exactly
/// this before any UI is built on assumptions.
nonisolated struct CapabilityReport: Sendable {
    var isMultiCamSupported: Bool = false
    var isRunningInSimulator: Bool = false
    var deviceModel: String = ""
    var systemVersion: String = ""
    var devices: [DeviceCapability] = []
    var pairings: [PairingCost] = []
    var probeDuration: TimeInterval = 0

    /// Which capture modes this hardware can actually offer. Doc 2 §4.3:
    /// unsupported modes are *absent* from the selector, not disabled — a
    /// control that can never be enabled is noise.
    var availableModes: [CaptureMode] {
        var modes: [CaptureMode] = []
        if isMultiCamSupported {
            if hasWorkingPairing(.rearWide, .front) { modes.append(.dualFrontBack) }
            if hasWorkingPairing(.rearWide, .rearUltraWide) { modes.append(.dualRear) }
        }
        modes.append(.single)
        return modes
    }

    func hasWorkingPairing(_ a: CameraSource, _ b: CameraSource) -> Bool {
        pairings.contains { pairing in
            pairing.isWithinBudget
                && Set([pairing.primary, pairing.secondary]) == Set([a, b])
        }
    }

    func capability(for source: CameraSource) -> DeviceCapability? {
        devices.first { $0.source == source }
    }

    /// A plain-text dump of everything probed, for `devicectl --console`.
    ///
    /// Doc 3 Phase 5 task 9 asks for the real capability ceiling of each device
    /// to be recorded. This is that record — and Doc 3 reminder 2's point in
    /// practice: *"the documentation is not authoritative; the device is."*
    var consoleDump: String {
        var lines: [String] = []
        lines.append("═══ DuoCam capability report ═══")
        lines.append("model:      \(deviceModel)")
        lines.append("system:     \(systemVersion)")
        lines.append("multi-cam:  \(isMultiCamSupported)")
        lines.append("probe:      \(Int(probeDuration * 1000)) ms")
        lines.append("modes:      \(availableModes.map(\.displayName).joined(separator: ", "))")

        lines.append("── pairings (hardwareCost / systemPressureCost) ──")
        if pairings.isEmpty { lines.append("  none") }
        for pairing in pairings {
            let verdict = pairing.isWithinBudget ? "OK " : "REJ"
            let cost = pairing.succeeded ? String(format: "%.3f", pairing.hardwareCost) : "n/a"
            let pressure = pairing.succeeded ? String(format: "%.3f", pairing.systemPressureCost) : "n/a"
            lines.append("  [\(verdict)] \(pairing.label): \(cost) / \(pressure)"
                         + (pairing.failureReason.map { "  — \($0)" } ?? ""))
        }

        lines.append("── cameras ──")
        for device in devices {
            lines.append("  \(device.localizedName) [\(device.source?.rawValue ?? "unmapped")]"
                         + "  \(device.multiCamFormats.count)/\(device.totalFormatCount) multi-cam formats"
                         + "  zoom \(String(format: "%.1f", device.minZoomFactor))–\(String(format: "%.1f", device.maxZoomFactor))×")
            // Only the ceiling per tier — the full list runs to dozens of rows
            // and buries the number that actually matters.
            for tier in Resolution.allCases {
                let best = device.multiCamFormats
                    .filter { $0.resolutionTier == tier }
                    .max { $0.maxFrameRate < $1.maxFrameRate }
                if let best {
                    lines.append("      \(tier.displayName.padding(toLength: 6, withPad: " ", startingAt: 0)) "
                                 + "\(best.dimensionLabel) up to \(Int(best.maxFrameRate)) fps"
                                 + (best.isBinned ? " (binned)" : ""))
                }
            }
        }
        lines.append("═══════════════════════════════")
        return lines.joined(separator: "\n")
    }

    /// The headline line in the Capability Inspector.
    var summary: String {
        if isRunningInSimulator {
            return "Multi-cam: unsupported (simulator — no capture hardware)"
        }
        return isMultiCamSupported
            ? "Multi-cam: supported · \(pairings.filter(\.isWithinBudget).count) valid pairing(s)"
            : "Multi-cam: unsupported on this device"
    }
}

// MARK: - Prober

/// Enumerates what this specific device can genuinely do, at runtime.
///
/// Doc 3 reminder 2 is the reason this type exists and is used everywhere
/// instead of a constant table: *"the documentation is not authoritative; the
/// device is."* Multi-cam format availability varies by device, by iOS version,
/// and by camera combination in ways that are not reliably documented.
///
/// Probing is I/O-ish and slow enough to matter at launch, so it runs off the
/// main actor and the result is cached.
actor CapabilityProber {
    private var cached: CapabilityReport?

    /// All device types worth discovering. Virtual devices are deliberately
    /// absent — Doc 1 §5.3.5, they are generally unavailable in multi-cam.
    private static let discoveryTypes: [AVCaptureDevice.DeviceType] = [
        .builtInWideAngleCamera,
        .builtInUltraWideCamera,
        .builtInTelephotoCamera,
        .builtInTrueDepthCamera,
    ]

    /// The pairings worth costing. Only combinations the product actually
    /// offers (Doc 1 §3.2) — costing every permutation wastes launch time.
    private static let candidatePairings: [(CameraSource, CameraSource)] = [
        (.rearWide, .front),
        (.rearWide, .rearUltraWide),
        (.rearUltraWide, .front),
        (.rearTelephoto, .front),
    ]

    func report(forceRefresh: Bool = false) -> CapabilityReport {
        if !forceRefresh, let cached { return cached }
        let fresh = probe()
        cached = fresh
        return fresh
    }

    private func probe() -> CapabilityReport {
        let start = Date()
        var report = CapabilityReport()

        #if targetEnvironment(simulator)
        report.isRunningInSimulator = true
        #endif

        report.deviceModel = Self.hardwareModelIdentifier()
        report.systemVersion = ProcessInfo.processInfo.operatingSystemVersionString

        // The iOS 26 simulator answers `true` to `isMultiCamSupported` while
        // exposing zero capture devices, so taking the flag at face value would
        // have the app confidently build a multi-cam session against nothing.
        // Support means "a session can actually run here", and it cannot.
        report.isMultiCamSupported = !report.isRunningInSimulator
            && AVCaptureMultiCamSession.isMultiCamSupported

        Log.capture.info(
            "Probing capabilities · model=\(report.deviceModel, privacy: .public) multiCam=\(report.isMultiCamSupported)"
        )

        report.devices = Self.discoverDevices()

        // Costing a pairing means actually building a session, so it is only
        // worth attempting when multi-cam exists at all.
        if report.isMultiCamSupported {
            report.pairings = Self.costPairings(availableDevices: report.devices)
        }

        report.probeDuration = Date().timeIntervalSince(start)
        Log.capture.info(
            "Probe complete in \(String(format: "%.0f", report.probeDuration * 1000))ms · \(report.devices.count) device(s), \(report.pairings.count) pairing(s)"
        )
        return report
    }

    // MARK: Discovery

    private static func discoverDevices() -> [DeviceCapability] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: discoveryTypes,
            mediaType: .video,
            position: .unspecified
        )

        return session.devices.map { device in
            let multiCamFormats = device.formats
                .filter(\.isMultiCamSupported)
                .map { format -> MultiCamFormatInfo in
                    let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                    let ranges = format.videoSupportedFrameRateRanges
                    return MultiCamFormatInfo(
                        width: dims.width,
                        height: dims.height,
                        maxFrameRate: ranges.map(\.maxFrameRate).max() ?? 0,
                        minFrameRate: ranges.map(\.minFrameRate).min() ?? 0,
                        isBinned: format.isVideoBinned,
                        supportsStabilization: format.isVideoStabilizationModeSupported(.standard)
                    )
                }

            let source = CameraSource.allCases.first {
                $0.deviceType == device.deviceType && $0.position == device.position
            }

            Log.capture.debug(
                "\(device.localizedName, privacy: .public): \(device.formats.count) formats, \(multiCamFormats.count) multi-cam"
            )

            return DeviceCapability(
                id: device.uniqueID,
                source: source,
                localizedName: device.localizedName,
                position: device.position,
                totalFormatCount: device.formats.count,
                multiCamFormats: multiCamFormats,
                minZoomFactor: device.minAvailableVideoZoomFactor,
                maxZoomFactor: device.maxAvailableVideoZoomFactor
            )
        }
    }

    // MARK: Pairing cost

    /// Builds a throwaway `AVCaptureMultiCamSession` per pairing and reads back
    /// its real `hardwareCost`. There is no way to compute this statically —
    /// the value depends on the exact formats selected on both devices.
    private static func costPairings(
        availableDevices: [DeviceCapability]
    ) -> [PairingCost] {
        let usable = Set(availableDevices.filter(\.hasMultiCamFormats).compactMap(\.source))

        return candidatePairings.compactMap { primary, secondary in
            guard usable.contains(primary), usable.contains(secondary) else { return nil }
            return cost(primary: primary, secondary: secondary)
        }
    }

    private static func cost(
        primary: CameraSource,
        secondary: CameraSource
    ) -> PairingCost {
        func failure(_ reason: String) -> PairingCost {
            Log.capture.error("Pairing \(primary.rawValue, privacy: .public)+\(secondary.rawValue, privacy: .public) failed: \(reason, privacy: .public)")
            return PairingCost(
                primary: primary,
                secondary: secondary,
                hardwareCost: .infinity,
                systemPressureCost: .infinity,
                succeeded: false,
                failureReason: reason
            )
        }

        guard let primaryDevice = AVCaptureDevice.default(
            primary.deviceType, for: .video, position: primary.position
        ) else { return failure("\(primary.displayName) camera not present") }

        guard let secondaryDevice = AVCaptureDevice.default(
            secondary.deviceType, for: .video, position: secondary.position
        ) else { return failure("\(secondary.displayName) camera not present") }

        let session = AVCaptureMultiCamSession()
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        do {
            let primaryInput = try AVCaptureDeviceInput(device: primaryDevice)
            let secondaryInput = try AVCaptureDeviceInput(device: secondaryDevice)

            // Doc 1 §5.3.1 — the `WithNoConnections` variants are mandatory.
            // The automatic ones silently fail to produce working connections.
            guard session.canAddInput(primaryInput), session.canAddInput(secondaryInput) else {
                return failure("Session rejected one of the inputs")
            }
            session.addInputWithNoConnections(primaryInput)
            session.addInputWithNoConnections(secondaryInput)

            // `hardwareCost` is a function of the **active formats**, not of
            // the inputs. Reading it straight after `addInput` returns 0.000
            // for every pairing on every device — a number that looks like a
            // pass and means nothing. Both devices are pinned to a common
            // baseline first so the figure is comparable across pairings.
            try applyProbeFormat(to: primaryDevice)
            try applyProbeFormat(to: secondaryDevice)

            return PairingCost(
                primary: primary,
                secondary: secondary,
                hardwareCost: session.hardwareCost,
                systemPressureCost: session.systemPressureCost,
                succeeded: true,
                failureReason: nil
            )
        } catch {
            return failure(error.localizedDescription)
        }
    }

    /// Pins a device to the probe baseline: the largest multi-cam format at or
    /// below 1920×1080 that reaches 30 fps.
    ///
    /// 1080p30 is the reference point because it is the tier Doc 1 §6.1 sets
    /// the sustained-recording target at, so a pairing's cost here is the cost
    /// of the configuration the app will actually spend most of its time in.
    nonisolated private static func applyProbeFormat(to device: AVCaptureDevice) throws {
        let candidates = device.formats.filter { format in
            guard format.isMultiCamSupported else { return false }
            guard format.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= 30 })
            else { return false }
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return dims.width <= 1920 && dims.height <= 1080
        }

        // Fall back to the smallest multi-cam format if nothing fits under
        // 1080p — some ultra-wide modules start above it.
        let chosen = candidates.max { lhs, rhs in
            area(of: lhs) < area(of: rhs)
        } ?? device.formats.filter(\.isMultiCamSupported).min { lhs, rhs in
            area(of: lhs) < area(of: rhs)
        }

        guard let chosen else {
            throw CaptureError.noMultiCamFormat(.rearWide)
        }

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeFormat = chosen
    }

    nonisolated private static func area(of format: AVCaptureDevice.Format) -> Int {
        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return Int(dims.width) * Int(dims.height)
    }

    // MARK: Model identifier

    private static func hardwareModelIdentifier() -> String {
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "Simulator"
        #else
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafeBytes(of: &systemInfo.machine) { buffer in
            buffer.prefix { $0 != 0 }.map { UInt8($0) }
        }
        return String(decoding: machine, as: UTF8.self)
        #endif
    }
}
