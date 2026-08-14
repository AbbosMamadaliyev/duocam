import AVFoundation
import os

/// Why a quality combination is unavailable.
///
/// Doc 2 §6.4 requires every greyed option to state *why*, "referencing the
/// actual constraint that blocks it". A free-text string would drift into
/// plausible-sounding fiction, so the reason is a value derived from the thing
/// that actually failed.
nonisolated enum QualityBlockReason: Equatable, Sendable {
    case noFormat(CameraSource)
    case frameRateUnsupported(Resolution, FrameRate)
    case hardwareCost(Float)
    case notInMode(CaptureMode)

    func message(resolution: Resolution, frameRate: FrameRate, mode: CaptureMode) -> String {
        switch self {
        case .noFormat(let source):
            "\(resolution.displayName) — the \(source.displayName) camera has no such format on this device"
        case .frameRateUnsupported(let res, let rate):
            "\(rate.displayName) fps — unavailable at \(res.displayName) on this device"
        case .hardwareCost(let cost):
            "\(resolution.displayName) at \(frameRate.displayName) fps — exceeds this camera pairing's budget (cost \(String(format: "%.2f", cost)))"
        case .notInMode(let blocked):
            "\(resolution.displayName) — unavailable in \(blocked.displayName) on this device"
        }
    }
}

/// One cell of the matrix.
nonisolated struct QualityCombination: Hashable, Sendable {
    let mode: CaptureMode
    let resolution: Resolution
    let frameRate: FrameRate
}

/// What this specific device can genuinely record, computed by trying it.
///
/// Doc 3 Phase 5 task 2: *"the constraint matrix: resolution × frame rate ×
/// mode × device, with `hardwareCost` validation for every combination"*, and
/// Doc 3 reminder 2's rule that the device is authoritative, not the
/// documentation.
///
/// Doc 3 Phase 5's acceptance criterion — *"the Quality sheet never offers a
/// combination that subsequently fails"* — is only achievable by testing the
/// combinations rather than reasoning about them, because `hardwareCost`
/// depends on the exact formats chosen on both devices at once.
actor QualityConstraintMatrix {
    private var blocked: [QualityCombination: QualityBlockReason] = [:]
    private var isProbed = false

    /// Cached per device model (Doc 3 Phase 5 task 2) — the matrix is identical
    /// for every unit of the same model, and probing costs ~1s of session
    /// churn that should not repeat on every launch.
    private static let cacheKeyPrefix = "quality.matrix."

    func reason(
        mode: CaptureMode,
        resolution: Resolution,
        frameRate: FrameRate
    ) -> QualityBlockReason? {
        blocked[QualityCombination(mode: mode, resolution: resolution, frameRate: frameRate)]
    }

    func allBlocked() -> [QualityCombination: QualityBlockReason] { blocked }

    func isAvailable(mode: CaptureMode, resolution: Resolution, frameRate: FrameRate) -> Bool {
        reason(mode: mode, resolution: resolution, frameRate: frameRate) == nil
    }

    /// Probes every combination the app can offer.
    func probe(report: CapabilityReport, force: Bool = false) {
        guard !isProbed || force else { return }
        isProbed = true

        if !force, let cached = Self.loadCache(modelKey: report.deviceModel) {
            blocked = cached
            Log.capture.info("Quality matrix loaded from cache (\(cached.count) blocked combinations)")
            return
        }

        let start = Date()
        var results: [QualityCombination: QualityBlockReason] = [:]

        for mode in report.availableModes {
            for resolution in Resolution.allCases {
                for frameRate in FrameRate.allCases {
                    let combination = QualityCombination(
                        mode: mode, resolution: resolution, frameRate: frameRate
                    )
                    if let reason = Self.evaluate(combination, report: report) {
                        results[combination] = reason
                    }
                }
            }
        }

        blocked = results
        Self.saveCache(results, modelKey: report.deviceModel)
        Log.capture.info(
            "Quality matrix probed in \(Int(Date().timeIntervalSince(start) * 1000))ms · \(results.count) blocked of \(report.availableModes.count * 9)"
        )
    }

    // MARK: Evaluation

    nonisolated private static func evaluate(
        _ combination: QualityCombination,
        report: CapabilityReport
    ) -> QualityBlockReason? {
        let sources = combination.mode.defaultSources
        let needed = [sources.primary, sources.secondary].compactMap { $0 }
        let requiresMultiCam = combination.mode.isDual

        // Step 1: does each camera even have a format at this tier and rate?
        for source in needed {
            guard let device = AVCaptureDevice.default(
                source.deviceType, for: .video, position: source.position
            ) else {
                return .noFormat(source)
            }

            let target = combination.resolution.dimensions
            let matching = device.formats.filter { format in
                guard !requiresMultiCam || format.isMultiCamSupported else { return false }
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return dims.width >= target.width && dims.height >= target.height
            }

            guard !matching.isEmpty else {
                return requiresMultiCam
                    ? .notInMode(combination.mode)
                    : .noFormat(source)
            }

            let supportsRate = matching.contains { format in
                format.videoSupportedFrameRateRanges.contains {
                    $0.maxFrameRate >= Double(combination.frameRate.rawValue)
                }
            }
            guard supportsRate else {
                return .frameRateUnsupported(combination.resolution, combination.frameRate)
            }
        }

        // Step 2: for dual modes, would the pairing actually fit?
        guard requiresMultiCam else { return nil }
        return costCheck(combination, sources: needed)
    }

    /// Builds a throwaway session at the exact combination and reads the real
    /// cost. There is no way to predict this — it depends on both devices'
    /// selected formats simultaneously.
    nonisolated private static func costCheck(
        _ combination: QualityCombination,
        sources: [CameraSource]
    ) -> QualityBlockReason? {
        let session = AVCaptureMultiCamSession()
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        var devices: [AVCaptureDevice] = []

        for source in sources {
            guard let device = AVCaptureDevice.default(
                source.deviceType, for: .video, position: source.position
            ), let input = try? AVCaptureDeviceInput(device: device),
                session.canAddInput(input)
            else { return .noFormat(source) }

            session.addInputWithNoConnections(input)
            devices.append(device)
        }

        let target = combination.resolution.dimensions
        for device in devices {
            let candidates = device.formats.filter { format in
                guard format.isMultiCamSupported else { return false }
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                guard dims.width >= target.width, dims.height >= target.height else { return false }
                return format.videoSupportedFrameRateRanges.contains {
                    $0.maxFrameRate >= Double(combination.frameRate.rawValue)
                }
            }
            // Smallest format that still meets the tier — the cheapest way to
            // satisfy the request, which is what the engine will also pick.
            guard let chosen = candidates.min(by: { lhs, rhs in
                let l = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
                let r = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
                return Int(l.width) * Int(l.height) < Int(r.width) * Int(r.height)
            }) else {
                return .notInMode(combination.mode)
            }

            guard (try? device.lockForConfiguration()) != nil else { continue }
            device.activeFormat = chosen
            let duration = CMTime(value: 1, timescale: CMTimeScale(combination.frameRate.rawValue))
            if chosen.videoSupportedFrameRateRanges.contains(where: {
                $0.minFrameDuration <= duration && duration <= $0.maxFrameDuration
            }) {
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
            }
            device.unlockForConfiguration()
        }

        let cost = session.hardwareCost
        return cost > 1.0 ? .hardwareCost(cost) : nil
    }

    // MARK: Cache

    nonisolated private static func loadCache(
        modelKey: String
    ) -> [QualityCombination: QualityBlockReason]? {
        guard let raw = UserDefaults.standard.dictionary(forKey: cacheKeyPrefix + modelKey)
                as? [String: String]
        else { return nil }

        var result: [QualityCombination: QualityBlockReason] = [:]
        for (key, value) in raw {
            guard let combination = decodeCombination(key),
                  let reason = decodeReason(value)
            else { continue }
            result[combination] = reason
        }
        return result
    }

    nonisolated private static func saveCache(
        _ blocked: [QualityCombination: QualityBlockReason],
        modelKey: String
    ) {
        var raw: [String: String] = [:]
        for (combination, reason) in blocked {
            raw[encode(combination)] = encode(reason)
        }
        UserDefaults.standard.set(raw, forKey: cacheKeyPrefix + modelKey)
    }

    nonisolated private static func encode(_ c: QualityCombination) -> String {
        "\(c.mode.rawValue)|\(c.resolution.rawValue)|\(c.frameRate.rawValue)"
    }

    nonisolated private static func decodeCombination(_ raw: String) -> QualityCombination? {
        let parts = raw.split(separator: "|")
        guard parts.count == 3,
              let mode = CaptureMode(rawValue: String(parts[0])),
              let resolution = Resolution(rawValue: String(parts[1])),
              let rate = Int(parts[2]).flatMap(FrameRate.init(rawValue:))
        else { return nil }
        return QualityCombination(mode: mode, resolution: resolution, frameRate: rate)
    }

    nonisolated private static func encode(_ reason: QualityBlockReason) -> String {
        switch reason {
        case .noFormat(let source): "noFormat:\(source.rawValue)"
        case .frameRateUnsupported(let r, let f): "rate:\(r.rawValue):\(f.rawValue)"
        case .hardwareCost(let cost): "cost:\(cost)"
        case .notInMode(let mode): "mode:\(mode.rawValue)"
        }
    }

    nonisolated private static func decodeReason(_ raw: String) -> QualityBlockReason? {
        let parts = raw.split(separator: ":")
        switch parts.first {
        case "noFormat":
            return CameraSource(rawValue: String(parts[1])).map(QualityBlockReason.noFormat)
        case "rate":
            guard parts.count == 3,
                  let resolution = Resolution(rawValue: String(parts[1])),
                  let rate = Int(parts[2]).flatMap(FrameRate.init(rawValue:))
            else { return nil }
            return .frameRateUnsupported(resolution, rate)
        case "cost":
            return Float(parts[1]).map(QualityBlockReason.hardwareCost)
        case "mode":
            return CaptureMode(rawValue: String(parts[1])).map(QualityBlockReason.notInMode)
        default:
            return nil
        }
    }
}
