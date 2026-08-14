import SwiftUI

/// One 72×88pt card in the Layout sheet (Doc 2 §6.3).
///
/// The card shows a *schematic* of the layout — a rounded rectangle standing in
/// for the screen with a smaller filled shape showing where the secondary
/// stream sits — rather than an icon. A user choosing between five arrangements
/// needs to see the arrangement, not a glyph they have to decode.
struct LayoutCard: View {
    let layout: LayoutType
    let isSelected: Bool
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                LayoutSchematic(layout: layout, isSelected: isSelected)
                    .frame(width: 44, height: 56)

                Text(layout.caption)
                    .font(DC.Font.pillCaption)
                    .foregroundStyle(isSelected ? DC.Color.accent : DC.Color.chromeSecondary)
            }
            .frame(width: 72, height: 88)
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
            HStack(spacing: 10) {
                ForEach(LayoutType.allCases) { candidate in
                    LayoutCard(layout: candidate, isSelected: candidate == layout) {
                        layout = candidate
                        HapticEngine.shared.layoutSelected()
                    }
                }
            }
        }
    }
    return Harness()
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: 0x101014))
        .preferredColorScheme(.dark)
}
