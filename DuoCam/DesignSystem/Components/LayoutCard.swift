import SwiftUI

/// One card in the Layout sheet (Doc 2 §6.3).
///
/// The card shows a *schematic* of the layout — a rounded rectangle standing in
/// for the screen with a smaller filled shape showing where the secondary
/// stream sits — rather than an icon. A user choosing between five arrangements
/// needs to see the arrangement, not a glyph they have to decode.
///
/// **Width is claimed from the row, not fixed.** Doc 2 §6.3 specifies 72pt, and
/// five 72pt cards with 8pt gutters need 392pt of row — one point more than the
/// entire width of a 393pt iPhone, before the sheet's own margins. The row
/// overflowed by ~39pt and the end cards were clipped flush against both edges
/// of the sheet, which is what the layout sheet looked like on every device
/// narrower than a Pro Max. `maxWidth: .infinity` divides whatever the row
/// actually has, so the margins hold at every width.
/// There is no locked state. Split and diagonal used to carry a lock badge and
/// raise the paywall on tap; the gate now sits on the shutter in both dual
/// modes, so charging for the arrangement as well refused one recording twice —
/// and a lock on the arrangement hides the only thing the preview is there to
/// demonstrate.
struct LayoutCard: View {
    let layout: LayoutType
    let isSelected: Bool
    var action: () -> Void = {}

    /// Tall enough for the schematic plus its caption, and a comfortable target
    /// in its own right.
    static let height: CGFloat = 92

    /// The screen outline inside the card.
    ///
    /// 36×47 rather than the original 40×52, for the same reason the row's
    /// gutter shrank: `pipWide` made this a six-card row, and on the narrowest
    /// supported screen a 40pt schematic plus its 6pt side padding no longer fit
    /// the card's share of the width. The proportion — a phone, taller than it
    /// is wide — is unchanged.
    private static let schematicWidth: CGFloat = 36
    private static let schematicHeight: CGFloat = 47

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                LayoutSchematic(layout: layout, isSelected: isSelected)
                    .frame(width: Self.schematicWidth, height: Self.schematicHeight)

                Text(layout.caption)
                    .font(DC.Font.pillCaption)
                    .foregroundStyle(isSelected ? DC.Color.accent : DC.Color.chromeSecondary)
                    .lineLimit(1)
                    // "Diagonal" is the longest caption and the one that decides
                    // the floor; it shrinks rather than truncating on a narrow
                    // screen, because "Diago…" names nothing.
                    .minimumScaleFactor(0.75)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .frame(height: Self.height)
            .background {
                RoundedRectangle.dc(DC.Radius.card)
                    .fill(isSelected ? DC.Color.accent.opacity(0.15) : .clear)
            }
            .overlay {
                RoundedRectangle.dc(DC.Radius.card)
                    .strokeBorder(
                        isSelected ? DC.Color.accent : DC.Color.chromeTertiary,
                        lineWidth: isSelected ? 2 : 1
                    )
            }
            .contentShape(RoundedRectangle.dc(DC.Radius.card))
        }
        .buttonStyle(.plain)
        .dcAnimation(DC.Motion.standard, value: isSelected)
        .accessibilityLabel(layout.caption)
        .accessibilityHint("Applies this layout immediately")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The miniature diagram inside a `LayoutCard`.
private struct LayoutSchematic: View {
    let layout: LayoutType
    let isSelected: Bool

    private var stroke: Color { isSelected ? DC.Color.accent : DC.Color.chromeSecondary }
    private var fill: Color { isSelected ? DC.Color.accent : DC.Color.chromeSecondary }

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height

            ZStack(alignment: .topLeading) {
                // The secondary region is always drawn at full schematic size
                // and clipped by the screen outline, so split fills reach the
                // rounded edges instead of being masked away by their own
                // half-height bounds.
                secondaryRegion(w: w, h: h)
                    .frame(width: w, height: h)
                    .clipShape(RoundedRectangle.dc(5))

                RoundedRectangle.dc(5)
                    .strokeBorder(stroke, lineWidth: 1.5)
            }
        }
    }

    @ViewBuilder
    private func secondaryRegion(w: CGFloat, h: CGFloat) -> some View {
        switch layout {
        case .pipRounded, .pipTall, .pipWide:
            pip(RoundedRectangle.dc(2.5), size: overlaySize(in: w))

        case .pipCircle:
            pip(Circle(), size: overlaySize(in: w))

        case .splitHorizontal:
            VStack(spacing: 0) {
                Color.clear
                Rectangle().fill(fill.opacity(0.55))
            }

        case .splitDiagonal:
            DiagonalHalf().fill(fill.opacity(0.55))
        }
    }

    /// The overlay at the size and shape this layout actually installs.
    ///
    /// Both numbers come from `LayoutType` rather than being tuned per card, so
    /// the schematic cannot drift from what tapping it produces — the width is
    /// the layout's own fraction, and the height follows its real pixel
    /// proportions rather than the fraction, because the card's outline is a
    /// stylised phone rather than a true 16:9 frame.
    private func overlaySize(in width: CGFloat) -> CGSize {
        let overlayWidth = width * layout.defaultOverlaySize.width
        return CGSize(
            width: overlayWidth,
            height: overlayWidth / max(layout.overlayAspectRatio, 0.01)
        )
    }

    /// A floating overlay sits inset from the top-right corner, matching the
    /// default snap zone (Doc 2 §5.1).
    private func pip(_ shape: some Shape, size: CGSize) -> some View {
        shape
            .fill(fill.opacity(0.55))
            .frame(width: size.width, height: size.height)
            .padding(4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }
}

/// The lower half of an angled seam, used by the diagonal schematic.
private struct DiagonalHalf: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.18))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY - rect.height * 0.18))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

#Preview("Layout cards") {
    struct Harness: View {
        @State private var layout: LayoutType = .pipRounded
        var body: some View {
            HStack(spacing: 8) {
                ForEach(LayoutType.allCases) { candidate in
                    LayoutCard(layout: candidate, isSelected: candidate == layout) {
                        layout = candidate
                        HapticEngine.shared.layoutSelected()
                    }
                }
            }
            .frame(width: 353)
        }
    }
    return Harness()
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: 0x101014))
        .preferredColorScheme(.dark)
}
