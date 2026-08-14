import SwiftUI

/// Every design-system component, in every state, over a camera-like scene.
///
/// Phase B's acceptance criterion is that each component renders correctly in
/// both idle and active states. SwiftUI `#Preview`s cover that in Xcode, but
/// they cannot be screenshotted from a headless build, and — more importantly —
/// they cannot show whether the 0.5pt hairline actually saves a material pill
/// against a *bright* scene. That question only has an answer on a real
/// gradient, at real size, on the real device class.
///
/// Reachable via `xcrun simctl launch <udid> com.altzet.DuoCam -DCGallery YES`.
struct DesignSystemGalleryView: View {
    @State private var mode: CaptureMode = .dualFrontBack
    @State private var role: StreamRole = .primary
    @State private var layout: LayoutType = .pipRounded
    @State private var zoom: String = "1x"
    @State private var exposure: Double = 0
    @State private var iso: Double = 800
    @State private var isoAuto = true
    @State private var flash: FlashMode = .off

    var body: some View {
        ZStack {
            simulatedScene

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    section("Shutter — 5 states") {
                        HStack(spacing: 18) {
                            labelled("Photo") { MorphingShutter(state: .photoIdle) }
                            labelled("Video") { MorphingShutter(state: .videoIdle) }
                            labelled("Rec") { MorphingShutter(state: .videoRecording) }
                        }
                        HStack(spacing: 18) {
                            labelled("Paused") { MorphingShutter(state: .videoPaused) }
                            labelled("Off") { MorphingShutter(state: .disabled) }
                            labelled("Burst") {
                                MorphingShutter(state: .photoIdle, longPressProgress: 0.65)
                            }
                        }
                    }

                    section("Top cluster") {
                        HStack(spacing: DC.Spacing.controlGap) {
                            QualityPill(quality: NegotiatedQuality(
                                resolution: .uhd4K, frameRate: .fps30, hardwareCost: 0.82
                            ))
                            Spacer()
                            CircularControlButton(
                                systemImage: "slider.horizontal.3",
                                accessibilityLabel: "Adjustments"
                            )
                            CircularControlButton(
                                systemImage: flash.symbolName,
                                isActive: flash != .off,
                                accessibilityLabel: "Flash",
                                accessibilityValue: flash.accessibilityValue,
                                action: { flash = flash.next }
                            )
                            CircularControlButton(
                                systemImage: "gearshape",
                                accessibilityLabel: "Settings"
                            )
                        }
                    }

                    section("Recording readout") {
                        HStack(spacing: 20) {
                            ElapsedTimerPill(elapsed: 92)
                            ElapsedTimerPill(elapsed: 92, isPaused: true)
                        }
                    }

                    section("Zoom pills") {
                        ZoomPillGroup(
                            stops: [
                                .init(label: "0.5x", zoomFactor: 0.5),
                                .init(label: "1x", zoomFactor: 1),
                                .init(label: "3x", zoomFactor: 3),
                            ],
                            selected: zoom,
                            onSelect: { zoom = $0.id }
                        )
                    }

                    section("Mode selector") {
                        CustomSegmentedControl(
                            options: CaptureMode.allCases,
                            selection: $mode,
                            title: \.displayName,
                            accessibilityLabel: "Capture mode"
                        )
                    }

                    section("Stream selector") {
                        CustomSegmentedControl(
                            options: StreamRole.allCases,
                            selection: $role,
                            title: \.displayName,
                            height: 36,
                            accessibilityLabel: "Stream"
                        )
                    }

                    // Layout cards and sliders never sit directly on the
                    // preview — they live inside sheets on `.regularMaterial`
                    // (Doc 2 §6.2, §6.3). Showing them on bare scene would
                    // misrepresent their contrast.
                    section("Layout cards (sheet context)") {
                        sheetContext {
                            HStack(spacing: 8) {
                                ForEach(LayoutType.allCases) { candidate in
                                    LayoutCard(layout: candidate, isSelected: candidate == layout) {
                                        layout = candidate
                                        HapticEngine.shared.layoutSelected()
                                    }
                                }
                            }
                        }
                    }

                    section("Sliders (sheet context)") {
                        sheetContext {
                            VStack(spacing: 20) {
                                CameraSlider(
                                    title: "Exposure",
                                    value: $exposure,
                                    range: -2...2,
                                    detent: 0,
                                    format: { String(format: "%+.1f EV", $0) }
                                )
                                CameraSlider(
                                    title: "ISO",
                                    value: $iso,
                                    range: 32...3200,
                                    format: { String(format: "%.0f", $0) },
                                    autoLabel: "AUTO",
                                    isAuto: isoAuto,
                                    onAutoToggle: { isoAuto.toggle() }
                                )
                            }
                        }
                    }

                    section("Toasts") {
                        ToastView(toast: Toast(
                            message: "Reducing quality to keep recording",
                            systemImage: "thermometer.high",
                            isWarning: true
                        ))
                        ToastView(toast: Toast(
                            message: "Recording saved",
                            systemImage: "checkmark.circle.fill"
                        ))
                    }

                    section("Overlay treatment") {
                        HStack(spacing: 16) {
                            overlaySample(
                                shape: AnyShape(RoundedRectangle.dc(DC.Radius.overlay)),
                                size: CGSize(width: 96, height: 128)
                            )
                            overlaySample(
                                shape: AnyShape(Circle()),
                                size: CGSize(width: 112, height: 112)
                            )
                        }
                    }
                }
                .padding(DC.Spacing.edgeMargin)
                .padding(.vertical, 40)
            }
            .defaultScrollAnchor(DebugFlags.galleryStartsAtBottom ? .bottom : .top)
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Scene

    /// A deliberately *bright*, saturated backdrop. Chrome that reads well over
    /// black proves nothing — the hard case is white sky and pale skin tones.
    private var simulatedScene: some View {
        LinearGradient(
            colors: [
                Color(hex: 0xFFF4D6),
                Color(hex: 0x8FD3F4),
                Color(hex: 0x2B1B4A),
                Color(hex: 0xF7A072),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    /// Mirrors `pipCircle` needing a square frame — a `Circle` inside a 3:4
    /// frame inscribes rather than fills, leaving the stroke and the content
    /// disagreeing about where the edge is.
    private func overlaySample(shape: AnyShape, size: CGSize) -> some View {
        LinearGradient(colors: [.pink, .indigo], startPoint: .top, endPoint: .bottom)
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .overlay {
                shape.stroke(
                    DC.Color.chromePrimary.opacity(DC.Stroke.overlayOpacity),
                    lineWidth: DC.Stroke.overlay
                )
            }
            .shadow(
                color: .black.opacity(DC.Shadow.overlayOpacity),
                radius: DC.Shadow.overlayRadius,
                y: DC.Shadow.overlayY
            )
    }

    // MARK: Scaffolding

    @ViewBuilder
    private func section(
        _ title: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(DC.Font.microLabel)
                .tracking(1.4)
                .foregroundStyle(DC.Color.chromePrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(DC.Color.scrim, in: Capsule())

            content()
        }
    }

    /// Stands in for a presented sheet's `.regularMaterial` background.
    private func sheetContext(@ViewBuilder content: () -> some View) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dcSurfaceElevated(in: RoundedRectangle.dc(DC.Radius.card))
    }

    private func labelled(
        _ title: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(spacing: 6) {
            content()
            Text(title)
                .font(DC.Font.pillCaption)
                .foregroundStyle(DC.Color.chromePrimary)
        }
    }
}

#Preview {
    DesignSystemGalleryView()
}
