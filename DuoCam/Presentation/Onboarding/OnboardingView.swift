import SwiftUI

/// The four-page carousel (Doc 2 §11).
///
/// Doc 1 §2.1's read of the competitive set is that onboarding *sells outcomes,
/// not features* — so each page leads with a benefit statement and shows the
/// result, and only the last one asks for anything.
struct OnboardingView: View {
    let onFinish: () -> Void
    let onRequestPermissions: () async -> Void

    @State private var page = 0
    @State private var isRequesting = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let pages = OnboardingPage.all

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                skipButton

                TabView(selection: $page) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, content in
                        OnboardingPageView(page: content, isActive: index == page)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                pageDots
                    .padding(.bottom, 20)

                primaryAction
                    .padding(.horizontal, DC.Spacing.edgeMargin)
                    .padding(.bottom, 24)
            }
        }
        .preferredColorScheme(.dark)
        .analyticsScreen(AnalyticsScreen.onboarding, class: "OnboardingView")
        .onAppear {
            Analytics.log(AnalyticsEvent.onboardingStarted, [
                AnalyticsParam.count: pages.count,
            ])
            logPageView(0)
        }
        // Every page is reported, not only the first and the last. The carousel
        // is swipeable as well as buttoned, so the drop-off between pages is the
        // only thing that says which promise stops holding attention — and a
        // funnel of two points cannot show it.
        .onChange(of: page) { _, index in logPageView(index) }
    }

    private func logPageView(_ index: Int) {
        guard pages.indices.contains(index) else { return }
        Analytics.log(AnalyticsEvent.onboardingPageViewed, [
            AnalyticsParam.index: index,
            AnalyticsParam.name: pages[index].analyticsName,
        ])
    }

    // MARK: Background

    /// Diagonal gradient with two soft radial glows for depth (Doc 2 §11.1).
    private var background: some View {
        ZStack {
            LinearGradient(
                colors: [DC.Color.onboardGradientStart, DC.Color.onboardGradientEnd],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [.white.opacity(0.15), .clear],
                center: .init(x: 0.15, y: 0.2),
                startRadius: 0,
                endRadius: 320
            )
            RadialGradient(
                colors: [.white.opacity(0.15), .clear],
                center: .init(x: 0.85, y: 0.75),
                startRadius: 0,
                endRadius: 380
            )
        }
        .ignoresSafeArea()
    }

    private var skipButton: some View {
        HStack {
            Spacer()
            if page < pages.count - 1 {
                Button("Skip") {
                    Analytics.log(AnalyticsEvent.onboardingSkipped, [
                        AnalyticsParam.index: page,
                        AnalyticsParam.name: pages[page].analyticsName,
                    ])
                    onFinish()
                }
                    .font(.system(size: 15))
                    .foregroundStyle(DC.Color.chromeSecondary)
                    .transition(.opacity)
            }
        }
        .frame(height: 44)
        .padding(.horizontal, DC.Spacing.edgeMargin)
        .dcAnimation(DC.Motion.fade, value: page)
    }

    private var pageDots: some View {
        HStack(spacing: 10) {
            ForEach(pages.indices, id: \.self) { index in
                Circle()
                    .fill(index == page ? DC.Color.accent : DC.Color.chromeTertiary)
                    .frame(width: 8, height: 8)
                    .scaleEffect(index == page ? 1.2 : 1)
            }
        }
        .dcAnimation(DC.Motion.standard, value: page)
        .accessibilityHidden(true)
    }

    private var primaryAction: some View {
        Button {
            advance()
        } label: {
            Group {
                if isRequesting {
                    ProgressView().tint(.white)
                } else {
                    Text(pages[page].actionTitle)
                        .font(.system(size: 17, weight: .semibold))
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: DC.Size.cta)
            .background(
                LinearGradient(
                    colors: [DC.Color.ctaGradientStart, DC.Color.ctaGradientEnd],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: Capsule()
            )
        }
        .disabled(isRequesting)
        .accessibilityLabel(pages[page].actionTitle)
    }

    private func advance() {
        Analytics.log(AnalyticsEvent.onboardingContinueTapped, [
            AnalyticsParam.index: page,
            AnalyticsParam.name: pages[page].analyticsName,
            AnalyticsParam.value: pages[page].actionTitle,
        ])

        guard page == pages.count - 1 else {
            withAnimation(DC.Motion.resolve(DC.Motion.standard, reduceMotion: reduceMotion)) {
                page += 1
            }
            return
        }

        // Doc 2 §11.2: permission is requested at the moment of stated need —
        // this button, on the last page — never at cold launch.
        isRequesting = true
        Task {
            await onRequestPermissions()
            isRequesting = false
            // After the prompts, so the completion event sits *after* the two
            // `permission_result`s in the session. Ordering is what makes the
            // sequence readable as a funnel rather than as three unrelated rows.
            Analytics.log(AnalyticsEvent.onboardingCompleted)
            Analytics.setUserProperty(true, for: AnalyticsUserProperty.onboardingCompleted)
            onFinish()
        }
    }
}

// MARK: - Page content (Doc 2 §11.2)

nonisolated struct OnboardingPage: Sendable {
    let headline: String
    let subtitle: String
    let actionTitle: String
    let mockup: MockupStyle

    /// A stable name for the analytics event, taken from the mockup rather than
    /// from the headline. Headlines are marketing copy and will be rewritten;
    /// a page identified by its copy silently becomes a *new* page in the
    /// dashboard the first time a word changes, which breaks the drop-off
    /// comparison the event exists for.
    var analyticsName: String {
        switch mockup {
        case .pipOverScene: "shoot_once_two_videos"
        case .portraitWithRail: "portrait_and_landscape"
        case .landmarkWithSelfie: "front_and_back"
        case .permissionIllustration: "permission_request"
        }
    }

    enum MockupStyle: Sendable {
        case pipOverScene
        case portraitWithRail
        case landmarkWithSelfie
        case permissionIllustration
    }

    static let all: [OnboardingPage] = [
        OnboardingPage(
            headline: "Shoot Once.\nTwo Videos.",
            subtitle: "Perfect for TikTok, YouTube, Reels, and more",
            actionTitle: "Continue",
            mockup: .pipOverScene
        ),
        OnboardingPage(
            headline: "Portrait & Landscape",
            subtitle: "No editing, no cropping. 4K recording, pro results.",
            actionTitle: "Continue",
            mockup: .portraitWithRail
        ),
        OnboardingPage(
            headline: "Front & Back Mode",
            subtitle: "Front camera on you. Back camera on the action.",
            actionTitle: "Continue",
            mockup: .landmarkWithSelfie
        ),
        OnboardingPage(
            headline: "Ready When You Are",
            subtitle: "We'll need camera and microphone access to get started.",
            actionTitle: "Enable Camera Access",
            mockup: .permissionIllustration
        ),
    ]
}

// MARK: - One page

private struct OnboardingPageView: View {
    let page: OnboardingPage
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textVisible = false

    var body: some View {
        VStack(spacing: 0) {
            OnboardingMockup(style: page.mockup, isActive: isActive)
                .frame(maxHeight: .infinity)

            VStack(spacing: 12) {
                Text(page.headline)
                    .font(DC.Font.onboardTitle)
                    .foregroundStyle(DC.Color.chromePrimary)
                    .multilineTextAlignment(.center)
                    .offset(y: textVisible ? 0 : 40)
                    .opacity(textVisible ? 1 : 0)

                Text(page.subtitle)
                    .font(DC.Font.onboardBody)
                    .foregroundStyle(DC.Color.chromeSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .offset(y: textVisible ? 0 : 40)
                    .opacity(textVisible ? 1 : 0)
                    // Doc 2 §11.3: staggered 80ms behind the headline.
                    .animation(
                        reduceMotion ? DC.Motion.reduced : DC.Motion.standard.delay(0.08),
                        value: textVisible
                    )
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
            .animation(reduceMotion ? DC.Motion.reduced : DC.Motion.standard, value: textVisible)
        }
        .onChange(of: isActive, initial: true) { _, active in
            textVisible = active
        }
    }
}
