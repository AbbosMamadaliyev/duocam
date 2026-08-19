import SwiftUI

// MARK: - Layout sheet (Doc 2 §6.3)

/// **This is the fix for prototype problem P2**, where the five layout options
/// floated in the vertical middle of the screen, directly over the face of the
/// person being filmed.
///
/// They now live in a short bottom sheet that stays open during selection and
/// dims the preview by only 15% — the user has to be able to see the effect of
/// each layout while choosing between them.
struct LayoutSheet: View {
    @Bindable var model: CameraViewModel

    /// Gutter between cards. The cards themselves flex, so this is the only
    /// horizontal number the row needs.
    ///
    /// 6 rather than 8 since `pipWide` made this a six-card row: on a 375pt
    /// screen the five 8pt gutters plus the sheet's own margins left each card
    /// under 49pt, which is narrower than the schematic inside it. Two points
    /// per gutter is ten points back across the row, and the difference between
    /// a schematic that fits and one that is clipped.
    private static let cardGap: CGFloat = 6

    /// Title + gap + card row + top and bottom margins, and nothing else.
    ///
    /// The detent was a round 200 against ~160 of content, which left a band of
    /// empty material under the cards that read as a sheet that had failed to
    /// load the rest of itself. Derived from the content instead, so it stays
    /// right if the card grows.
    private static var detentHeight: CGFloat {
        20 + 22 + 16 + LayoutCard.height + 24
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Layout")
                .font(DC.Font.sheetTitle)
                .foregroundStyle(DC.Color.chromePrimary)

            HStack(spacing: Self.cardGap) {
                ForEach(LayoutType.allCases) { layout in
                    LayoutCard(
                        layout: layout,
                        isSelected: layout == model.configuration.layout,
                        // Doc 1 §4.5 gates the split layouts. Tapping one has
                        // always raised the paywall; until now the card gave no
                        // sign of it beforehand, so the paywall arrived as a
                        // surprise in place of the layout the user asked for.
                        isLocked: layout.isSplit && model.entitlements?.isPro == false
                    ) {
                        model.select(layout: layout)
                    }
                }
            }
        }
        // `edgeMargin` on all four sides. The cards divide what is left, so the
        // row can no longer overrun the sheet and pin itself to both edges.
        .padding(.horizontal, DC.Spacing.edgeMargin)
        .padding(.top, 20)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(Self.detentHeight)])
        .presentationBackground(.regularMaterial)
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled)
    }
}

// MARK: - Adjustments sheet (Doc 2 §6.2)

/// The manual controls, as a sheet.
///
/// Nothing in the camera chrome opens this any more — the controls live inside
/// Settings, one push down, and this wrapper survives for the `-forceSheet
/// adjustments` debug flag, which is the only way to reach that screen in a
/// state the simulator cannot be tapped into.
struct AdjustmentsSheet: View {
    @Bindable var model: CameraViewModel

    var body: some View {
        ScrollView {
            ManualControls(model: model)
                .padding(.horizontal, DC.Spacing.edgeMargin)
                .padding(.vertical, 20)
        }
        .presentationDetents([.height(280), .medium, .large])
        .presentationBackground(.regularMaterial)
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled)
    }
}

/// Because there are two live streams, the first row is a stream selector.
/// Every control below applies to whichever stream is selected — without that,
/// "exposure" would be ambiguous the moment a second camera exists.
///
/// Presentation-free on purpose: it is pushed inside the Settings navigation
/// stack *and* presented as a sheet, and `presentationDetents` applied from a
/// pushed view would resize the sheet it was pushed inside.
struct ManualControls: View {
    @Bindable var model: CameraViewModel

    @State private var stream: StreamRole = .primary
    @State private var exposure: Double = 0
    @State private var iso: Double = 400
    @State private var isoAuto = true
    @State private var shutter: Double = 60
    @State private var shutterAuto = true
    @State private var whiteBalance: Double = 5200
    @State private var whiteBalanceAuto = true
    @State private var focus: Double = 0.5
    @State private var focusAuto = true

    var body: some View {
        VStack(spacing: 22) {
            if model.hasSecondaryStream {
                CustomSegmentedControl(
                    options: StreamRole.allCases,
                    selection: $stream,
                    title: \.displayName,
                    height: 36,
                    accessibilityLabel: "Stream"
                )
            }

            CameraSlider(
                title: "Exposure",
                value: $exposure,
                range: -2...2,
                detent: 0,
                format: { String(format: "%+.1f EV", $0) }
            )
            .onChange(of: exposure) { _, new in
                model.applyManualControl(.exposureBias(Float(new)), to: stream)
            }

            CameraSlider(
                title: "ISO",
                value: $iso,
                range: 32...3200,
                format: { String(format: "%.0f", $0) },
                autoLabel: "AUTO",
                isAuto: isoAuto,
                onAutoToggle: {
                    isoAuto.toggle()
                    model.applyManualControl(.iso(isoAuto ? nil : Float(iso)), to: stream)
                }
            )
            .onChange(of: iso) { _, new in
                guard !isoAuto else { return }
                model.applyManualControl(.iso(Float(new)), to: stream)
            }

            CameraSlider(
                title: "Shutter",
                value: $shutter,
                range: 4...2000,
                format: { "1/\(Int($0))" },
                autoLabel: "AUTO",
                isAuto: shutterAuto,
                onAutoToggle: {
                    shutterAuto.toggle()
                    model.applyManualControl(.shutterSpeed(shutterAuto ? nil : shutter), to: stream)
                }
            )
            .onChange(of: shutter) { _, new in
                guard !shutterAuto else { return }
                model.applyManualControl(.shutterSpeed(new), to: stream)
            }

            CameraSlider(
                title: "White balance",
                value: $whiteBalance,
                range: 2000...8000,
                detent: 5200,
                format: { "\(Int($0))K" },
                autoLabel: "AWB",
                isAuto: whiteBalanceAuto,
                onAutoToggle: {
                    whiteBalanceAuto.toggle()
                    model.applyManualControl(
                        .whiteBalance(whiteBalanceAuto ? nil : Float(whiteBalance)), to: stream
                    )
                }
            )
            .onChange(of: whiteBalance) { _, new in
                guard !whiteBalanceAuto else { return }
                model.applyManualControl(.whiteBalance(Float(new)), to: stream)
            }

            CameraSlider(
                title: "Focus",
                value: $focus,
                range: 0...1,
                format: { String(format: "%.2f", $0) },
                autoLabel: "AF",
                isAuto: focusAuto,
                onAutoToggle: {
                    focusAuto.toggle()
                    model.applyManualControl(.focus(focusAuto ? nil : Float(focus)), to: stream)
                }
            )
            .onChange(of: focus) { _, new in
                guard !focusAuto else { return }
                model.applyManualControl(.focus(Float(new)), to: stream)
            }

            Button("Reset") {
                reset()
            }
            .font(DC.Font.sheetBody)
            .foregroundStyle(DC.Color.accent)
            .padding(.top, 4)
        }
    }

    private func reset() {
        exposure = 0
        iso = 400; isoAuto = true
        shutter = 60; shutterAuto = true
        whiteBalance = 5200; whiteBalanceAuto = true
        focus = 0.5; focusAuto = true
        model.applyManualControl(.resetAll, to: stream)
        HapticEngine.shared.success()
    }
}

// MARK: - Quality sheet (Doc 2 §6.4)

/// Unavailable options are shown **greyed with an inline reason**, never
/// hidden. Doc 2 §6.4: *"This teaches the user the real constraints instead of
/// leaving them confused."*
struct QualitySheet: View {
    @Bindable var model: CameraViewModel

    var body: some View {
        NavigationStack {
            List {
                Section("Resolution") {
                    ForEach(Resolution.allCases) { resolution in
                        optionRow(
                            title: resolution.displayName,
                            isSelected: model.configuration.quality.resolution == resolution,
                            unavailableReason: reason(for: resolution),
                            isPro: resolution == .uhd4K
                        ) {
                            model.selectResolution(resolution)
                        }
                    }
                }

                Section("Frame rate") {
                    ForEach(FrameRate.allCases) { rate in
                        optionRow(
                            title: rate.displayName,
                            isSelected: model.configuration.quality.frameRate == rate,
                            unavailableReason: reason(for: rate),
                            isPro: rate == .fps60
                        ) {
                            model.selectFrameRate(rate)
                        }
                    }
                }

                Section("Codec") {
                    ForEach(VideoCodec.allCases) { codec in
                        optionRow(
                            title: codec.displayName,
                            isSelected: model.configuration.quality.codec == codec,
                            unavailableReason: nil,
                            isPro: false
                        ) {
                            model.configuration.quality.codec = codec
                        }
                    }
                }

                Section {
                    Toggle(isOn: Binding(
                        get: { model.configuration.quality.savesCleanSources },
                        set: { model.setSavesCleanSources($0) }
                    )) {
                        HStack {
                            Text("Save clean sources")
                            if model.entitlements?.isPro == false { ProBadge() }
                        }
                    }
                } footer: {
                    Text("Also writes each camera's untouched footage, so you can "
                         + "re-edit the composition later.")
                }

                Section {
                    LabeledContent("Hardware cost") {
                        Text(String(format: "%.2f", model.negotiatedQuality.hardwareCost))
                            .monospacedDigit()
                    }
                } footer: {
                    Text("Options are queried live from the device and validated against "
                         + "hardware cost — the sheet never offers a combination that "
                         + "would subsequently fail.")
                }
            }
            .navigationTitle("Quality")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { model.probeQualityMatrix() }
        .presentationDetents([.height(420), .large])
        .presentationBackground(.regularMaterial)
    }

    @ViewBuilder
    private func optionRow(
        title: String,
        isSelected: Bool,
        unavailableReason: String?,
        isPro: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            if let unavailableReason {
                model.toasts.show(unavailableReason, isWarning: true)
                HapticEngine.shared.error()
            } else {
                action()
                HapticEngine.shared.sliderDetent()
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .foregroundStyle(unavailableReason == nil ? Color.primary : Color.secondary)
                        if isPro, model.entitlements?.isPro == false { ProBadge() }
                    }
                    if let unavailableReason {
                        Text(unavailableReason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isSelected, unavailableReason == nil {
                    Image(systemName: "checkmark")
                        .foregroundStyle(DC.Color.accent)
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// Both reasons come from `QualityConstraintMatrix`, which established them
    /// by *building a session* at that combination and reading the real
    /// `hardwareCost` — Doc 3 reminder 2's rule that the device is
    /// authoritative, applied to the one screen where guessing would be
    /// visible to the user.
    private func reason(for resolution: Resolution) -> String? {
        model.blockReason(
            resolution: resolution,
            frameRate: model.configuration.quality.frameRate
        )
    }

    private func reason(for rate: FrameRate) -> String? {
        model.blockReason(
            resolution: model.configuration.quality.resolution,
            frameRate: rate
        )
    }
}

// MARK: - Settings placeholder

struct SettingsPlaceholderSheet: View {
    @Environment(AppRouter.self) private var router
    @Environment(SubscriptionManager.self) private var subscriptions
    @Environment(\.dismiss) private var dismiss

    @Bindable var model: CameraViewModel

    var body: some View {
        NavigationStack {
            List {
                // First, above Capture, because it is the one row here that is
                // about how the footage *looks* rather than how it is made —
                // and the only one whose effect is invisible from inside this
                // sheet, which is why it closes it on the way through.
                Section {
                    Button {
                        model.presentPiPParameterSheet()
                    } label: {
                        HStack {
                            Text("PiP parameter")
                                .foregroundStyle(Color.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        // `.buttonStyle(.plain)` hit-tests the label's *content*
                        // and a `Spacer` is not content, so without this the row
                        // only responded to taps that landed on the word or the
                        // chevron — the gap between them, which is most of the
                        // row, did nothing.
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } footer: {
                    Text("Size, corner radius, thickness and colour of the "
                         + "floating preview. The camera stays visible while you "
                         + "adjust it.")
                }

                Section("Capture") {
                    Toggle("Grid", isOn: Binding(
                        get: { model.configuration.showsGrid },
                        set: { _ in model.toggleGrid() }
                    ))
                    Toggle("Level", isOn: Binding(
                        get: { model.configuration.showsLevel },
                        set: { _ in model.toggleLevel() }
                    ))
                    Toggle("Mirror front camera", isOn: Binding(
                        get: { model.configuration.mirrorsFrontCamera },
                        set: { model.configuration.mirrorsFrontCamera = $0 }
                    ))
                    Picker("Self-timer", selection: $model.selfTimer) {
                        ForEach(SelfTimer.allCases) { timer in
                            Text(timer.displayName).tag(timer)
                        }
                    }
                    Toggle("Save to Photos", isOn: $model.savesToPhotoLibrary)
                }

                // Moved out of the camera chrome, where it held a permanent slot
                // over the picture. Exposure, ISO, shutter, white balance and
                // focus are a setup decision — made once for a scene, rarely
                // mid-shot — and this is where setup decisions live.
                Section("Manual") {
                    NavigationLink("Manual controls") {
                        ScrollView {
                            ManualControls(model: model)
                                .padding(.horizontal, DC.Spacing.edgeMargin)
                                .padding(.vertical, 20)
                        }
                        .navigationTitle("Manual controls")
                        .navigationBarTitleDisplayMode(.inline)
                    }
                }

                Section("Lenses") {
                    ForEach(StreamRole.allCases) { role in
                        if role == .primary || model.hasSecondaryStream {
                            Picker(role.displayName, selection: Binding(
                                get: {
                                    role == .primary
                                        ? model.configuration.primarySource
                                        : (model.configuration.secondarySource ?? .front)
                                },
                                set: { model.setSource($0, for: role) }
                            )) {
                                ForEach(CameraSource.allCases) { source in
                                    Text(source.displayName).tag(source)
                                }
                            }
                        }
                    }
                }

                Section("Quality") {
                    Picker("Resolution", selection: Binding(
                        get: { model.configuration.quality.resolution },
                        set: { model.selectResolution($0) }
                    )) {
                        ForEach(Resolution.allCases) { Text($0.displayName).tag($0) }
                    }
                    Picker("Frame rate", selection: Binding(
                        get: { model.configuration.quality.frameRate },
                        set: { model.selectFrameRate($0) }
                    )) {
                        ForEach(FrameRate.allCases) { Text($0.displayName).tag($0) }
                    }
                    Picker("Codec", selection: Binding(
                        get: { model.configuration.quality.codec },
                        set: { model.configuration.quality.codec = $0 }
                    )) {
                        ForEach(VideoCodec.allCases) { Text($0.displayName).tag($0) }
                    }
                }

                Section("Pro") {
                    if model.entitlements?.isPro == true {
                        Label("DuoCam Pro is active", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(DC.Color.accent)
                    } else {
                        Button("Unlock DuoCam Pro") {
                            model.entitlements?.pendingFeature = nil
                            model.entitlements?.isShowingPaywall = true
                            dismiss()
                        }
                    }
                    Button("Restore Purchases") {
                        Task { await subscriptions.restore() }
                    }
                }

                Section("About") {
                    Button("Replay Introduction") {
                        dismiss()
                        router.replayOnboarding()
                    }
                    LabeledContent("Version", value: Bundle.appVersion)
                }

                Section("Diagnostics") {
                    Button("Capability Inspector") {
                        dismiss()
                        router.isShowingCapabilityInspector = true
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(.regularMaterial)
    }
}


/// A small Pro marker.
///
/// Doc 2 §12.3's "no dark patterns" applies here too: the badge says a feature
/// is paid, it does not pretend the feature is broken.
struct ProBadge: View {
    var body: some View {
        Text("PRO")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.black)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(DC.Color.accent, in: Capsule())
            .accessibilityLabel("Pro feature")
    }
}
