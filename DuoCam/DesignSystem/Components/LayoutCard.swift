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
struct LayoutCard: View {
    let layout: LayoutType
    let isSelected: Bool
    /// Marks a layout the current entitlement does not cover. The card stays
    /// tappable — tapping is what raises the paywall — it just stops looking
    /// identical to the three that are already paid for.
    var isLocked: Bool = false
    var action: () -> Void = {}

    /// Tall enough for the schematic plus its caption, and a comfortable target
    /// in its own right.
    static let height: CGFloat = 92

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                LayoutSchematic(layout: layout, isSelected: isSelected)
                    .frame(width: 40, height: 52)
                    .overlay(alignment: .topLeading) {
                        if isLocked {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.black)
                                .frame(width: 16, height: 16)
                                .background(DC.Color.accent, in: Circle())
                                .offset(x: -6, y: -6)
                        }
                    }

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
        .accessibilityValue(isLocked ? "Pro" : "")
        .accessibilityHint(isLocked
            ? "Requires DuoCam Pro. Opens the upgrade screen"
            : "Applies this layout immediately")
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
        case .pipRounded:
            pip(RoundedRectangle.dc(2.5), size: CGSize(width: w * 0.34, height: w * 0.34 / 0.75))

        case .pipTall:
            pip(RoundedRectangle.dc(2.5), size: CGSize(width: w * 0.28, height: w * 0.28 / 0.5625))

        case .pipCircle:
            pip(Circle(), size: CGSize(width: w * 0.34, height: w * 0.34))

        case .splitHorizontal:
            VStack(spacing: 0) {
                Color.clear
                Rectangle().fill(fill.opacity(0.55))
            }

        case .splitDiagonal:
            DiagonalHalf().fill(fill.opacity(0.55))
        }
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
