import AVKit
import SwiftData
import SwiftUI

/// Full-screen playback with trim and export (Doc 2 §12.1, Doc 3 Phase 6).
struct CaptureDetailView: View {
    let record: CaptureRecord
    let namespace: Namespace.ID

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(EntitlementGate.self) private var entitlements

    @State private var player: AVPlayer?
    @State private var dragOffset: CGFloat = 0
    @State private var isTrimming = false
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 1
    @State private var exportProgress: Double?
    @State private var exportTask: Task<Void, Never>?
    @State private var showingSourcePicker = false
    @State private var toast: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            content
                .matchedGeometryEffect(id: record.id, in: namespace)
                .offset(y: dragOffset)
                // Doc 2 §12.1: interactive, rubber-banded swipe-down dismissal.
                .scaleEffect(1 - min(abs(dragOffset) / 1200, 0.2))
                .gesture(dismissGesture)

            VStack {
                header
                Spacer()
                if isTrimming { trimBar }
                actionRow
            }

            if let exportProgress {
                exportOverlay(exportProgress)
            }
        }
        .overlay(alignment: .top) {
            if let toast {
                ToastView(toast: Toast(message: toast, systemImage: "checkmark.circle.fill"))
                    .padding(.top, 60)
                    .transition(.opacity)
            }
        }
        .animation(DC.Motion.standard, value: toast)
        .statusBarHidden()
        .analyticsScreen(AnalyticsScreen.captureDetail, class: "CaptureDetailView")
        .task { preparePlayer() }
        .onDisappear {
            player?.pause()
            exportTask?.cancel()
        }
        .confirmationDialog("Clean sources", isPresented: $showingSourcePicker) {
            if let name = record.primarySourceFileName {
                ShareLink(item: RecordingController.mediaDirectory.appending(path: name)) {
                    Text("Share primary source")
                }
            }
            if let name = record.secondarySourceFileName {
                ShareLink(item: RecordingController.mediaDirectory.appending(path: name)) {
                    Text("Share secondary source")
                }
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if record.isPhoto {
            ThumbnailImage(url: record.compositedURL)
                .aspectRatio(contentMode: .fit)
        } else if let player {
            VideoPlayer(player: player)
                .aspectRatio(9 / 16, contentMode: .fit)
        } else {
            ProgressView().tint(.white)
        }
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .dcSurface(in: Circle())
            }
            Spacer()
            VStack(spacing: 1) {
                Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 13, weight: .medium))
                Text("\(record.mode.displayName) · \(record.resolution.displayName)")
                    .font(.system(size: 11))
                    .foregroundStyle(DC.Color.chromeSecondary)
            }
            .foregroundStyle(.white)
            Spacer()
            Color.clear.frame(width: 40, height: 40)
        }
        .padding(.horizontal, DC.Spacing.edgeMargin)
        .padding(.top, 8)
    }

    private var actionRow: some View {
        HStack(spacing: 28) {
            // A simultaneous gesture, not a replacement one: `ShareLink` owns
            // the tap and offers no action closure, and consuming it here would
            // cost the user the share sheet to gain an event.
            ShareLink(item: record.compositedURL) {
                actionLabel("Share", "square.and.arrow.up")
            }
            .simultaneousGesture(TapGesture().onEnded {
                Analytics.log(AnalyticsEvent.captureShareTapped, [
                    AnalyticsParam.source: AnalyticsValue.sourceCaptureDetail,
                    AnalyticsParam.mediaType: record.analyticsMediaType,
                ])
            })

            Menu {
                ForEach(ExportPreset.allCases) { preset in
                    Button(preset.displayName) { export(preset) }
                }
            } label: {
                actionLabel("Export", "square.and.arrow.down")
            }

            if !record.isPhoto {
                Button {
                    isTrimming.toggle()
                    Analytics.log(AnalyticsEvent.trimToggled, [
                        AnalyticsParam.enabled: isTrimming,
                        AnalyticsParam.durationSeconds: record.duration,
                    ])
                } label: {
                    actionLabel("Trim", "scissors")
                }
            }

            if record.hasCleanSources {
                Button {
                    Analytics.log(AnalyticsEvent.cleanSourcesOpened, [
                        AnalyticsParam.source: AnalyticsValue.sourceCaptureDetail,
                        AnalyticsParam.mode: record.mode.rawValue,
                    ])
                    showingSourcePicker = true
                } label: {
                    actionLabel("Sources", "rectangle.on.rectangle")
                }
            }

            Button(role: .destructive) {
                Analytics.log(AnalyticsEvent.captureDeleted, [
                    AnalyticsParam.source: AnalyticsValue.sourceCaptureDetail,
                    AnalyticsParam.mediaType: record.analyticsMediaType,
                    AnalyticsParam.count: 1,
                ])
                CaptureLibrary.deleteFiles(for: record)
                context.delete(record)
                try? context.save()
                dismiss()
            } label: {
                actionLabel("Delete", "trash")
            }
        }
        .padding(.bottom, 28)
    }

    private func actionLabel(_ title: String, _ symbol: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
            Text(title)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(.white)
    }

    // MARK: Trim

    /// A dual-handle range over the clip. Doc 3 Phase 6 task 8 asks for
    /// frame-accurate output, which `AVAssetExportSession` gives via
    /// `timeRange` — the UI's job is only to express the range.
    private var trimBar: some View {
        VStack(spacing: 6) {
            Text("\(timeLabel(trimStart)) – \(timeLabel(trimEnd))")
                .font(DC.Font.pillLabel)
                .foregroundStyle(.white)

            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(DC.Color.chromeTertiary).frame(height: 36)

                    Capsule()
                        .fill(DC.Color.accent.opacity(0.25))
                        .frame(width: max(0, (trimEnd - trimStart) * width), height: 36)
                        .offset(x: trimStart * width)

                    handle.offset(x: trimStart * width - 6)
                        .gesture(handleDrag(width: width, isStart: true))
                    handle.offset(x: trimEnd * width - 6)
                        .gesture(handleDrag(width: width, isStart: false))
                }
            }
            .frame(height: 36)
        }
        .padding(.horizontal, DC.Spacing.edgeMargin)
        .padding(.bottom, 16)
    }

    private var handle: some View {
        RoundedRectangle.dc(3)
            .fill(DC.Color.accent)
            .frame(width: 12, height: 44)
    }

    private func handleDrag(width: CGFloat, isStart: Bool) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let fraction = (value.location.x / width).clamped(to: 0...1)
                if isStart {
                    trimStart = min(fraction, trimEnd - 0.02)
                } else {
                    trimEnd = max(fraction, trimStart + 0.02)
                }
            }
    }

    private func timeLabel(_ fraction: Double) -> String {
        let seconds = fraction * record.duration
        return String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }

    // MARK: Export

    /// Export is reported in three parts — started, completed, failed — because
    /// it is the app's one long-running user-facing operation, and a single
    /// "exported" count cannot distinguish a preset nobody picks from one that
    /// never finishes. `watermark` rides along as the free-tier marker: exports
    /// that carried one are the population the paywall is arguing with.
    private func export(_ preset: ExportPreset) {
        exportTask?.cancel()
        exportProgress = 0

        let parameters: [String: Any] = [
            AnalyticsParam.preset: preset.rawValue,
            AnalyticsParam.mediaType: record.analyticsMediaType,
            AnalyticsParam.trimmed: isTrimming,
            AnalyticsParam.watermark: entitlements.exportsWatermark,
            AnalyticsParam.durationSeconds: record.duration,
        ]
        Analytics.log(AnalyticsEvent.exportStarted, parameters)

        exportTask = Task {
            do {
                let range = isTrimming
                    ? (start: trimStart * record.duration, end: trimEnd * record.duration)
                    : nil
                let url = try await MediaExporter.export(
                    record: record,
                    preset: preset,
                    trim: range,
                    watermark: entitlements.exportsWatermark
                ) { progress in
                    Task { @MainActor in exportProgress = progress }
                }
                await PhotoLibraryExporter.saveToPhotos(url, isPhoto: record.isPhoto)
                exportProgress = nil
                Analytics.log(AnalyticsEvent.exportCompleted, parameters)
                Analytics.log(AnalyticsEvent.savedToPhotoLibrary, [
                    AnalyticsParam.source: AnalyticsValue.sourceCaptureDetail,
                    AnalyticsParam.mediaType: record.analyticsMediaType,
                ])
                showToast("Exported to Photos")
            } catch is CancellationError {
                exportProgress = nil
                Analytics.log(AnalyticsEvent.exportCancelled, parameters)
            } catch {
                exportProgress = nil
                Analytics.log(
                    AnalyticsEvent.exportFailed,
                    parameters.merging([AnalyticsParam.reason: error.localizedDescription]) {
                        current, _ in current
                    }
                )
                showToast(error.localizedDescription)
            }
        }
    }

    private func exportOverlay(_ progress: Double) -> some View {
        VStack(spacing: 14) {
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(DC.Color.accent)
                .frame(width: 200)
            Text("Exporting \(Int(progress * 100))%")
                .font(DC.Font.sheetBody)
                .foregroundStyle(.white)
            Button("Cancel") { exportTask?.cancel(); exportProgress = nil }
                .foregroundStyle(DC.Color.accent)
        }
        .padding(24)
        .dcSurfaceElevated(in: RoundedRectangle.dc(20))
    }

    private func showToast(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            toast = nil
        }
    }

    // MARK: Player

    private func preparePlayer() {
        guard !record.isPhoto else { return }
        let item = AVPlayerItem(url: record.compositedURL)
        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        self.player = player
        player.play()
    }

    private var dismissGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard value.translation.height > 0 else { return }
                // Rubber-banding: the further it is pulled, the less it moves.
                dragOffset = pow(value.translation.height, 0.85)
            }
            .onEnded { value in
                if value.translation.height > 140 {
                    dismiss()
                } else {
                    withAnimation(DC.Motion.standard) { dragOffset = 0 }
                }
            }
    }
}
