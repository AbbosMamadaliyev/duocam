import Foundation
import os
import StoreKit

/// The products DuoCam sells (Doc 1 §4.5, Doc 3 Phase 7 task 1).
nonisolated enum ProductID: String, CaseIterable, Sendable {
    case monthly = "com.altzet.DuoCam.pro.monthly"
    case annual = "com.altzet.DuoCam.pro.annual"
    case lifetime = "com.altzet.DuoCam.pro.lifetime"

    var displayName: String {
        switch self {
        case .monthly: "Monthly"
        case .annual: "Annual"
        case .lifetime: "Lifetime"
        }
    }

    /// Doc 2 §12.3: annual is pre-selected and carries the savings badge.
    var isRecommended: Bool { self == .annual }
    var badge: String? { self == .annual ? "SAVE 40%" : nil }
}

/// Owns StoreKit and nothing else (Doc 3 Phase 7 task 2).
@MainActor
@Observable
final class SubscriptionManager {
    private(set) var products: [Product] = []
    private(set) var isPro = false
    private(set) var isLoading = false
    private(set) var purchaseError: String?

    private var updatesTask: Task<Void, Never>?

    init() {
        // The listener must start before any purchase can complete, including
        // ones finished outside the app (Ask to Buy, App Store redemption).
        // Starting it lazily is how those transactions get missed.
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.handle(update)
            }
        }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            products = try await Product.products(for: ProductID.allCases.map(\.rawValue))
                .sorted { lhs, rhs in
                    order(of: lhs) < order(of: rhs)
                }
            await refreshEntitlements()
        } catch {
            Log.ui.error("Product load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func order(of product: Product) -> Int {
        switch ProductID(rawValue: product.id) {
        case .annual: 0
        case .monthly: 1
        case .lifetime: 2
        case nil: 3
        }
    }

    // MARK: Purchase

    func purchase(_ product: Product) async {
        purchaseError = nil
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                await handle(verification)
            case .userCancelled:
                break
            case .pending:
                // Ask to Buy. The updates listener will deliver it later.
                purchaseError = "Waiting for approval"
            @unknown default:
                break
            }
        } catch {
            purchaseError = error.localizedDescription
            Log.ui.error("Purchase failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func restore() async {
        do {
            try await AppStore.sync()
            await refreshEntitlements()
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    private func handle(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else {
            Log.ui.error("Unverified transaction ignored")
            return
        }
        await transaction.finish()
        await refreshEntitlements()
    }

    /// The single source of truth for entitlement.
    ///
    /// Read from `Transaction.currentEntitlements` rather than remembered in
    /// `UserDefaults`: Doc 3 Phase 7's criteria include expiry correctly
    /// re-locking Pro, and a cached flag cannot expire.
    func refreshEntitlements() async {
        var entitled = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            guard ProductID(rawValue: transaction.productID) != nil else { continue }
            if transaction.revocationDate == nil {
                entitled = true
            }
        }
        isPro = entitled
        Log.ui.info("Entitlement → \(entitled ? "Pro" : "Free")")
    }
}

/// The one place the rest of the app asks "may they?".
///
/// Doc 3 Phase 7 task 3 is explicit: *"never scatter entitlement checks through
/// view code"*. Scattered checks are how a gate gets added to four of five
/// call sites and the fifth ships unlocked.
@MainActor
@Observable
final class EntitlementGate {
    /// Everything behind the Pro tier (Doc 1 §4.5).
    nonisolated enum Feature: String, CaseIterable, Sendable {
        case resolution4K
        case frameRate60
        case splitLayouts
        case cleanSourceFiles
        case manualControls
        case watermarkRemoval

        var displayName: String {
            switch self {
            case .resolution4K: "4K recording"
            case .frameRate60: "60 fps"
            case .splitLayouts: "Split and diagonal layouts"
            case .cleanSourceFiles: "Clean source files"
            case .manualControls: "Manual controls"
            case .watermarkRemoval: "No watermark"
            }
        }
    }

    private let subscriptions: SubscriptionManager

    /// Set when a gated feature was tapped, so the paywall can open in context
    /// (Doc 3 Phase 7 task 6: contextual, never on cold launch).
    var pendingFeature: Feature?
    var isShowingPaywall = false

    init(subscriptions: SubscriptionManager) {
        self.subscriptions = subscriptions
    }

    var isPro: Bool { subscriptions.isPro }

    func isUnlocked(_ feature: Feature) -> Bool { subscriptions.isPro }

    /// Returns `true` when the caller may proceed; otherwise raises the paywall
    /// and returns `false`.
    @discardableResult
    func require(_ feature: Feature) -> Bool {
        if isUnlocked(feature) { return true }
        pendingFeature = feature
        isShowingPaywall = true
        return false
    }

    /// Free-tier exports carry a watermark (Doc 1 §4.5).
    var exportsWatermark: Bool { !subscriptions.isPro }

    func isUnlocked(resolution: Resolution) -> Bool {
        resolution == .uhd4K ? isUnlocked(.resolution4K) : true
    }

    func isUnlocked(frameRate: FrameRate) -> Bool {
        frameRate == .fps60 ? isUnlocked(.frameRate60) : true
    }

    func isUnlocked(layout: LayoutType) -> Bool {
        layout.isSplit ? isUnlocked(.splitLayouts) : true
    }
}
