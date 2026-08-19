import SwiftData
import SwiftUI

/// The product.
///
/// Layer stack per Doc 2 §3.1, rendered back to front, with the preview
/// full-bleed behind everything. Design principle 1: *"The preview is the
/// interface."* There are no opaque bars and no reserved rectangles — the
/// correction to prototype problem P5.
struct CameraScreen: View {
    @Bindable var model: CameraViewModel
    @Environment(AppRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let safeTop = proxy.safeAreaInsets.top
            let safeBottom = proxy.safeAreaInsets.bottom
            // The `GeometryReader` is laid out *inside* the safe area, so
            // `proxy.size` is the inset size — but the `ZStack` below ignores
            // the safe area and therefore positions its children in full-screen
            // coordinates. Handing the inset size to `LayoutGeometry` made every
            // frame it computes short by the two insets: the bottom cluster's
            // obstacle rect sat ~120pt above the real shutter, and the overlay
            // could not be moved into the bottom fifth of the display at all.
            let screenSize = CGSize(
                width: proxy.size.width + proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing,
                height: proxy.size.height + safeTop + safeBottom
            )
            let geometry = model.geometry(
                screenSize: screenSize,
                safeTop: safeTop,
                safeBottom: safeBottom
            )

            ZStack {
                primaryPreview(geometry: geometry)
                    .zIndex(DC.Layer.preview)

                ChromeScrims()
                    .zIndex(DC.Layer.composition)

                secondaryStream(geometry: geometry)
                    .zIndex(DC.Layer.overlay)

                if model.configuration.showsGrid {
                    // Thirds of the *frame*, not of the display. A grid drawn
                    // over the letterbox bands would put its lines somewhere the
                    // recording has no equivalent of.
                    GridOverlay()
                        .frame(
                            width: geometry.previewRect.width,
                            height: geometry.previewRect.height
                        )
                        .zIndex(DC.Layer.transient)
                }

                if model.configuration.showsLevel {
                    LevelIndicator(rollDegrees: model.level.rollDegrees)
                        .zIndex(DC.Layer.transient)
                }

                if let indicator = model.focusIndicator {
                    FocusReticle(indicator: indicator)
                        .zIndex(DC.Layer.transient)
                }

                if let remaining = model.timerRemaining {
                    TimerCountdownOverlay(remaining: remaining)
                        .zIndex(DC.Layer.toast)
                }

                // Above the overlay, not below it. Without an explicit index the
                // chrome inherits 0 and the ZStack sorts it *under* both the
                // scrims and the floating overlay — which is why an overlay
                // parked on the left edge swallowed the taps meant for the
                // pause and torch controls. Design principle 4, "nothing
                // important is ever covered", is a z-order claim before it is a
                // geometry one.
                if !model.isChromeHidden {
                    chrome(geometry: geometry, safeTop: safeTop, safeBottom: safeBottom)
                        .zIndex(DC.Layer.topCluster)
                }

                // Above everything: the screen must actually be white for the
                // front camera's exposure, chrome included.
                ScreenFlashOverlay(isActive: model.isScreenFlashing)
                    .zIndex(DC.Layer.toast + 1)
                CaptureFlashOverlay(isActive: model.isCaptureFlashing)
                    .zIndex(DC.Layer.toast + 2)

                if DebugFlags.showsPerformanceHUD {
                    PerformanceHUD(monitor: model.performance)
                        .padding(.leading, DC.Spacing.edgeMargin)
                        .padding(.top, safeTop + 120)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .zIndex(DC.Layer.toast + 3)
                }
            }
            .ignoresSafeArea(.all)
            // The compositor has to be told the same geometry the chrome is
            // drawing with, on every change that can move the overlay.
            .onChange(of: geometry) { _, new in model.syncComposition(with: new) }
            .onChange(of: model.overlayCentreUnit) { _, _ in model.syncComposition(with: geometry) }
            // The border is not part of `LayoutGeometry` — it changes nothing
            // about where anything sits — so it needs its own push, or the
            // preview and the file disagree about the border for as long as
            // nothing else moves. The two size fractions *are* in the geometry,
            // so `onChange(of: geometry)` above already carries them.
            .onChange(of: model.overlayBorder) { _, _ in model.syncComposition(with: geometry) }
            .task(id: geometry) { model.syncComposition(with: geometry) }
        }
        .background(Color.black)
        .toastSlot(model.toasts)
        // Doc 2 §14 caps camera-overlay readouts at ".accessibilityMedium",
        // which has no `DynamicTypeSize` equivalent — the API offers
        // `.accessibility1`…`.accessibility5`. `.accessibility1` is the cap
        // used here: the chrome's control sizes are fixed at 44–76pt, and the
        // larger accessibility steps overflow them. Sheets, Settings, Gallery
        // and Onboarding are outside this modifier and stay uncapped.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .analyticsScreen(AnalyticsScreen.camera, class: "CameraScreen")
        .task { await model.start() }
        .sheet(item: Binding(get: { model.activeSheet }, set: { model.activeSheet = $0 })) { sheet in
            sheetContent(sheet)
        }
        .fullScreenCover(isPresented: Binding(
            get: { model.isShowingGallery },
            set: { model.isShowingGallery = $0 }
        )) {
            GalleryView()
                .modelContainer(model.library?.container ?? PreviewContainers.empty)
        }
    }

    // MARK: Previews

    /// The picture, at the shape it is recorded in.
    ///
    /// Confined to `geometry.previewRect` rather than full-bleed. Design
    /// principle 1 is *"the preview is the interface"*, and a preview stretched
    /// to a 19.5:9 display while the file is written at 16:9 is not that
    /// interface: it crops the sides the recording keeps, so the user frames one
    /// picture and receives another. The letterbox bands are black, the chrome
    /// floats over both, and the two now show the identical crop.
    @ViewBuilder
    private func primaryPreview(geometry: LayoutGeometry) -> some View {
        let layout = model.configuration.layout
        let picture = geometry.previewRect

        if layout.isSplit, model.hasSecondaryStream {
            SplitPreview(model: model, geometry: geometry)
                .frame(width: picture.width, height: picture.height)
        } else {
            CameraPreviewView(source: model.engine.previewSource(for: .primary))
                .frame(width: picture.width, height: picture.height)
                .contentShape(Rectangle())
                .gesture(previewTapGesture(picture: picture))
                .simultaneousGesture(previewDoubleTapGesture)
                .simultaneousGesture(previewLongPressGesture(picture: picture))
        }
    }

    @ViewBuilder
    private func secondaryStream(geometry: LayoutGeometry) -> some View {
        if model.hasSecondaryStream, model.configuration.layout.isPiP {
            FloatingOverlayView(
                source: model.engine.previewSource(for: .secondary),
                geometry: geometry,
                model: model
            )
        }
    }

    // MARK: Chrome

    @ViewBuilder
    private func chrome(geometry: LayoutGeometry, safeTop: CGFloat, safeBottom: CGFloat) -> some View {
        VStack(spacing: 0) {
            TopCluster(model: model, router: router)
                .padding(.horizontal, DC.Spacing.edgeMargin)
                .padding(.top, safeTop + DC.Spacing.grid)
                .zIndex(DC.Layer.topCluster)

            Spacer(minLength: 0)

            BottomCluster(model: model, geometry: geometry)
                .padding(.bottom, safeBottom + 12)
                .zIndex(DC.Layer.bottomCluster)
        }
        .opacity(model.isChromeDimmed ? 0.3 : 1)
        .dcAnimation(DC.Motion.fade, value: model.isChromeDimmed)
        .overlay(alignment: .leading) {
            if model.isRecording {
                RecordingControlStack(model: model)
                    .padding(.leading, DC.Spacing.edgeMargin)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .dcAnimation(DC.Motion.standard, value: model.isRecording)
    }

    // MARK: Preview gestures (Doc 2 §8)

    /// The tap arrives in the preview's own coordinates, which are the picture's.
    ///
    /// Two conversions come out of that, and they are not the same one: the
    /// engine wants the point normalised against the *picture* — a tap 40% down
    /// the frame must focus 40% down the frame, not 40% down a display that is
    /// taller than the frame — while the reticle is drawn in the full-screen
    /// ZStack and needs the letterbox offset added back.
    private func previewTapGesture(picture: CGRect) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                model.focus(
                    at: CGPoint(
                        x: value.location.x + picture.minX,
                        y: value.location.y + picture.minY
                    ),
                    normalized: normalize(value.location, in: picture.size),
                    in: .primary
                )
            }
    }

    private var previewDoubleTapGesture: some Gesture {
        TapGesture(count: 2).onEnded {
            withAnimation(DC.Motion.fade) { model.toggleChromeHidden() }
        }
    }

    private func previewLongPressGesture(picture: CGRect) -> some Gesture {
        LongPressGesture(minimumDuration: 0.5)
            .onEnded { _ in
                // Long press locks AE/AF at the centre of the frame when there
                // is no spatial information — `LongPressGesture` carries no
                // location.
                model.lockFocus(
                    at: CGPoint(x: picture.midX, y: picture.midY),
                    normalized: CGPoint(x: 0.5, y: 0.5),
                    in: .primary
                )
            }
    }

    private func normalize(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: (point.x / max(size.width, 1)).clamped(to: 0...1),
            y: (point.y / max(size.height, 1)).clamped(to: 0...1)
        )
    }

    // MARK: Sheets

    @ViewBuilder
    private func sheetContent(_ sheet: CameraSheet) -> some View {
        // Each sheet names itself. Left untracked they would all report as the
        // camera screen underneath them, and the four surfaces the app's whole
        // configuration lives on would be invisible in the screen report.
        switch sheet {
        case .layout:
            LayoutSheet(model: model)
                .analyticsScreen(AnalyticsScreen.sheetLayout, class: "LayoutSheet")
        case .adjustments:
            AdjustmentsSheet(model: model)
                .analyticsScreen(AnalyticsScreen.sheetAdjustments, class: "AdjustmentsSheet")
        case .quality:
            QualitySheet(model: model)
                .analyticsScreen(AnalyticsScreen.sheetQuality, class: "QualitySheet")
        case .settings:
            SettingsPlaceholderSheet(model: model)
                .analyticsScreen(AnalyticsScreen.sheetSettings, class: "SettingsSheet")
        case .pipParameters:
            PiPParameterSheet(model: model)
                .analyticsScreen(AnalyticsScreen.sheetPiPParameter, class: "PiPParameterSheet")
        }
    }
}

// MARK: - Top cluster (Doc 2 §4.2)

private struct TopCluster: View {
    @Bindable var model: CameraViewModel
    let router: AppRouter

    /// Doc 2 §4.2 places the elapsed readout in the horizontal centre of the top
    /// cluster, "which is empty in the idle state". It used to take a second row
    /// underneath instead, because in the idle state that centre is not empty:
    /// the quality pill and the control trio leave under 60pt between them.
    ///
    /// But this row is never in the idle state while the readout exists. The
    /// moment recording starts the quality pill, the torch and Settings all
    /// leave — quality cannot be changed mid-take, and Settings would rebuild
    /// the session — so the centre genuinely *is* empty and the readout can have
    /// the position the design asked for. Dropping it to its own row also pushed
    /// it into the frame, which is the one place a recording indicator should
    /// never be.
    ///
    /// It is drawn as an overlay rather than as a row member so its width never
    /// pushes the controls around: it is centred on the screen, not on whatever
    /// space the controls left over. Reverses deviation D-3.
    var body: some View {
        controlRow
            .overlay {
                if model.isRecording {
                    ElapsedTimerPill(elapsed: model.elapsed, isPaused: model.isPaused)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .dcAnimation(DC.Motion.standard, value: model.isRecording)
            .dcAnimation(DC.Motion.standard, value: model.configuration.layout)
    }

    /// `grid` rather than `controlGap` between these: four 44pt controls plus
    /// the quality pill do not fit a 393pt screen at 12pt spacing, and the pill
    /// is what loses — see `QualityPill`. 8pt keeps the 44pt targets intact
    /// while giving the readout the width it needs.
    private var controlRow: some View {
        HStack(alignment: .top, spacing: DC.Spacing.grid) {
            // Gone while recording rather than dimmed. It used to stay as a
            // greyed-out `1080p │ 30 FPS`, which is a readout of something the
            // user cannot change and already decided before pressing record —
            // and it is the only thing standing between the elapsed timer and
            // the centre of the row it now shares. A control that can neither be
            // used nor acted on is chrome over the shot.
            if !model.isRecording {
                QualityPill(quality: model.negotiatedQuality) {
                    model.presentSheet(.quality, from: AnalyticsValue.sourceQualityPill)
                }
                .transition(.scale.combined(with: .opacity))
            }

            Spacer(minLength: 0)

            // The frame shape, first in the trailing cluster.
            //
            // Two controls used to lead this row and neither earned the space.
            // The overlay-rotate control changed the *overlay's* proportions,
            // which the pinch and the Layout sheet both already do, and it
            // appeared and vanished with the layout — a control that comes and
            // goes teaches the user to stop looking for anything here. The
            // Adjustments control opened a sheet of manual exposure, ISO,
            // shutter, white balance and focus: a settings screen wearing a
            // camera control's clothes, given a permanent slot over the picture
            // for a panel most takes never touch. It lives in Settings now.
            //
            // What replaced them is the one thing on this row the user changes
            // per shot and can see the result of instantly.
            if !model.isRecording {
                AspectRatioButton(ratio: model.configuration.aspectRatio) {
                    model.toggleAspectRatio()
                }
                .transition(.scale.combined(with: .opacity))
            }

            // Doc 2 §4.2 gives this slot to flash, and flash is only read where
            // a still is exposed — `capturePhoto` builds the
            // `AVCapturePhotoSettings`. Nothing in the video path ever looked at
            // it, so in Video mode this control used to cycle its own icon
            // through three states and change nothing about the picture.
            //
            // In Video mode it is now the torch, which is the light source a
            // take can actually use. One slot, one meaning per mode, and neither
            // meaning is decorative.
            //
            // Hidden while recording, alongside Settings: the recording stack
            // takes over the torch for the duration, and the same control on two
            // edges of one screen makes the user look for a difference that does
            // not exist.
            if !model.isRecording {
                if model.configuration.photoVideoMode == .photo {
                    CircularControlButton(
                        systemImage: model.configuration.flashMode.symbolName,
                        isActive: model.configuration.flashMode != .off,
                        accessibilityLabel: "Flash",
                        accessibilityValue: model.configuration.flashMode.accessibilityValue
                    ) {
                        model.toggleFlash()
                    }
                } else {
                    CircularControlButton(
                        systemImage: model.configuration.isTorchOn
                            ? "flashlight.on.fill" : "flashlight.off.fill",
                        isActive: model.configuration.isTorchOn,
                        accessibilityLabel: "Torch",
                        accessibilityValue: model.configuration.isTorchOn ? "On" : "Off"
                    ) {
                        model.toggleTorch()
                    }
                }
            }

            // Hidden while recording: Settings carries the resolution, frame
            // rate, codec and lens pickers, every one of which tears down and
            // rebuilds the session. Offering them mid-take is offering the user
            // a way to end their own recording. The quality pill already refuses
            // for the same reason; this is the same rule, applied where the
            // control cannot be usefully dimmed.
            if !model.isRecording {
                CircularControlButton(
                    systemImage: "gearshape",
                    accessibilityLabel: "Settings"
                ) {
                    model.presentSheet(.settings, from: AnalyticsValue.sourceCameraChrome)
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
    }
}

// MARK: - Aspect ratio control

/// 16:9 ↔ 4:3, on one tap.
///
/// Text rather than a glyph: SF Symbols has `aspectratio`, and it says "this is
/// about proportions" without saying *which* proportion is live — which is the
/// only thing the user needs from this control at a glance.
///
/// Built as a plain `Button` with `.buttonStyle(.plain)` and nothing layered on
/// top, for the reason spelled out at length in `CircularControlButton`: every
/// version of these chrome controls that added a `ButtonStyle`, a
/// `contentShape` or a gesture composite lost the single tap.
private struct AspectRatioButton: View {
    let ratio: AspectRatio
    var size: CGFloat = DC.Size.control
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            Text(ratio.displayName)
                .font(DC.Font.pillLabel)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(DC.Color.chromePrimary)
                .frame(width: size, height: size)
                .dcSurface(in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Aspect ratio")
        .accessibilityValue(ratio.displayName)
        .accessibilityHint("Switches the frame between 16 by 9 and 4 by 3")
    }
}

// MARK: - Bottom cluster (Doc 2 §4.3)

private struct BottomCluster: View {
    @Bindable var model: CameraViewModel
    let geometry: LayoutGeometry

    private var halfWidth: CGFloat { geometry.screenSize.width / 2 }

    var body: some View {
        VStack(spacing: DC.Spacing.grid) {
            if model.areZoomPillsVisible, !model.zoomStops.isEmpty {
                ZoomPillGroup(
                    stops: model.zoomStops,
                    selected: model.selectedZoomStop,
                    onSelect: { model.selectZoom($0) }
                )
                .padding(.bottom, DC.Spacing.zoomPillGap)
                .transition(.opacity)
            }

            // Tier 1 — primary control row.
            ZStack {
                if model.subModeLabelVisible {
                    Text(model.configuration.photoVideoMode.displayName)
                        .font(DC.Font.microLabel)
                        .tracking(2)
                        .foregroundStyle(DC.Color.chromeSecondary)
                        .offset(y: -DC.Size.shutterOuter / 2 - 16)
                        .transition(.opacity)
                }

                // Five fixed positions rather than `Spacer`s, for the reason
                // Doc 2 §4.3 gives: spacers let the inner controls drift into
                // the shutter as the screen width changes, which is how a row
                // overlaps on one device class and not another. Every offset
                // below is measured from the nearest screen edge, so the
                // spacing between neighbours is a constant.
                //
                // Left to right: gallery · layout · record · photo · swap. The
                // two shutters sit either side of centre because they are the
                // two things this row exists for, and the four utility controls
                // are pushed to the edges around them. Deviation D-4.
                GalleryButton(model: model)
                    .offset(x: -halfWidth + DC.Spacing.edgeMargin + DC.Size.bottomControl / 2)

                CircularControlButton(
                    systemImage: "rectangle.split.2x1",
                    size: DC.Size.bottomControl,
                    isEnabled: model.hasSecondaryStream,
                    accessibilityLabel: "Layout",
                    accessibilityHint: "Choose how the two streams are arranged"
                ) {
                    model.presentSheet(.layout, from: AnalyticsValue.sourceCameraChrome)
                }
                .offset(
                    x: -halfWidth + DC.Spacing.edgeMargin
                        + DC.Size.bottomControl * 1.5 + DC.Spacing.controlGap
                )

                // The red button is video and only video now. It kept the morph
                // — idle circle to recording square — because that is what says
                // a take is running; what it lost is having to also stand for
                // Photo, which is what made a single button ambiguous about
                // which mode a tap would act in.
                MorphingShutter(
                    state: model.shutterState,
                    onTap: { model.triggerRecord() }
                )

                PhotoShutterButton(
                    isEnabled: model.isPhotoButtonEnabled,
                    capturesDuringRecording: model.isRecording
                ) {
                    model.triggerPhoto()
                }
                .offset(
                    x: halfWidth - DC.Spacing.edgeMargin
                        - DC.Size.bottomControl - DC.Spacing.controlGap
                        - DC.Size.photoShutter / 2
                )

                CircularControlButton(
                    systemImage: "arrow.triangle.2.circlepath.camera",
                    size: DC.Size.bottomControl,
                    isEnabled: model.hasSecondaryStream,
                    accessibilityLabel: "Swap cameras",
                    accessibilityHint: "Swaps which camera fills the screen"
                ) {
                    model.swapStreams()
                }
                .offset(x: halfWidth - DC.Spacing.edgeMargin - DC.Size.bottomControl / 2)
            }
            .frame(maxWidth: .infinity)
            .frame(height: DC.Size.shutterOuter)

            // Tier 2 — mode selector. Hidden entirely during recording.
            if geometry.isModeSelectorVisible, model.availableModes.count > 1 {
                CustomSegmentedControl(
                    options: model.availableModes,
                    selection: Binding(
                        get: { model.configuration.mode },
                        set: { model.select(mode: $0) }
                    ),
                    title: \.displayName,
                    accessibilityLabel: "Capture mode"
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, DC.Spacing.edgeMargin)
        .dcAnimation(DC.Motion.standard, value: model.isRecording)
        .dcAnimation(DC.Motion.fade, value: model.areZoomPillsVisible)
        .dcAnimation(DC.Motion.fade, value: model.subModeLabelVisible)
    }
}

// MARK: - Photo shutter

/// The white button: one still, one tap.
///
/// Doc 2 §4.4 made Photo ↔ Video a *swipe* on a single morphing shutter,
/// specifically to avoid the prototype's two side-by-side circles (problem P4).
/// The objection there was real but it was about ambiguity, not about count:
/// two identical discs with no indication of which was armed. Two visibly
/// different buttons that each do exactly one thing are not ambiguous — the red
/// one records, the white one takes a picture — and they cost nothing to
/// discover, where a swipe on an unmarked control costs everything.
///
/// During a take it keeps working, as the full-resolution still capture
/// Doc 2 §7.2 asks for. That is the same action, not a different one wearing
/// the same button, which is why the appearance does not change.
private struct PhotoShutterButton: View {
    let isEnabled: Bool
    let capturesDuringRecording: Bool
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(
                        isEnabled ? DC.Color.chromePrimary : DC.Color.chromeTertiary,
                        lineWidth: 2.5
                    )
                Circle()
                    .fill(isEnabled ? DC.Color.chromePrimary : DC.Color.chromeTertiary)
                    .padding(5)
            }
            .frame(width: DC.Size.photoShutter, height: DC.Size.photoShutter)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(capturesDuringRecording ? "Capture still" : "Take photo")
        .accessibilityValue(capturesDuringRecording ? "Recording continues" : "")
    }
}

private struct GalleryButton: View {
    @Bindable var model: CameraViewModel

    var body: some View {
        Button {
            model.openGallery()
        } label: {
            // A circle, like every other control in this row. It was the one
            // rounded square among four discs, which read as an element from a
            // different screen that had drifted in.
            //
            // It also no longer turns into a still-capture button during a take.
            // That reassignment existed because there was nowhere else to put
            // the still; now there is a dedicated white shutter two slots over,
            // and a control that silently becomes a different control is only
            // ever worth it when nothing else can do the job.
            Image(systemName: "photo.on.rectangle")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(model.isRecording ? DC.Color.chromeTertiary : DC.Color.chromePrimary)
                .frame(width: DC.Size.bottomControl, height: DC.Size.bottomControl)
                .dcSurface(in: Circle())
        }
        .buttonStyle(.plain)
        // Doc 2 §7.4: the library is not a place to be sent mid-take.
        .disabled(model.isRecording)
        .accessibilityLabel("Gallery")
        .dcAnimation(DC.Motion.standard, value: model.isRecording)
    }
}

// MARK: - Recording-only chrome (Doc 2 §7.2)

/// Only the controls that mean something *because* a take is running: pause,
/// and the one light source that can be changed mid-take.
///
/// Adjustments used to sit here as well, while also sitting in the top cluster
/// throughout — the same control twice on one screen, which makes the user look
/// for a difference that does not exist. Audio metering sat here too, as a
/// button whose entire behaviour was a toast saying the feature did not exist
/// yet; a control that announces its own absence reads as a broken control.
private struct RecordingControlStack: View {
    @Bindable var model: CameraViewModel

    var body: some View {
        VStack(spacing: DC.Spacing.controlGap) {
            CircularControlButton(
                systemImage: model.isPaused ? "record.circle" : "pause.fill",
                isActive: model.isPaused,
                accessibilityLabel: model.isPaused ? "Resume recording" : "Pause recording",
                accessibilityValue: model.isPaused ? "Paused" : "Recording"
            ) {
                model.togglePause()
            }

            // Through `toggleTorch`, not `setTorch`. `setTorch` is a no-op
            // whenever the primary stream is front-facing — there is no LED the
            // front camera can see — and this control used to take that no-op
            // silently while still lighting up as though the torch were on.
            CircularControlButton(
                systemImage: model.configuration.isTorchOn
                    ? "flashlight.on.fill" : "flashlight.off.fill",
                isActive: model.configuration.isTorchOn,
                accessibilityLabel: "Torch",
                accessibilityValue: model.configuration.isTorchOn ? "On" : "Off"
            ) {
                model.toggleTorch(source: AnalyticsValue.sourceRecordingStack)
            }
        }
    }
}

// MARK: - Focus reticle (Doc 2 §8)

private struct FocusReticle: View {
    let indicator: FocusIndicator

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scale: CGFloat = 1.3

    var body: some View {
        VStack(spacing: 6) {
            RoundedRectangle.dc(4)
                .stroke(indicator.isLocked ? DC.Color.accent : DC.Color.chromePrimary, lineWidth: 1.5)
                .frame(width: 74, height: 74)
                .scaleEffect(scale)

            if indicator.isLocked {
                Text("AE/AF LOCK")
                    .font(DC.Font.microLabel)
                    .tracking(1.4)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(DC.Color.accent, in: RoundedRectangle.dc(3))
            }
        }
        .position(indicator.point)
        .allowsHitTesting(false)
        .onAppear {
            guard !reduceMotion else { scale = 1; return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { scale = 1 }
        }
    }
}

// MARK: - Split layouts (Doc 2 §5.7)

private struct SplitPreview: View {
    @Bindable var model: CameraViewModel
    let geometry: LayoutGeometry

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let split = height * model.splitRatio

            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    CameraPreviewView(source: model.engine.previewSource(for: .primary))
                        .frame(height: split)
                    CameraPreviewView(source: model.engine.previewSource(for: .secondary))
                        .frame(height: height - split)
                }

                SplitDividerHandle(model: model, containerHeight: height)
                    .offset(y: split)
            }
        }
        // Sized by the caller to the picture, so the split divides the recorded
        // frame at the same ratio the file does.
        .dcAnimation(DC.Motion.layout, value: model.splitRatio)
    }
}

private struct SplitDividerHandle: View {
    @Bindable var model: CameraViewModel
    let containerHeight: CGFloat

    @State private var hasCrossedCentre = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(DC.Color.chromePrimary.opacity(0.5))
                .frame(height: 4)

            Capsule()
                .fill(DC.Color.chromePrimary)
                .frame(width: 36, height: 5)
        }
        .frame(height: 44)
        .contentShape(Rectangle())
        .offset(y: -22)
        .gesture(
            DragGesture()
                .onChanged { value in
                    let ratio = ((value.location.y) / containerHeight).clamped(to: 0.3...0.7)
                    // Doc 2 §5.7: a rigid detent at exactly 50%, fired once per
                    // crossing so it reads as a notch rather than a buzz.
                    let nearCentre = abs(ratio - 0.5) < 0.01
                    if nearCentre, !hasCrossedCentre {
                        HapticEngine.shared.dividerCentred()
                        hasCrossedCentre = true
                    } else if !nearCentre {
                        hasCrossedCentre = false
                    }
                    model.splitRatio = nearCentre ? 0.5 : ratio
                }
        )
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                model.swapStreams(source: AnalyticsValue.sourceSplitDivider)
            }
        )
        .accessibilityLabel("Split divider")
        .accessibilityValue("\(Int(model.splitRatio * 100)) percent")
        .accessibilityAdjustableAction { direction in
            let step: CGFloat = 0.05
            switch direction {
            case .increment: model.splitRatio = min(0.7, model.splitRatio + step)
            case .decrement: model.splitRatio = max(0.3, model.splitRatio - step)
            @unknown default: break
            }
        }
    }
}
