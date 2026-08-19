import SwiftUI

/// Everything about the floating overlay that is a *number*: its width, its
/// height, and the three properties of its border.
///
/// A short sheet with the background left interactive, for the same reason the
/// Layout sheet is one — every control here changes something that is only
/// judgeable by looking at it. The overlay defaults to the top-trailing corner
/// and this sheet is bottom-anchored, so the thing being adjusted is on screen
/// the entire time it is being adjusted. A pushed Settings row would have
/// covered it, which is why the Settings entry closes itself on the way in
/// rather than stacking this on top.
struct PiPParameterSheet: View {
    @Bindable var model: CameraViewModel

    /// The presets, as sRGB components.
    ///
    /// White first because it is the default and the one a camera border is
    /// usually meant to be; the rest are the strong, saturated colours that
    /// survive being drawn over a moving scene. Pastels are absent on purpose —
    /// at this width they read as a rendering artefact.
    private static let swatches: [(name: String, red: Double, green: Double, blue: Double)] = [
        ("White", 1, 1, 1),
        ("Black", 0, 0, 0),
        ("Yellow", 1, 0.831, 0.149),
        ("Red", 1, 0.231, 0.188),
        ("Green", 0.196, 0.843, 0.294),
        ("Blue", 0.192, 0.506, 1),
        ("Pink", 1, 0.176, 0.333),
    ]

    /// `CameraSlider` works in `Double`; the limits are `CGFloat`. Converted
    /// once here rather than inline, because a `...` at the start of a
    /// continuation line parses as the prefix range operator and the expression
    /// stops compiling.
    private static let widthRange =
        Double(OverlayMetrics.minimumWidthFraction)...Double(OverlayMetrics.maximumWidthFraction)
    private static let heightRange =
        Double(OverlayMetrics.minimumHeightFraction)...Double(OverlayMetrics.maximumHeightFraction)

    private static let sliderHeight: CGFloat = 18 + 8 + 28   // label row, gap, track
    private static let colourRowHeight: CGFloat = 18 + 10 + 34
    private static let contentSpacing: CGFloat = 20

    /// Title + four sliders + the colour row + margins, derived rather than
    /// rounded off so no band of empty material appears under the content.
    ///
    /// Five controls is enough that this can outgrow a short phone, where the
    /// system clamps the detent to what it can give. The content is in a
    /// `ScrollView` for exactly that case — and only that case, since
    /// `.scrollBounceBehavior(.basedOnSize)` leaves it inert whenever the
    /// content fits.
    private static var detentHeight: CGFloat {
        20 + 22
            + (contentSpacing + sliderHeight) * 4
            + contentSpacing + colourRowHeight
            + 24
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Self.contentSpacing) {
                header

                // Size before decoration: the two sliders that decide how much
                // of the shot the overlay takes belong above the three that
                // decide what its edge looks like.
                CameraSlider(
                    title: "Width",
                    value: Binding(
                        get: { Double(model.overlayWidthFraction) },
                        set: { model.setOverlayWidth(CGFloat($0)) }
                    ),
                    range: Self.widthRange,
                    format: Self.percent
                )

                CameraSlider(
                    title: "Height",
                    value: Binding(
                        get: { Double(model.overlayHeightFraction) },
                        set: { model.setOverlayHeight(CGFloat($0)) }
                    ),
                    range: Self.heightRange,
                    format: Self.percent
                )

                CameraSlider(
                    title: "Corner radius",
                    value: Binding(
                        get: { Double(model.overlayBorder.cornerRadius) },
                        set: { model.overlayBorder.cornerRadius = CGFloat($0) }
                    ),
                    range: 0...Double(OverlayBorderStyle.maximumCornerRadius),
                    format: { "\(Int($0.rounded()))" }
                )

                CameraSlider(
                    title: "Thickness",
                    value: Binding(
                        get: { Double(model.overlayBorder.width) },
                        set: { model.overlayBorder.width = CGFloat($0) }
                    ),
                    range: 0...Double(OverlayBorderStyle.maximumWidth),
                    // One decimal, because the whole range is three points wide
                    // and rounding to integers would give the slider four
                    // positions.
                    format: { String(format: "%.1f", $0) }
                )

                colourRow
            }
            .padding(.horizontal, DC.Spacing.edgeMargin)
            .padding(.top, 20)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([.height(Self.detentHeight), .large])
        .presentationBackground(.regularMaterial)
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled)
    }

    /// Both size sliders read as a share of the frame rather than as points.
    ///
    /// Points would be a lie on two counts: the number would mean something
    /// different on every screen size, and the overlay is recorded at the file's
    /// resolution, not the display's. A percentage is the one figure that is
    /// true of the preview and the recording at once.
    private static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("PiP Parameter")
                .font(DC.Font.sheetTitle)
                .foregroundStyle(DC.Color.chromePrimary)

            Spacer()

            // Shown only when there is something to undo, so the row is not
            // carrying a control that does nothing the first time it is seen.
            if model.hasCustomPiPParameters {
                Button("Reset") { model.resetPiPParameters() }
                    .font(DC.Font.sheetBody)
                    .foregroundStyle(DC.Color.accent)
                    .transition(.opacity)
            }
        }
        .dcAnimation(DC.Motion.fade, value: model.hasCustomPiPParameters)
    }

    // MARK: Colour

    private var colourRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Colour")
                    .font(DC.Font.sheetBody)
                    .foregroundStyle(DC.Color.chromeSecondary)

                Spacer()

                // The presets cover the common answers; this covers every other
                // one, opacity included — which is where the shipped 90% white
                // lives, and therefore the only way back to it by hand.
                ColorPicker(
                    "Custom colour",
                    selection: Binding(
                        get: { model.overlayBorder.swiftUIColor },
                        set: { model.overlayBorder.apply($0) }
                    ),
                    supportsOpacity: true
                )
                .labelsHidden()
            }

            HStack(spacing: 10) {
                ForEach(Self.swatches, id: \.name) { swatch in
                    swatchButton(swatch)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func swatchButton(
        _ swatch: (name: String, red: Double, green: Double, blue: Double)
    ) -> some View {
        let isSelected = model.overlayBorder.matchesColor(
            red: swatch.red, green: swatch.green, blue: swatch.blue
        )

        // A plain `Button` with nothing layered over it, per
        // `CircularControlButton`'s note: every composite gesture added to a
        // control in this app has cost it the single tap.
        return Button {
            // The opacity survives the change. A user who dialled their border
            // back to 40% is choosing a *colour*, not asking for the
            // transparency to be undone.
            model.overlayBorder.setColor(
                red: swatch.red,
                green: swatch.green,
                blue: swatch.blue,
                opacity: model.overlayBorder.opacity
            )
            HapticEngine.shared.sliderDetent()
        } label: {
            Circle()
                .fill(Color(.sRGB, red: swatch.red, green: swatch.green, blue: swatch.blue))
                .frame(width: 30, height: 30)
                .overlay {
                    // A hairline on every swatch, not just the dark one: black
                    // on material is invisible without it, and giving only that
                    // swatch a ring makes it look selected.
                    Circle().strokeBorder(DC.Color.hairline, lineWidth: 1)
                }
                .overlay {
                    if isSelected {
                        Circle()
                            .strokeBorder(DC.Color.accent, lineWidth: 2)
                            .padding(-4)
                    }
                }
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(swatch.name)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
