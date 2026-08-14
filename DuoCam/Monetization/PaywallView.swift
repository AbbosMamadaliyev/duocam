import StoreKit
import SwiftUI

/// The Pro upgrade sheet (Doc 2 §12.3).
///
/// Doc 2 is explicit about what this must *not* do: *"Dismissible without
/// friction — no dark patterns, no fake countdowns."* So there is no timer, no
/// pre-checked upsell, and the close control is the first thing in the view
/// hierarchy rather than a 12pt grey cross that appears after four seconds.
struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SubscriptionManager.self) private var subscriptions

    /// The feature that triggered this, so the headline can be about *their*
    /// intent rather than about the subscription.
    let context: EntitlementGate.Feature?

    @State private var selection: ProductID = .annual

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    featureList
                    planCards
                    legal
                }
                .padding(.horizontal, DC.Spacing.edgeMargin)
                .padding(.vertical, 24)
            }
            .safeAreaInset(edge: .bottom) { callToAction }
            .background(Color(hex: 0x101014).ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(DC.Color.chromeSecondary)
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await subscriptions.load() }
        .onChange(of: subscriptions.isPro) { _, isPro in
            if isPro { dismiss() }
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 46, weight: .thin))
                .foregroundStyle(DC.Color.accent)

            Text("Unlock DuoCam Pro")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(DC.Color.chromePrimary)

            if let context {
                Text("\(context.displayName) is a Pro feature.")
                    .font(DC.Font.sheetBody)
                    .foregroundStyle(DC.Color.chromeSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, 8)
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(EntitlementGate.Feature.allCases, id: \.self) { feature in
                HStack(spacing: 11) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(DC.Color.accent)
                    Text(feature.displayName)
                        .font(DC.Font.sheetBody)
                        .foregroundStyle(DC.Color.chromePrimary)
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var planCards: some View {
        if subscriptions.products.isEmpty {
            // Sandbox and offline both land here. Saying so beats an empty box
            // the user cannot act on.
            VStack(spacing: 10) {
                if subscriptions.isLoading {
                    ProgressView().tint(DC.Color.accent)
                    Text("Loading plans…")
                        .font(DC.Font.sheetBody)
                        .foregroundStyle(DC.Color.chromeSecondary)
                } else {
                    // A spinner here would suggest something is still coming.
                    // Nothing is: either StoreKit has no products configured, or
                    // the device is offline. Saying so is the honest state.
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(DC.Color.chromeTertiary)
                    Text("Plans are unavailable right now.")
                        .font(DC.Font.sheetBody)
                        .foregroundStyle(DC.Color.chromeSecondary)
                    Button("Try again") {
                        Task { await subscriptions.load() }
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(DC.Color.accent)
                }
            }
            .frame(height: 130)
        } else {
            VStack(spacing: 10) {
                ForEach(subscriptions.products, id: \.id) { product in
                    PlanCard(
                        product: product,
                        isSelected: ProductID(rawValue: product.id) == selection
                    ) {
                        if let id = ProductID(rawValue: product.id) {
                            selection = id
                            HapticEngine.shared.sliderDetent()
                        }
                    }
                }
            }
        }
    }

    private var callToAction: some View {
        VStack(spacing: 10) {
            if let error = subscriptions.purchaseError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(DC.Color.record)
            }

            Button {
                guard let product = subscriptions.products
                    .first(where: { $0.id == selection.rawValue })
                else { return }
                Task { await subscriptions.purchase(product) }
            } label: {
                Text("Continue")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
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
            .disabled(subscriptions.products.isEmpty)
            .opacity(subscriptions.products.isEmpty ? 0.5 : 1)
        }
        .padding(.horizontal, DC.Spacing.edgeMargin)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
    }

    private var legal: some View {
        VStack(spacing: 8) {
            Button("Restore Purchases") {
                Task { await subscriptions.restore() }
            }
            .font(.system(size: 12))
            .foregroundStyle(DC.Color.chromeSecondary)

            Text("Subscriptions renew automatically until cancelled. Manage them in Settings.")
                .font(.system(size: 11))
                .foregroundStyle(DC.Color.chromeTertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 4)
    }
}

// MARK: - Plan card

private struct PlanCard: View {
    let product: Product
    let isSelected: Bool
    let action: () -> Void

    private var id: ProductID? { ProductID(rawValue: product.id) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? DC.Color.accent : DC.Color.chromeTertiary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(id?.displayName ?? product.displayName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(DC.Color.chromePrimary)
                    Text(product.displayPrice)
                        .font(DC.Font.sheetBody)
                        .foregroundStyle(DC.Color.chromeSecondary)
                }

                Spacer()

                if let badge = id?.badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(DC.Color.accent, in: Capsule())
                }
            }
            .padding(14)
            .background {
                RoundedRectangle.dc(14)
                    .fill(isSelected ? DC.Color.accent.opacity(0.1) : .white.opacity(0.04))
            }
            .overlay {
                RoundedRectangle.dc(14)
                    .strokeBorder(
                        isSelected ? DC.Color.accent : DC.Color.chromeTertiary.opacity(0.5),
                        lineWidth: isSelected ? 2 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .dcAnimation(DC.Motion.standard, value: isSelected)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
