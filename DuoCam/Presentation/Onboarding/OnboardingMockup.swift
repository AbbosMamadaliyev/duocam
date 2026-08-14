import SwiftUI

/// The device mockup and floating platform badges (Doc 2 §11.1).
///
/// Doc 2 asks for "a real captured result" in each mockup. Shipping stock
/// footage in the bundle would be the obvious route and the wrong one — the
/// screens would show something the app did not produce. These are schematic
/// instead: honest about being a diagram, and they show the actual *geometry*
/// the app creates, which is the part that has to be understood in the four
/// seconds a user spends on each page.
struct OnboardingMockup: View {
    let style: OnboardingPage.MockupStyle
    let isActive: Bool

    var body: some View {
        ZStack {
            switch style {
            case .pipOverScene:
                phone { PiPMockContent() }
                badges([.tiktok, .youtube, .instagram])
            case .portraitWithRail:
                phone { PortraitRailMockContent() }
                badges([.instagram, .tiktok])
            case .landmarkWithSelfie:
                phone { LandmarkMockContent() }
                badges([.youtube, .instagram])
            case .permissionIllustration:
                permissionIllustration
            }
        }
        .padding(.horizontal, 40)
    }

    // MARK: Phone frame

    private func phone(@ViewBuilder content: () -> some View) -> some View {
        content()
            .aspectRatio(9 / 19.5, contentMode: .fit)
            .clipShape(RoundedRectangle.dc(34))
            .overlay {
                RoundedRectangle.dc(34)
                    .strokeBorder(.white.opacity(0.9), lineWidth: 5)
            }
            .overlay(alignment: .top) {
                // Dynamic Island stand-in — without it the frame reads as a
                // generic rectangle rather than a phone.
                Capsule()
                    .fill(.black)
                    .frame(width: 74, height: 22)
                    .padding(.top, 12)
            }
            .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
            .frame(maxHeight: 420)
    }

    // MARK: Badges

    private func badges(_ platforms: [PlatformBadge.Platform]) -> some View {
        GeometryReader { proxy in
            ForEach(Array(platforms.enumerated()), id: \.offset) { index, platform in
                PlatformBadge(platform: platform, phase: Double(index) * 1.1, isActive: isActive)
                    .position(
                        x: proxy.size.width * badgePositions[index].x,
                        y: proxy.size.height * badgePositions[index].y
                    )
            }
        }
    }

    /// Asymmetric on purpose (Doc 2 §11.1) — an even ring of badges reads as a
    /// diagram, a scattered one reads as depth.
    private let badgePositions: [CGPoint] = [
        CGPoint(x: 0.04, y: 0.24),
        CGPoint(x: 0.95, y: 0.42),
        CGPoint(x: 0.10, y: 0.74),
    ]

    // MARK: Permission page

    private var permissionIllustration: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .fill(.white.opacity(0.12))
                    .frame(width: 168, height: 168)
                Image(systemName: "camera.aperture")
                    .font(.system(size: 76, weight: .thin))
                    .foregroundStyle(.white)
            }

            HStack(spacing: 30) {
                permissionChip("Camera", "camera.fill")
                permissionChip("Microphone", "mic.fill")
            }
        }
    }

    private func permissionChip(_ title: String, _ symbol: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
            Text(title)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.85))
        .frame(width: 92, height: 74)
        .background(.white.opacity(0.1), in: RoundedRectangle.dc(16))
    }
}

// MARK: - Mock screen contents

private struct PiPMockContent: View {
    var body: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(
                colors: [Color(hex: 0x2E6FB0), Color(hex: 0x0C2340)],
                startPoint: .top, endPoint: .bottom
            )
            SubjectSilhouette(scale: 0.55)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

            LinearGradient(
                colors: [Color(hex: 0xF08E6C), Color(hex: 0x70285F)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(width: 74, height: 98)
            .overlay { SubjectSilhouette(scale: 0.8) }
            .clipShape(RoundedRectangle.dc(12))
            .overlay { RoundedRectangle.dc(12).strokeBorder(.white, lineWidth: 2) }
            // Clears the Dynamic Island stand-in. The real app's snap-zone
            // resolution does the same thing for the same reason (Doc 2 §5.4),
            // so a mockup that shows the overlay tucked under the island would
            // be advertising the bug the app was built to avoid.
            .padding(.top, 44)
            .padding(.trailing, 12)
        }
    }
}

private struct PortraitRailMockContent: View {
    var body: some View {
        ZStack(alignment: .trailing) {
            LinearGradient(
                colors: [Color(hex: 0x1F7A6B), Color(hex: 0x08251F)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            SubjectSilhouette(scale: 0.62)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

            // The social action rail Doc 2 §11.2 describes for this page.
            VStack(spacing: 16) {
                ForEach(["heart.fill", "bubble.right.fill", "arrowshape.turn.up.right.fill"], id: \.self) {
                    Image(systemName: $0)
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
            .padding(.trailing, 12)
        }
    }
}

private struct LandmarkMockContent: View {
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [Color(hex: 0x7BA7D4), Color(hex: 0xE8C39E)],
                startPoint: .top, endPoint: .bottom
            )

            // A landmark stand-in, so the page reads as "the scene" rather than
            // as an abstract gradient.
            Triangle()
                .fill(Color(hex: 0x6B4B33).opacity(0.85))
                .frame(width: 120, height: 130)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

            LinearGradient(
                colors: [Color(hex: 0xF08E6C), Color(hex: 0x70285F)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(width: 70, height: 70)
            .overlay { SubjectSilhouette(scale: 0.85) }
            .clipShape(Circle())
            .overlay { Circle().strokeBorder(.white, lineWidth: 2) }
            .padding(12)
        }
    }
}

/// A head-and-shoulders shape. Recognisable as a person at thumbnail size,
/// which a photograph scaled to 70pt would not be.
private struct SubjectSilhouette: View {
    var scale: CGFloat = 1

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height) * scale
            VStack(spacing: -side * 0.08) {
                Circle()
                    .fill(.white.opacity(0.75))
                    .frame(width: side * 0.42, height: side * 0.42)
                RoundedRectangle.dc(side * 0.3)
                    .fill(.white.opacity(0.75))
                    .frame(width: side * 0.78, height: side * 0.55)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Platform badges

/// A floating platform mark with an independent slow float (Doc 2 §11.1:
/// ±6pt vertical, 3–4s period, offset phases).
struct PlatformBadge: View {
    enum Platform: Sendable {
        case tiktok, youtube, instagram

        var symbol: String {
            switch self {
            case .tiktok: "music.note"
            case .youtube: "play.rectangle.fill"
            case .instagram: "camera.fill"
            }
        }

        var colors: [Color] {
            switch self {
            case .tiktok: [Color(hex: 0x25F4EE), Color(hex: 0xFE2C55)]
            case .youtube: [Color(hex: 0xFF4E45), Color(hex: 0xC4302B)]
            case .instagram: [Color(hex: 0xF9CE34), Color(hex: 0xEE2A7B), Color(hex: 0x6228D7)]
            }
        }
    }

    let platform: Platform
    let phase: Double
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var floatUp = false

    var body: some View {
        Image(systemName: platform.symbol)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 56, height: 56)
            .background(
                LinearGradient(colors: platform.colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle.dc(16)
            )
            .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
            .offset(y: floatUp ? -6 : 6)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(
                    .easeInOut(duration: 3.2 + phase * 0.3)
                    .repeatForever(autoreverses: true)
                    .delay(phase)
                ) {
                    floatUp = true
                }
            }
            .accessibilityHidden(true)
    }
}
