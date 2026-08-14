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
            let geometry = model.geometry(
                screenSize: proxy.size,
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
                    GridOverlay().zIndex(DC.Layer.transient)
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

                if !model.isChromeHidden {
                    chrome(geometry: geometry, safeTop: safeTop, safeBottom: safeBottom)
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
            .onChange(of: model.overlayZone) { _, _ in model.syncComposition(with: geometry) }
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

    @ViewBuilder
    private func primaryPreview(geometry: LayoutGeometry) -> some View {
        let layout = model.configuration.layout

        if layout.isSplit, model.hasSecondaryStream {
            SplitPreview(model: model, geometry: geometry)
        } else {
            CameraPreviewView(source: model.engine.previewSource(for: .primary))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .gesture(previewTapGesture(geometry: geometry))
                .simultaneousGesture(previewDoubleTapGesture)
                .simultaneousGesture(previewLongPressGesture(geometry: geometry))
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

    private func previewTapGesture(geometry: LayoutGeometry) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                model.focus(
                    at: value.location,
                    normalized: normalize(value.location, in: geometry),
                    in: .primary
                )
            }
    }

    private var previewDoubleTapGesture: some Gesture {
        TapGesture(count: 2).onEnded {
            withAnimation(DC.Motion.fade) { model.isChromeHidden.toggle() }
        }
    }

    private func previewLongPressGesture(geometry: LayoutGeometry) -> some Gesture {
        LongPressGesture(minimumDuration: 0.5)
            .onEnded { _ in
                // Long press locks AE/AF at the screen centre when there is no
                // spatial information — `LongPressGesture` carries no location.
                let centre = CGPoint(x: geometry.screenSize.width / 2, y: geometry.screenSize.height / 2)
                model.lockFocus(at: centre, normalized: CGPoint(x: 0.5, y: 0.5), in: .primary)
            }
    }

    private func normalize(_ point: CGPoint, in geometry: LayoutGeometry) -> CGPoint {
        CGPoint(
            x: (point.x / geometry.screenSize.width).clamped(to: 0...1),
            y: (point.y / geometry.screenSize.height).clamped(to: 0...1)
        )
    }

    // MARK: Sheets

    @ViewBuilder
    private func sheetContent(_ sheet: CameraSheet) -> some View {
        switch sheet {
        case .layout:
            LayoutSheet(model: model)
        case .adjustments:
            AdjustmentsSheet(model: model)
        case .quality:
            QualitySheet(model: model)
        case .settings:
            SettingsPlaceholderSheet(model: model)
        }
    }
}

// MARK: - Top cluster (Doc 2 §4.2)

private struct TopCluster: View {
    @Bindable var model: CameraViewModel
    let router: AppRouter

    var body: some View {
        VStack(spacing: DC.Spacing.grid) {
            controlRow

            // Doc 2 §4.2 places the elapsed readout in the horizontal centre of
            // the top cluster, "which is empty in the idle state". On a 440pt
            // screen it is not empty enough: the quality pill plus the control
            // trio — plus the conditional overlay-rotate control — leave under
            // 60pt between them, and a 90pt timer pill drawn there lands behind
            // the controls.
            //
            // Design principle 4 ("nothing important is ever covered") outranks
            // the literal placement, so the readout takes its own centred row
            // directly beneath. It is still top, still centred, and now never
            // collides. Recorded as deviation D-3 in the build plan.
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
            QualityPill(
                quality: model.negotiatedQuality,
                isDimmed: model.isRecording
            ) {
                if model.isRecording {
                    model.toasts.show("Stop recording to change quality")
                    HapticEngine.shared.error()
                } else {
                    model.activeSheet = .quality
                }
            }

            Spacer(minLength: 0)

            // Doc 2 §4.2: the overlay-rotate control appears only for PiP
            // layouts, because in a split there is nothing to rotate.
            if model.configuration.layout.supportsOverlayRotation, model.hasSecondaryStream {
                CircularControlButton(
                    systemImage: "rectangle.portrait.rotate",
                    accessibilityLabel: "Rotate overlay",
                    accessibilityHint: "Switches the overlay between portrait and landscape"
                ) {
                    rotateOverlayAspect()
                }
                .transition(.scale.combined(with: .opacity))
            }

            CircularControlButton(
                systemImage: "slider.horizontal.3",
                accessibilityLabel: "Adjustments"
            ) {
                model.activeSheet = .adjustments
            }

            CircularControlButton(
                systemImage: model.configuration.flashMode.symbolName,
                isActive: model.configuration.flashMode != .off,
                accessibilityLabel: "Flash",
                accessibilityValue: model.configuration.flashMode.accessibilityValue
            ) {
                model.toggleFlash()
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
                    model.activeSheet = .settings
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
    }

    /// Toggles between the two PiP aspect ratios.
    private func rotateOverlayAspect() {
        let next: LayoutType = model.configuration.layout == .pipTall ? .pipRounded : .pipTall
        model.select(layout: next)
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
                .padding(.bottom, 20)
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

                // Doc 2 §4.3 fixes these positions exactly: gallery at
                // `edgeMargin`, shutter centred, swap at `center + 84`, layout
                // at `width - edgeMargin - 48`. Laying them out with `Spacer`s
                // instead lets the swap control drift into the shutter as the
                // screen width changes — which is how it ends up overlapping
                // on one device class and not another.
                //
                // The swap control is the one exception, and it is measured from
                // the *right* rather than from the centre: at `center + 84` its
                // 48pt disc lands half a point from the layout control's on a
                // 393pt screen, so the two read as a single fused capsule. It now
                // sits one `controlGap` inboard of layout, which keeps the pair
                // grouped as the two "what am I looking at" controls while
                // leaving 30pt of air to the shutter. Deviation D-4.
                GalleryButton(model: model)
                    .offset(x: -halfWidth + DC.Spacing.edgeMargin + DC.Size.bottomControl / 2)

                MorphingShutter(
                    state: model.shutterState,
                    onTap: { model.triggerShutter() }
                )
                .gesture(shutterSwipeGesture)

                CircularControlButton(
                    systemImage: "arrow.triangle.2.circlepath.camera",
                    size: DC.Size.bottomControl,
                    isEnabled: model.hasSecondaryStream,
                    accessibilityLabel: "Swap cameras",
                    accessibilityHint: "Swaps which camera fills the screen"
                ) {
                    model.swapStreams()
                }
                .offset(
                    x: halfWidth - DC.Spacing.edgeMargin
                        - DC.Size.bottomControl * 1.5 - DC.Spacing.controlGap
                )

                CircularControlButton(
                    systemImage: "rectangle.split.2x1",
                    size: DC.Size.bottomControl,
                    isEnabled: model.hasSecondaryStream,
                    accessibilityLabel: "Layout",
                    accessibilityHint: "Choose how the two streams are arranged"
                ) {
                    model.activeSheet = .layout
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

    /// Doc 2 §4.4: Photo ↔ Video is a swipe on the shutter region, not a row of
    /// its own. This is what removes the prototype's two-shutter ambiguity (P4).
    private var shutterSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                model.setPhotoVideoMode(value.translation.width < 0 ? .photo : .video)
            }
    }
}

private struct GalleryButton: View {
    @Bindable var model: CameraViewModel

    var body: some View {
        Button {
            // Doc 2 §7.4: gallery access is disabled during recording, where
            // this slot becomes the still-capture button instead.
            if model.isRecording {
                model.captureStillDuringVideo()
            } else {
                model.isShowingGallery = true
            }
        } label: {
            // Doc 2 §7.2: during recording this slot becomes a still-capture
            // button rather than a way out of the recording screen.
            //
            // With a camera glyph in it, not bare: an unlabelled white disc in
            // the slot that held the gallery a second ago says nothing about
            // what it now does, and the one guess it invites — "back to my
            // library" — is the opposite of what it does.
            Group {
                if model.isRecording {
                    Circle()
                        .fill(DC.Color.chromePrimary)
                        .frame(width: 40, height: 40)
                        .overlay {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.black)
                        }
                } else {
                    RoundedRectangle.dc(DC.Radius.thumbnail)
                        .fill(DC.Color.chromeTertiary.opacity(0.5))
                        .frame(width: DC.Size.bottomControl, height: DC.Size.bottomControl)
                        .overlay {
                            Image(systemName: "photo.on.rectangle")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(DC.Color.chromePrimary)
                        }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.isRecording ? "Capture still" : "Gallery")
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
                accessibilityLabel: model.isPaused ? "Resume recording" : "Pause recording"
            ) {
                model.togglePause()
            }

            CircularControlButton(
                systemImage: "flashlight.on.fill",
                isActive: model.configuration.isTorchOn,
                accessibilityLabel: "Torch"
            ) {
                model.setTorch(enabled: !model.configuration.isTorchOn)
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
        .ignoresSafeArea()
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
            TapGesture(count: 2).onEnded { model.swapStreams() }
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
