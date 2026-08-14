import Foundation

/// Which of the two streams a value applies to.
///
/// "Primary" is the stream that fills the screen; "secondary" is the one in the
/// overlay or the second half of a split. The pair is *swappable* (Doc 2 §5.6)
/// and that swap is a pure presentation change — both streams stay live, so no
/// camera reconfiguration is involved.
nonisolated enum StreamRole: String, CaseIterable, Identifiable, Codable, Sendable {
    case primary
    case secondary

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .primary: "Primary"
        case .secondary: "Secondary"
        }
    }

    var swapped: StreamRole {
        self == .primary ? .secondary : .primary
    }
}

/// Photo versus Video. Doc 2 §4.4: this is *not* a row of its own — it is a
/// swipe on the shutter region, and the shutter morphs to communicate it. That
/// is the fix for prototype problem P4, where a red record circle and a white
/// photo circle sat side by side with no indication of which was active.
nonisolated enum PhotoVideoMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case photo
    case video

    var id: String { rawValue }

    /// The transient label shown above the shutter for 1.2s after a change.
    var displayName: String {
        switch self {
        case .photo: "PHOTO"
        case .video: "VIDEO"
        }
    }

    var toggled: PhotoVideoMode {
        self == .photo ? .video : .photo
    }
}

/// Flash cycles Off → On → Auto on tap (Doc 2 §4.2).
nonisolated enum FlashMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case off
    case on
    case auto

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .off: "bolt.slash"
        case .on: "bolt.fill"
        case .auto: "bolt.badge.a"
        }
    }

    var next: FlashMode {
        switch self {
        case .off: .on
        case .on: .auto
        case .auto: .off
        }
    }

    var accessibilityValue: String {
        switch self {
        case .off: "Off"
        case .on: "On"
        case .auto: "Auto"
        }
    }
}
