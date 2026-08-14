import AVFoundation
import CoreMedia
import Foundation

/// Capture resolution tier.
///
/// These are *requests*. What the hardware actually grants is reported back
/// separately — see `NegotiatedQuality`. Doc 1 §1.1 makes honest quality
/// reporting a product pillar, and Doc 3 reminder 10 spells out why: users
/// forgive limitations, they do not forgive being misled about what they just
/// recorded.
nonisolated enum Resolution: String, CaseIterable, Identifiable, Codable, Sendable, Comparable {
    case uhd4K
    case hd1080p
    case hd720p

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .uhd4K: "4K"
        case .hd1080p: "1080p"
        case .hd720p: "720p"
        }
    }

    var dimensions: CMVideoDimensions {
        switch self {
        case .uhd4K: CMVideoDimensions(width: 3840, height: 2160)
        case .hd1080p: CMVideoDimensions(width: 1920, height: 1080)
        case .hd720p: CMVideoDimensions(width: 1280, height: 720)
        }
    }

    var pixelCount: Int {
        Int(dimensions.width) * Int(dimensions.height)
    }

    /// One tier down, for the degradation ladder (Doc 3 Phase 2 task 13).
    /// `nil` at the bottom — there is nowhere left to step.
    var loweredOneTier: Resolution? {
        switch self {
        case .uhd4K: .hd1080p
        case .hd1080p: .hd720p
        case .hd720p: nil
        }
    }

    /// Target video bitrate, scaled to resolution (Doc 3 Phase 2 task 5).
    var targetBitrate: Int {
        switch self {
        case .uhd4K: 45_000_000
        case .hd1080p: 12_000_000
        case .hd720p: 6_000_000
        }
    }

    static func < (lhs: Resolution, rhs: Resolution) -> Bool {
        lhs.pixelCount < rhs.pixelCount
    }
}

/// Capture frame rate tier.
nonisolated enum FrameRate: Int, CaseIterable, Identifiable, Codable, Sendable, Comparable {
    case fps24 = 24
    case fps30 = 30
    case fps60 = 60

    var id: Int { rawValue }
    var displayName: String { "\(rawValue)" }

    /// The minimum frame duration to hand to `videoMinFrameDurationOverride`.
    var minFrameDuration: CMTime {
        CMTime(value: 1, timescale: CMTimeScale(rawValue))
    }

    var loweredOneTier: FrameRate? {
        switch self {
        case .fps60: .fps30
        case .fps30: .fps24
        case .fps24: nil
        }
    }

    static func < (lhs: FrameRate, rhs: FrameRate) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

nonisolated enum VideoCodec: String, CaseIterable, Identifiable, Codable, Sendable {
    case hevc
    case h264

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hevc: "HEVC"
        case .h264: "H.264"
        }
    }

    var avCodecType: AVVideoCodecType {
        switch self {
        case .hevc: .hevc
        case .h264: .h264
        }
    }
}

nonisolated enum StabilizationMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case off
    case standard
    case cinematic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: "Off"
        case .standard: "Standard"
        case .cinematic: "Cinematic"
        }
    }

    var avMode: AVCaptureVideoStabilizationMode {
        switch self {
        case .off: .off
        case .standard: .standard
        case .cinematic: .cinematic
        }
    }
}

/// What the user *asked* for.
nonisolated struct QualityProfile: Equatable, Codable, Sendable {
    var resolution: Resolution = .hd1080p
    var frameRate: FrameRate = .fps30
    var codec: VideoCodec = .hevc
    var stabilization: StabilizationMode = .standard
    var savesCleanSources: Bool = false

    static let `default` = QualityProfile()
}

/// What the hardware actually granted.
///
/// The quality pill (Doc 2 §4.2) binds to *this*, never to `QualityProfile`.
/// If the user asks for 4K and `hardwareCost` forces 1080p, the pill reads
/// 1080p immediately.
nonisolated struct NegotiatedQuality: Equatable, Sendable {
    var resolution: Resolution
    var frameRate: FrameRate
    var hardwareCost: Float

    /// Set when the request was reduced, so the UI can explain itself with a
    /// single toast rather than a silent downgrade.
    var degradationReason: DegradationReason?

    static let placeholder = NegotiatedQuality(
        resolution: .hd1080p,
        frameRate: .fps30,
        hardwareCost: 0
    )

    var wasDegraded: Bool { degradationReason != nil }
}

nonisolated enum DegradationReason: String, Equatable, Codable, Sendable {
    case hardwareCostExceeded
    case formatUnavailable
    case thermalPressure
    case systemPressure

    var userFacingMessage: String {
        switch self {
        case .hardwareCostExceeded: "Quality reduced to fit this camera pairing"
        case .formatUnavailable: "This device doesn't support that quality here"
        case .thermalPressure: "Reducing quality to keep recording"
        case .systemPressure: "Reducing quality to keep recording"
        }
    }
}
