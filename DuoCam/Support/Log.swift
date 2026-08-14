import Foundation
import os

/// Structured logging façade (Doc 3 Phase 0 task 7).
///
/// One subsystem, five categories. Every category is a distinct `Logger` so the
/// Console.app sidebar splits them cleanly — which is the entire reason for the
/// split, since diagnosing a dropped-frame problem means reading the
/// composition log without recording chatter in the way.
enum Log {
    nonisolated static let subsystem = Bundle.main.bundleIdentifier ?? "com.altzet.DuoCam"

    /// Session setup, connection graph, format negotiation, hardware cost.
    nonisolated static let capture = Logger(subsystem: subsystem, category: "capture")
    /// Metal compositor, texture cache, frame pairing.
    nonisolated static let composition = Logger(subsystem: subsystem, category: "composition")
    /// Asset writers, timestamps, finalization.
    nonisolated static let recording = Logger(subsystem: subsystem, category: "recording")
    /// Thermal state, system pressure, the degradation ladder.
    nonisolated static let thermal = Logger(subsystem: subsystem, category: "thermal")
    /// View lifecycle, gestures, geometry.
    nonisolated static let ui = Logger(subsystem: subsystem, category: "ui")
}
