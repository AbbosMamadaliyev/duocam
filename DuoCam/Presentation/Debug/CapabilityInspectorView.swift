import AVFoundation
import SwiftUI

/// Ground truth about this device's capture hardware (Doc 3 Phase 0 task 5).
///
/// A developer tool, gated behind a debug flag, but it stays in the codebase
/// permanently for field diagnostics. Doc 3 reminder 2: when a user reports
/// "4K isn't offered on my phone", this screen is the answer.
struct CapabilityInspectorView: View {
    @State private var report: CapabilityReport?
    @State private var isProbing = false

    private let prober = CapabilityProber()

    var body: some View {
        NavigationStack {
            List {
                if let report {
                    SummarySection(report: report)
                    ModesSection(report: report)
                    if !report.pairings.isEmpty {
                        PairingsSection(report: report)
                    }
                    DevicesSection(report: report)
                } else {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Probing capture hardware…")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Capabilities")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await probe(forceRefresh: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isProbing)
                    .accessibilityLabel("Re-probe capabilities")
                }
            }
        }
        .task { await probe() }
    }

    private func probe(forceRefresh: Bool = false) async {
        isProbing = true
        defer { isProbing = false }
        report = await prober.report(forceRefresh: forceRefresh)
    }
}

// MARK: - Summary

private struct SummarySection: View {
    let report: CapabilityReport

    var body: some View {
        Section {
            Label {
                Text(report.summary)
                    .font(.subheadline.weight(.medium))
            } icon: {
                Image(systemName: report.isMultiCamSupported
                      ? "checkmark.circle.fill"
                      : "exclamationmark.triangle.fill")
                .foregroundStyle(report.isMultiCamSupported ? Color.green : Color.orange)
            }

            LabeledContent("Model", value: report.deviceModel)
            LabeledContent("System", value: report.systemVersion)
            LabeledContent("Probe time", value: "\(Int(report.probeDuration * 1000)) ms")
        } header: {
            Text("Summary")
        } footer: {
            if report.isRunningInSimulator {
                Text("AVCaptureMultiCamSession is never available in the simulator. "
                     + "The app runs on a simulated capture engine here; every capture "
                     + "acceptance criterion must be verified on A12+ hardware.")
            }
        }
    }
}

// MARK: - Modes

private struct ModesSection: View {
    let report: CapabilityReport

    var body: some View {
        Section {
            ForEach(CaptureMode.allCases) { mode in
                let available = report.availableModes.contains(mode)
                LabeledContent(mode.displayName) {
                    Text(available ? "Available" : "Hidden")
                        .foregroundStyle(available ? Color.green : Color.secondary)
                }
            }
        } header: {
            Text("Capture Modes")
        } footer: {
            Text("Unsupported modes are absent from the mode selector, not disabled — "
                 + "a control that can never be enabled is noise (Doc 2 §4.3).")
        }
    }
}

// MARK: - Pairing cost

private struct PairingsSection: View {
    let report: CapabilityReport

    var body: some View {
        Section {
            ForEach(report.pairings) { pairing in
                PairingRow(pairing: pairing)
            }
        } header: {
            Text("Hardware Cost")
        } footer: {
            Text("A configuration is rejected outright above 1.00 (Doc 1 §5.3.4). "
                 + "Recovery is the degradation ladder, not an error dialog.")
        }
    }
}

private struct PairingRow: View {
    let pairing: PairingCost

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(pairing.label)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(pairing.succeeded
                     ? String(format: "%.2f", pairing.hardwareCost)
                     : "—")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(pairing.isWithinBudget ? Color.green : Color.red)
            }

            if let reason = pairing.failureReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(Color.red)
            } else {
                Text("system pressure \(String(format: "%.2f", pairing.systemPressureCost))")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
        }
    }
}

// MARK: - Devices

private struct DevicesSection: View {
    let report: CapabilityReport

    var body: some View {
        Section("Cameras (\(report.devices.count))") {
            if report.devices.isEmpty {
                Text("No capture devices found")
                    .foregroundStyle(.secondary)
            }
            ForEach(report.devices) { device in
                NavigationLink(value: device.id) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.localizedName)
                            .font(.subheadline.weight(.medium))
                        Text("\(device.multiCamFormats.count) of \(device.totalFormatCount) formats multi-cam capable")
                            .font(.caption)
                            .foregroundStyle(device.hasMultiCamFormats ? Color.secondary : Color.orange)
                    }
                }
            }
        }
        .navigationDestination(for: String.self) { deviceID in
            if let device = report.devices.first(where: { $0.id == deviceID }) {
                DeviceFormatList(device: device)
            }
        }
    }
}

private struct DeviceFormatList: View {
    let device: DeviceCapability

    var body: some View {
        List {
            Section("Zoom") {
                LabeledContent(
                    "Range",
                    value: "\(String(format: "%.1f", device.minZoomFactor))× – \(String(format: "%.1f", device.maxZoomFactor))×"
                )
            }

            Section("Multi-cam formats (\(device.multiCamFormats.count))") {
                if device.multiCamFormats.isEmpty {
                    Text("None — this camera cannot participate in a multi-cam session")
                        .font(.footnote)
                        .foregroundStyle(Color.orange)
                }
                ForEach(device.multiCamFormats) { format in
                    FormatRow(format: format)
                }
            }
        }
        .navigationTitle(device.localizedName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct FormatRow: View {
    let format: MultiCamFormatInfo

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(format.dimensionLabel)
                    .font(.subheadline.monospacedDigit())
                Text(format.frameRateLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let tier = format.resolutionTier {
                Text(tier.displayName)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
            }

            if format.isBinned {
                Text("binned")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    CapabilityInspectorView()
}
