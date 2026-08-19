import SwiftUI

/// The Pro upgrade sheet (Doc 2 §12.3).
///
/// Doc 2 is explicit about what this must *not* do: *"Dismissible without
/// friction — no dark patterns, no fake countdowns."* So there is no timer, no
/// pre-checked upsell, and the close control is the first thing in the view
/// hierarchy rather than a 12pt grey cross that appears after four seconds.
///
/// The layout is the standard iOS purchase sheet, in the order the eye needs it:
/// what this is → what it gets you → what it costs → one button. Everything
/// legally required — renewal terms, Terms of Use, Privacy Policy, Restore —
/// sits under the button as real, tappable text rather than being buried.
struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SubscriptionManager.self) private var subscriptions

    /// The feature that triggered this, so the headline can be about *their*
    /// intent rather than about the subscription. `nil` on the periodic
    /// every-fourth-launch reminder, which has no context to speak of.
    let context: EntitlementGate.Feature?

    /// Monthly, per Doc 2 §12.3's rule that the recommended plan is the one
    /// already chosen — never the most expensive, and never nothing at all,
    /// which turns the primary button into a second decision.
    @State private var selection: ProductID = .monthly

    var body: some View {
        ZStack {
            backdrop

            // `minHeight` from the container, with a flexible gap in the middle.
            //
            // A plain `ScrollView` sizes itself to its content, so on a large
            // phone the plan strip finished a third of the way up and left a
            // band of empty black between them and the button that buys them —
            // which reads as a section that failed to load. Giving the stack the
            // container's height as a *floor* lets the `Spacer` push the prices
            // down to meet the footer, while anything that outgrows the screen
            // still scrolls normally.
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 26) {
                        hero
                        benefits
                        Spacer(minLength: 24)
                        planPicker
                    }
                    .padding(.horizontal, DC.Spacing.edgeMargin)
                    .padding(.top, 36)
                    .padding(.bottom, 18)
                    .frame(minHeight: proxy.size.height, alignment: .top)
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
            }
            .safeAreaInset(edge: .bottom) { purchaseFooter }
            .overlay(alignment: .topTrailing) { closeButton }
        }
        .preferredColorScheme(.dark)
        // Uncapped Dynamic Type turns a three-row plan picker into three screens
        // of scrolling; capped at the largest step the layout still holds, which
        // is well past the default and short of the accessibility sizes.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .analyticsScreen(AnalyticsScreen.paywall, class: "PaywallView")
        .task { await subscriptions.load() }
        .onChange(of: subscriptions.isPro) { _, isPro in
            if isPro { dismiss() }
        }
        // On disappear rather than on the close button: the sheet is also
        // dismissible by dragging it down, and a "dismissed" count that misses
        // every swipe would make the close button look like the only way out.
        // `didPurchase` separates leaving because it worked from walking away.
        .onDisappear {
            Analytics.log(AnalyticsEvent.paywallDismissed, [
                AnalyticsParam.feature: context?.rawValue ?? "none",
                AnalyticsParam.plan: selection.rawValue,
                AnalyticsParam.result: subscriptions.isPro ? "purchased" : "abandoned",
            ])
        }
    }

    // MARK: Chrome

    /// A single warm pool of light behind the header and flat black below it.
    /// The gradient is doing one job — pulling the eye to the top of the sheet —
    /// so it stops well above the plan rows rather than tinting them.
    private var backdrop: some View {
        ZStack {
            Color(hex: 0x0B0B0F)

            RadialGradient(
                colors: [DC.Color.ctaGradientStart.opacity(0.35), .clear],
                center: .init(x: 0.5, y: 0.02),
                startRadius: 0,
                endRadius: 420
            )
        }
        .ignoresSafeArea()
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(DC.Color.chromeSecondary)
                .frame(width: 30, height: 30)
                .background(.white.opacity(0.10), in: Circle())
        }
        .buttonStyle(.plain)
        // A 30pt disc inside a 44pt target: visually restrained, still legal to
        // tap on the first try.
        .frame(width: DC.Size.control, height: DC.Size.control)
        .padding(.trailing, DC.Spacing.grid)
        .padding(.top, DC.Spacing.grid)
        .accessibilityLabel("Close")
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(DC.Color.accent)
                .accessibilityHidden(true)

            Text("DuoRec Pro")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(DC.Color.chromePrimary)

            Text(context?.contextLine ?? "Both cameras, every capture, at full quality.")
                .font(.system(size: 15))
                .foregroundStyle(DC.Color.chromeSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Benefits

    /// What the money buys, in the order it matters. Five rows: enough to make
    /// the case, few enough to read without scrolling past the price.
    private static let proBenefits: [(symbol: String, title: String)] = [
        ("camera.on.rectangle.fill", "Unlimited Front + Back and Rear + Rear capture"),
        ("4k.tv", "4K recording at 60 fps"),
        ("film.stack", "Clean source files for every take"),
        ("slider.horizontal.3", "Full control of the floating preview"),
        ("sparkles", "Exports with no watermark"),
    ]

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Self.proBenefits, id: \.title) { benefit in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Image(systemName: benefit.symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DC.Color.accent)
                        .frame(width: 22, alignment: .center)
                        .accessibilityHidden(true)

                    Text(benefit.title)
                        .font(.system(size: 15))
                        .foregroundStyle(DC.Color.chromePrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Plans

    /// All three plans are always drawn, from `ProductID` rather than from
    /// whatever the store returned.
    ///
    /// An empty offer list used to replace this whole section with a spinner
    /// or an error box, which is the one state where the user can see neither
    /// what is on offer nor what it costs. The prices shown are RevenueCat's
    /// localised price whenever there is one; when there is not — including
    /// every build made before the dashboard exists — the card falls back to
    /// the listed price and the button is disabled. Nothing is claimed that
    /// cannot be charged.
    ///
    /// Side by side rather than stacked: three tiles put every price in the
    /// same glance, so the choice is a comparison rather than three separate
    /// readings. `maxHeight: .infinity` inside the `HStack` is what keeps the
    /// tiles the same height when only one of them carries a trial line.
    private var planPicker: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(ProductID.allCases, id: \.self) { plan in
                PlanCard(
                    plan: plan,
                    price: displayPrice(for: plan),
                    introductory: subscriptions.offer(for: plan)?.introductory?.caption,
                    isSelected: plan == selection
                ) {
                    guard plan != selection else { return }
                    Analytics.log(AnalyticsEvent.paywallPlanSelected, [
                        AnalyticsParam.plan: plan.rawValue,
                        AnalyticsParam.previousPlan: selection.rawValue,
                        AnalyticsParam.feature: context?.rawValue ?? "none",
                    ])
                    selection = plan
                    HapticEngine.shared.sliderDetent()
                }
            }
        }
        // The tiles ask for an unbounded height so they can match each other;
        // without this the surrounding flexible layout takes that literally and
        // hands them every spare point on the screen, stretching three ~100pt
        // tiles into half-page columns. `fixedSize` proposes their ideal height
        // instead, which the `maxHeight` inside then equalises against.
        .fixedSize(horizontal: false, vertical: true)
        // Room for the recommended card's marker, which sits astride its top
        // edge and would otherwise be clipped by the section above.
        .padding(.top, 10)
    }

    // MARK: Footer

    private var purchaseFooter: some View {
        VStack(spacing: 10) {
            // Only a *failed* purchase speaks here. The standing "this plan
            // couldn't be confirmed" notice used to sit above the button in
            // every build without live store data, where it was permanent
            // furniture rather than news; the dimmed button already says the
            // same thing without shouting it.
            if let error = subscriptions.purchaseError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(DC.Color.record)
                    .multilineTextAlignment(.center)
            }

            continueButton

            Text(renewalDisclosure)
                .font(.system(size: 11))
                .foregroundStyle(DC.Color.chromeTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            legalRow
        }
        .padding(.horizontal, DC.Spacing.edgeMargin)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }

    /// Asked of the *selected* plan rather than of the offer list as a whole.
    /// A partial load — two of three packages matched — would otherwise leave
    /// the button live over a plan there is nothing to charge against, and
    /// tapping it would silently do nothing.
    private var isSelectionPurchasable: Bool {
        subscriptions.isPurchasable(selection)
    }

    private var continueButton: some View {
        Button {
            guard let offer = subscriptions.offer(for: selection) else { return }
            // Logged here rather than only inside `purchase`, because this is
            // the last point that still knows *why* the sheet was open. The
            // store outcome events that follow carry the plan but not the
            // context, and the pair is what makes "which gate sells what"
            // answerable.
            Analytics.log(AnalyticsEvent.paywallPurchaseTapped, [
                AnalyticsParam.plan: selection.rawValue,
                AnalyticsParam.productId: offer.productIdentifier,
                AnalyticsParam.feature: context?.rawValue ?? "none",
                AnalyticsParam.price: NSDecimalNumber(decimal: offer.price).doubleValue,
                AnalyticsParam.currency: offer.currencyCode ?? "",
                AnalyticsParam.offering: subscriptions.offeringIdentifier ?? "none",
            ])
            Task { await subscriptions.purchase(selection) }
        } label: {
            ZStack {
                if subscriptions.isPurchasing {
                    ProgressView().tint(.white)
                } else {
                    Text(continueTitle)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: DC.Size.cta)
            .background(
                LinearGradient(
                    colors: [DC.Color.ctaGradientStart, DC.Color.ctaGradientEnd],
                    startPoint: .leading, endPoint: .trailing
                ),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .disabled(!isSelectionPurchasable || subscriptions.isPurchasing)
        .opacity(isSelectionPurchasable ? 1 : 0.5)
        .accessibilityLabel(continueTitle)
        .accessibilityValue("\(selection.displayName), \(displayPrice(for: selection))")
    }

    private func displayPrice(for plan: ProductID) -> String {
        subscriptions.offer(for: plan)?.displayPrice ?? plan.fallbackPrice
    }

    /// One label for every plan, by request: the button names the transaction
    /// rather than the tier. What is actually being charged — a trial's length
    /// and the price after it, or the fact that the lifetime tier does not
    /// renew — is stated verbatim in `renewalDisclosure` directly beneath.
    private var continueTitle: String { "Subscribe" }

    /// Auto-renewable subscriptions must say this, and the lifetime tier must
    /// not — App Review reads it, and so does the one user in fifty who checks.
    ///
    /// When there is a trial, what happens *after* it is the part that has to be
    /// stated: the length, then the price, then the renewal. Leaving the price
    /// out of a trial disclosure is the single most common paywall rejection.
    private var renewalDisclosure: String {
        guard selection != .lifetime else {
            return "One payment. No subscription, nothing to cancel."
        }
        let renewal = "Renews automatically until cancelled. Cancel any time in Settings."
        guard let introductory = subscriptions.offer(for: selection)?.introductory else {
            return renewal
        }
        return "\(introductory.caption), then \(displayPrice(for: selection)) "
            + "\(selection.periodCaption). \(renewal)"
    }

    /// The three small text buttons Doc 2 §12.3 requires, on one line.
    ///
    /// Restore sits with the two legal links rather than up in the content:
    /// someone who has already paid arrives looking for exactly this row, and
    /// putting it where the fine print lives is where every other iOS app puts
    /// it.
    private var legalRow: some View {
        HStack(spacing: 6) {
            // `Link` opens Safari itself and offers no action closure, so the
            // tap is observed alongside it rather than in place of it. A
            // *simultaneous* gesture on purpose: anything that consumed the tap
            // would trade a working legal link for an event, which is the one
            // trade App Review would notice.
            Link("Terms of Use", destination: Self.termsOfUseURL)
                .accessibilityAddTraits(.isButton)
                .simultaneousGesture(TapGesture().onEnded {
                    logLegalTap(AnalyticsValue.legalTerms)
                })

            separator

            Link("Privacy Policy", destination: Self.privacyPolicyURL)
                .accessibilityAddTraits(.isButton)
                .simultaneousGesture(TapGesture().onEnded {
                    logLegalTap(AnalyticsValue.legalPrivacy)
                })

            separator

            Button("Restore") {
                Task { await subscriptions.restore(source: AnalyticsValue.sourcePaywall) }
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 12))
        .foregroundStyle(DC.Color.chromeSecondary)
        // 12pt text is a 16pt-tall target on its own; the extra height brings
        // the row up to something a thumb can hit without magnifying the type.
        .frame(height: 34)
    }

    private func logLegalTap(_ link: String) {
        Analytics.log(AnalyticsEvent.paywallLegalLinkTapped, [
            AnalyticsParam.name: link,
            AnalyticsParam.plan: selection.rawValue,
        ])
    }

    private var separator: some View {
        Text("·")
            .foregroundStyle(DC.Color.chromeTertiary)
            .accessibilityHidden(true)
    }

    /// Apple's standard EULA, which is what governs these purchases unless the
    /// app ships its own — and shipping our own would mean maintaining it.
    private static let termsOfUseURL = URL(
        string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/"
    )!

    /// The one link here that has to be ours, since a privacy policy describes
    /// what *this* app does with a recording.
    private static let privacyPolicyURL = URL(
        string: "https://altzet.com/duocam/privacy"
    )!
}

// MARK: - Plan card

/// One selectable plan, as a tile in the three-across strip.
///
/// A third of the content width is around 110pt, which is narrower than any
/// price plus its period read side by side — so the tile stacks them instead,
/// centred, with the name above and the trial line below. The price is the one
/// line allowed to shrink rather than wrap: a long localised amount is still a
/// single number, and breaking it across two lines would make it read as two.
private struct PlanCard: View {
    let plan: ProductID
    let price: String
    /// The trial or intro line, when this user is eligible for one. Beneath the
    /// period rather than beside the price: it qualifies *what you get*, and
    /// next to the number it would read as the number being charged.
    let introductory: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text(plan.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DC.Color.chromePrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text(price)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(isSelected ? DC.Color.accent : DC.Color.chromePrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .padding(.top, 2)

                Text(plan.periodCaption)
                    .font(.system(size: 11))
                    .foregroundStyle(DC.Color.chromeSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                if let introductory {
                    Text(introductory)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(DC.Color.accent)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 3)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 16)
            // Width shared equally by the `HStack`; the height is whatever the
            // tallest of the three needs, so a trial line on one plan does not
            // leave the other two short.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RoundedRectangle.dc(16)
                    .fill(isSelected ? DC.Color.accent.opacity(0.10) : .white.opacity(0.05))
            }
            .overlay {
                RoundedRectangle.dc(16)
                    .strokeBorder(
                        isSelected ? DC.Color.accent : DC.Color.hairline,
                        lineWidth: isSelected ? 2 : 1
                    )
            }
            .overlay(alignment: .top) {
                if let badge = plan.badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.4)
                        .foregroundStyle(.black)
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(DC.Color.accent, in: Capsule())
                        // Astride the top border rather than inside the tile: it
                        // is a label *on* the plan, and inside it would be
                        // competing with the price for the same narrow column.
                        .offset(y: -9)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(RoundedRectangle.dc(16))
        }
        .buttonStyle(.plain)
        .dcAnimation(DC.Motion.standard, value: isSelected)
        .accessibilityLabel(plan.displayName)
        .accessibilityValue(
            "\(price) \(plan.periodCaption)"
                + (introductory.map { ", \($0)" } ?? "")
                + (plan.badge.map { ", \($0.lowercased())" } ?? "")
        )
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

#Preview("Paywall") {
    PaywallView(context: .dualFrontBackCapture)
        .environment(SubscriptionManager())
}
