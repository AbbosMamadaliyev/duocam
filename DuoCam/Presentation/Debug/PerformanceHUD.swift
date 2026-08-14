import AVFoundation
import Foundation
import SwiftUI

/// Live performance figures (Doc 3 Phase 5 task 8).
///
/// Every number here corresponds to a budget in Doc 3's performance table.
/// Showing them side by side with their budgets is the point — a HUD that
/// reports "8.2 ms" without saying the ceiling is 6 ms is decoration.
@MainActor
@Observable
final class PerformanceMonitor {
    private(set) var gpuMillisecondsPerFrame: Double = 0
    private(set) var memoryMegabytes: Double = 0
    private(set) var thermalState: ProcessInfo.ThermalState = .nominal
    private(set) var framesAppended = 0
    private(set) var framesDropped = 0
    private(set) var hardwareCost: Float = 0

    private var timer: Task<Void, Never>?
    private weak var engine: (any CaptureEngine)?

    func start(engine: any CaptureEngine) {
        self.engine = engine
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.sample()
            }
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func sample() {
        thermalState = ProcessInfo.processInfo.thermalState
        memoryMegabytes = Self.footprintMegabytes()

        if let multiCam = engine as? MultiCamCaptureEngine {
            let stats = multiCam.performanceSnapshot()
            gpuMillisecondsPerFrame = stats.gpuMilliseconds
            framesAppended = stats.appended
            framesDropped = stats.dropped
            hardwareCost = stats.hardwareCost
        }
    }

    /// `phys_footprint` rather than `resident_size`: it is the number iOS
    /// actually uses when deciding what to terminate, and the only one Doc 3's
    /// 400 MB ceiling can meaningfully be checked against.
    nonisolated static func footprintMegabytes() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }
}

/// The HUD itself. Debug builds only, behind `-DCPerfHUD YES`.
struct PerformanceHUD: View {
    let monitor: PerformanceMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            row("GPU", String(format: "%.1f ms", monitor.gpuMillisecondsPerFrame),
                budget: 6, value: monitor.gpuMillisecondsPerFrame)
            row("MEM", String(format: "%.0f MB", monitor.memoryMegabytes),
                budget: 400, value: monitor.memoryMegabytes)
            row("COST", String(format: "%.2f", monitor.hardwareCost),
                budget: 1, value: Double(monitor.hardwareCost))
            row("DROP", String(format: "%.2f%%", dropPercent),
                budget: 0.1, value: dropPercent)
            row("THERM", thermalLabel, budget: nil, value: 0)
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .padding(8)
        .background(.black.opacity(0.55), in: RoundedRectangle.dc(8))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var dropPercent: Double {
        let total = monitor.framesAppended + monitor.framesDropped
        return total == 0 ? 0 : Double(monitor.framesDropped) / Double(total) * 100
    }

    private var thermalLabel: String {
        switch monitor.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "?"
        }
    }

    private func row(_ label: String, _ text: String, budget: Double?, value: Double) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .foregroundStyle(DC.Color.chromeSecondary)
                .frame(width: 38, alignment: .leading)
            Text(text)
                .foregroundStyle(overBudget(budget, value) ? DC.Color.record : DC.Color.chromePrimary)
        }
    }

    private func overBudget(_ budget: Double?, _ value: Double) -> Bool {
        guard let budget else { return false }
        return value > budget
    }
}
