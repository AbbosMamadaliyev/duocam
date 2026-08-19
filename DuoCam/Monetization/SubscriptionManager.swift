import Foundation
import os
import RevenueCat

/// The products DuoCam sells (Doc 1 §4.5, Doc 3 Phase 7 task 1).
///
/// Three tiers and no more: a cheap way in, the one most people should take, and
/// a way to stop paying rent. The annual tier is gone — with a weekly at the
/// bottom, a fourth row turns the plan picker into a comparison exercise, and
/// the monthly is the row the pricing is built around.
///
/// The raw values are still the App Store product identifiers, but they are now
/// only *one* of the ways a plan is matched to what RevenueCat returns — see
/// `SubscriptionManager.package(for:in:)`. A dashboard is free to rename its
/// products, and the app should not need a release when it does.
nonisolated enum ProductID: String, CaseIterable, Sendable {
    case weekly = "com.altzet.DuoCam.weekly"
    case monthly = "com.altzet.DuoCam.monthly"
    case lifetime = "com.altzet.DuoCam.lifetime"

    /// RevenueCat's own name for this kind of package. The dashboard's
    /// predefined identifiers (`$rc_weekly` and friends) map onto these, which
    /// is what lets a plan be found without knowing any product identifier.
    var packageType: PackageType {
        switch self {
        case .weekly: .weekly
        case .monthly: .monthly
        case .lifetime: .lifetime
        }
    }

    var displayName: String {
        switch self {
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        case .lifetime: "Lifetime"
        }
    }

    /// What the row says under its title when the store has not been reached —
    /// which is every run until the RevenueCat dashboard is filled in.
    ///
    /// Only ever a fallback: a live offer always wins, because the price the App
    /// Store quotes through RevenueCat is the one that will actually be charged,
    /// in the user's own currency.
    var fallbackPrice: String {
        switch self {
        case .weekly: "$3.99"
        case .monthly: "$12.99"
        case .lifetime: "$29.99"
        }
    }

    /// The billing period, spelled out rather than inferred from the product
    /// type: `Product.SubscriptionPeriod` has no display form of its own, and
    /// "1 month" reads worse than "per month".
    var periodCaption: String {
        switch self {
        case .weekly: "per week"
        case .monthly: "per month"
        case .lifetime: "one payment"
        }
    }

    /// Monthly is pre-selected and is the only row that carries a marker.
    var badge: String? { self == .monthly ? "BEST OPTION" : nil }
}

/// One plan as the paywall needs to draw it.
///
/// A plain value rather than RevenueCat's `Package`, so that the view layer
/// imports nothing from the SDK: the paywall's job is to show three prices and
/// return a choice, and it should keep working if the store behind it is ever
/// replaced. The `Package` itself stays inside `SubscriptionManager`, which is
/// the only type that has to hand something back to RevenueCat.
nonisolated struct PlanOffer: Sendable {
    let plan: ProductID
    /// The App Store product this plan resolved to, for the analytics funnel —
    /// it is the join key between Firebase, RevenueCat and App Store Connect.
    let productIdentifier: String
    /// Already localised — the correct currency, symbol and separators for the
    /// user's own store front, which is why it is never composed here.
    let displayPrice: String
    let price: Decimal
    let currencyCode: String?

    /// The intro offer this user is *eligible* for — never merely the one the
    /// product defines.
    ///
    /// The distinction is the whole point: a product keeps its introductory
    /// offer forever, so anyone who has already used a trial would be shown
    /// "7 days free" and then charged immediately. `nil` for everyone the store
    /// says is ineligible, and for everyone whose eligibility cannot be
    /// determined — an unclaimed trial costs a conversion, a claimed-then-
    /// charged one costs a refund and a one-star review.
    let introductory: IntroductoryOffer?

    nonisolated struct IntroductoryOffer: Sendable {
        /// Free trials and paid intro periods read differently on the button
        /// and in the renewal disclosure, and only one of them may say "free".
        let isFreeTrial: Bool
        /// Ready to show: "7 days free", or "$1.99 for 1 month".
        let caption: String
    }
}

/// Owns RevenueCat and nothing else (Doc 3 Phase 7 task 2).
///
/// RevenueCat, not StoreKit, is now the source of truth: the products, the
/// prices, which plans appear and what "Pro" means are all defined in the
/// dashboard, so the plan mix and the pricing can change without an app release.
/// What the rest of the app sees is unchanged — `isPro`, an offer per plan, and
/// two methods that either work or set `purchaseError`.
///
/// Every path tolerates the SDK not being configured at all (`Purchasing.apiKey`
/// still empty), because that is the state this ships in until the dashboard is
/// filled in: no offers, no entitlement, a disabled purchase button, and the
/// listed prices under the plan names.
@MainActor
@Observable
final class SubscriptionManager {
    /// The plans that resolved against the current offering, in the order the
    /// picker reads them.
    private(set) var offers: [PlanOffer] = []
    private(set) var isPro = false
    private(set) var isLoading = false
    private(set) var purchaseError: String?
    private(set) var isPurchasing = false

    /// Which offering the visible prices came from. Carried on the paywall's
    /// events so an A/B test run from the dashboard is readable in Firebase —
    /// without it, two prices for the same plan are indistinguishable in the
    /// funnel.
    private(set) var offeringIdentifier: String?

    /// What `offers` was built from. Never handed out: a purchase must be made
    /// against the exact `Package` the price was read from, or RevenueCat cannot
    /// attribute the transaction to the offering that produced it.
    private var packages: [ProductID: Package] = [:]

    private var customerInfoTask: Task<Void, Never>?

    init() {
        // The stream must be listening before any purchase can complete,
        // including ones finished outside the app — Ask to Buy approvals, a
        // redemption on another device, an expiry that arrives while the app is
        // open, or a refund. Subscribing lazily is how those get missed.
        guard Purchases.isConfigured else { return }
        customerInfoTask = Task { [weak self] in
            for await info in Purchases.shared.customerInfoStream {
                self?.apply(info)
            }
        }
    }

    // MARK: Offerings

    /// Reads the current offering and turns it into one `PlanOffer` per plan.
    ///
    /// Safe to call repeatedly — the paywall does, on every appearance — because
    /// RevenueCat serves offerings from its own cache and only goes to the
    /// network when that cache is stale.
    func load() async {
        guard Purchases.isConfigured else {
            Log.ui.info("RevenueCat is not configured — paywall will show listed prices")
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let offerings = try await Purchases.shared.offerings()
            let offering = Purchasing.offeringIdentifier.flatMap { offerings.offering(identifier: $0) }
                ?? offerings.current

            guard let offering else {
                // A configured dashboard with no current offering: the products
                // exist but nothing is on sale, which is a setup mistake rather
                // than a runtime failure — and one that is otherwise invisible,
                // because the paywall looks merely offline.
                Log.ui.error("No current offering — check the RevenueCat dashboard")
                Analytics.log(AnalyticsEvent.productsLoadFailed, [
                    AnalyticsParam.reason: "no_current_offering",
                ])
                return
            }

            offeringIdentifier = offering.identifier
            packages = [:]

            // Driven by `ProductID` rather than by the offering's own list, so
            // the picker's order is the app's decision and a package the app
            // does not know about cannot appear in it unannounced.
            var matched: [(plan: ProductID, package: Package)] = []
            for plan in ProductID.allCases {
                guard let package = package(for: plan, in: offering) else { continue }
                packages[plan] = package
                matched.append((plan, package))
            }

            // One round trip for all three, before any of them is shown. Asked
            // per row instead, the trial line would appear a beat after the
            // price it modifies.
            let eligibility = await Purchases.shared.checkTrialOrIntroDiscountEligibility(
                productIdentifiers: matched.map(\.package.storeProduct.productIdentifier)
            )

            let resolved = matched.map { plan, package in
                let product = package.storeProduct
                return PlanOffer(
                    plan: plan,
                    productIdentifier: product.productIdentifier,
                    displayPrice: product.localizedPriceString,
                    price: product.price,
                    currencyCode: product.currencyCode,
                    introductory: introductoryOffer(
                        for: product,
                        status: eligibility[product.productIdentifier]?.status
                    )
                )
            }

            offers = resolved

            if resolved.count != ProductID.allCases.count {
                // A partial resolve leaves rows priced from the fallback list and
                // unbuyable. Worth an event: it means the dashboard and the app
                // disagree about which plans exist, and nothing else would say so.
                Analytics.log(AnalyticsEvent.productsLoadFailed, [
                    AnalyticsParam.reason: "unmatched_packages",
                    AnalyticsParam.count: resolved.count,
                ])
            }

            await refreshEntitlements()
        } catch {
            Log.ui.error("Offerings load failed: \(error.localizedDescription, privacy: .public)")
            // The paywall stays usable when this fails — it falls back to the
            // listed prices and disables the button — so the failure is
            // invisible from the outside. It is also the difference between a
            // paywall nobody bought from and a paywall nobody *could* buy from.
            Analytics.log(AnalyticsEvent.productsLoadFailed, [
                AnalyticsParam.reason: error.localizedDescription,
            ])
        }
    }

    /// Finds the package a plan is sold through, three ways, in falling order of
    /// confidence.
    ///
    /// One match would be enough if the dashboard were guaranteed to mirror this
    /// file, and it is not: product identifiers get renamed, and a package can be
    /// added with a custom identifier rather than one of RevenueCat's predefined
    /// ones. Matching on the product identifier first keeps the mapping exact
    /// where it is known, and the package type keeps the app working when it is
    /// not.
    private func package(for plan: ProductID, in offering: Offering) -> Package? {
        offering.availablePackages.first { $0.storeProduct.productIdentifier == plan.rawValue }
            ?? offering.availablePackages.first { $0.packageType == plan.packageType }
            ?? offering.package(identifier: plan.rawValue)
    }

    /// Builds the trial or intro line, and only for a user the store says may
    /// have it. `.unknown` is treated as ineligible on purpose — RevenueCat
    /// returns it when it cannot see the subscription group, and showing the
    /// full price to someone who was entitled to a trial is the cheaper of the
    /// two mistakes.
    private func introductoryOffer(
        for product: StoreProduct,
        status: IntroEligibilityStatus?
    ) -> PlanOffer.IntroductoryOffer? {
        guard status == .eligible, let discount = product.introductoryDiscount else { return nil }
        let period = Self.describe(discount.subscriptionPeriod, repeated: discount.numberOfPeriods)

        switch discount.paymentMode {
        case .freeTrial:
            return .init(isFreeTrial: true, caption: "\(period) free")
        case .payUpFront, .payAsYouGo:
            return .init(isFreeTrial: false, caption: "\(discount.localizedPriceString) for \(period)")
        @unknown default:
            return nil
        }
    }

    /// "7 days", "1 month" — the length of an intro period, spelled out.
    ///
    /// `numberOfPeriods` only exceeds one for pay-as-you-go offers, where the
    /// period repeats; for a trial or a pay-up-front intro it is always one, so
    /// multiplying is right in every case.
    private static func describe(_ period: SubscriptionPeriod, repeated count: Int) -> String {
        let total = period.value * max(count, 1)
        let unit: String
        switch period.unit {
        case .day: unit = "day"
        case .week: unit = "week"
        case .month: unit = "month"
        case .year: unit = "year"
        }
        return "\(total) \(unit)\(total == 1 ? "" : "s")"
    }

    func offer(for plan: ProductID) -> PlanOffer? {
        offers.first { $0.plan == plan }
    }

    /// Whether there is something to charge against. Asked per plan rather than
    /// of the list as a whole: a partial resolve would otherwise leave the
    /// button live over a row nothing can be bought from.
    func isPurchasable(_ plan: ProductID) -> Bool {
        packages[plan] != nil
    }

    // MARK: Purchase

    /// Every branch of the result is reported, not only the sale.
    ///
    /// A funnel that counts purchases and nothing else cannot tell a price
    /// objection from a broken product identifier: both look like "the button was
    /// pressed and no revenue arrived". Cancel, pending and failure are separate
    /// events for exactly that reason.
    func purchase(_ plan: ProductID) async {
        guard let package = packages[plan] else {
            purchaseError = "This plan isn't available right now."
            return
        }

        purchaseError = nil
        isPurchasing = true
        defer { isPurchasing = false }

        let offer = offer(for: plan)
        var planParameters: [String: Any] = [
            AnalyticsParam.plan: plan.rawValue,
            AnalyticsParam.productId: package.storeProduct.productIdentifier,
        ]
        if let offeringIdentifier {
            planParameters[AnalyticsParam.offering] = offeringIdentifier
        }

        do {
            let result = try await Purchases.shared.purchase(package: package)

            // RevenueCat reports a cancelled sheet as a *result* rather than as
            // a thrown error, so this branch is the common one — most people who
            // open a paywall leave through it.
            guard !result.userCancelled else {
                Analytics.log(AnalyticsEvent.purchaseCancelled, planParameters)
                return
            }

            apply(result.customerInfo)
            Analytics.log(AnalyticsEvent.purchaseSucceeded, planParameters.merging([
                AnalyticsParam.price: NSDecimalNumber(decimal: offer?.price ?? 0).doubleValue,
                AnalyticsParam.currency: offer?.currencyCode ?? "",
            ]) { current, _ in current })
        } catch {
            if Purchasing.isCancellation(error) {
                Analytics.log(AnalyticsEvent.purchaseCancelled, planParameters)
                return
            }
            if Purchasing.isPending(error) {
                // Ask to Buy. The customer info stream delivers the approval
                // whenever the parent gets to it, which may be days later.
                purchaseError = "Waiting for approval"
                Analytics.log(AnalyticsEvent.purchasePending, planParameters)
                return
            }
            purchaseError = Purchasing.message(for: error)
            Log.ui.error("Purchase failed: \(error.localizedDescription, privacy: .public)")
            Analytics.log(AnalyticsEvent.purchaseFailed, planParameters.merging([
                AnalyticsParam.reason: error.localizedDescription,
                AnalyticsParam.errorCode: Purchasing.code(for: error)?.rawValue ?? -1,
            ]) { current, _ in current })
        }
    }

    /// `source` is carried because Restore lives in two places — the paywall's
    /// legal row and the Settings list — and which one people actually find is
    /// the whole question behind putting it in both.
    func restore(source: String = AnalyticsValue.sourcePaywall) async {
        purchaseError = nil
        Analytics.log(AnalyticsEvent.restoreTapped, [AnalyticsParam.source: source])

        guard Purchases.isConfigured else {
            purchaseError = "Purchases aren't available in this build."
            Analytics.log(AnalyticsEvent.restoreFailed, [
                AnalyticsParam.source: source,
                AnalyticsParam.reason: "not_configured",
            ])
            return
        }

        isPurchasing = true
        defer { isPurchasing = false }

        do {
            // RevenueCat syncs the receipt and returns the resulting entitlement
            // state in one call, so there is nothing to re-read afterwards.
            apply(try await Purchases.shared.restorePurchases())
            if isPro {
                Analytics.log(AnalyticsEvent.restoreSucceeded, [AnalyticsParam.source: source])
            } else {
                purchaseError = "No previous purchase found"
                Analytics.log(AnalyticsEvent.restoreFailed, [
                    AnalyticsParam.source: source,
                    AnalyticsParam.reason: "no_purchase_found",
                ])
            }
        } catch {
            purchaseError = Purchasing.message(for: error)
            Analytics.log(AnalyticsEvent.restoreFailed, [
                AnalyticsParam.source: source,
                AnalyticsParam.reason: error.localizedDescription,
            ])
        }
    }

    // MARK: Entitlement

    /// Re-reads entitlement from RevenueCat.
    ///
    /// Cheap and safe to call on every launch: the SDK answers from its cache
    /// and refreshes in the background, which is what makes the every-fourth-
    /// launch reminder's "ask only after entitlement is known" rule affordable.
    func refreshEntitlements() async {
        guard Purchases.isConfigured else {
            // Nothing to read from, so nothing changes. `isPro` stays false,
            // which is the correct answer for a build with no store.
            return
        }
        do {
            apply(try await Purchases.shared.customerInfo())
        } catch {
            Log.ui.error("Customer info failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The single source of truth for entitlement.
    ///
    /// One named entitlement rather than a list of product identifiers: expiry,
    /// refunds, billing retry, family sharing and a promotional grant from the
    /// dashboard all arrive as changes to the same flag, and none of them needs
    /// a code change here. Deliberately not cached in `UserDefaults` — Doc 3
    /// Phase 7's criteria include expiry correctly re-locking Pro, and a
    /// remembered flag cannot expire.
    private func apply(_ info: CustomerInfo) {
        let entitled = info.entitlements[Purchasing.entitlementIdentifier]?.isActive == true
        let changed = isPro != entitled
        isPro = entitled
        Log.ui.info("Entitlement → \(entitled ? "Pro" : "Free")")

        // The property is set on every refresh, not only on a change: it is the
        // segment every other number in the console is read against, and a
        // property that is only written when it flips is missing for every user
        // whose state was already correct at launch.
        Analytics.setUserProperty(entitled, for: AnalyticsUserProperty.isPro)
        if changed {
            Analytics.log(AnalyticsEvent.entitlementChanged, [AnalyticsParam.isPro: entitled])
        }
    }
}

// MARK: - Free-tier ledger

/// Which shutter was pressed. The two are counted apart on purpose: a free
/// allowance spent on stills must not shorten the one for takes, and vice
/// versa.
nonisolated enum CaptureKind: String, CaseIterable, Sendable {
    case photo
    case video

    var displayName: String {
        switch self {
        case .photo: "Photo"
        case .video: "Video"
        }
    }
}

/// How much of the paid product a free user gets, and how often they are
/// reminded that there is a paid product.
///
/// Persisted in `UserDefaults` rather than held in memory, because the whole
/// point of a count is that it survives the app being closed — a counter that
/// resets on relaunch is not a limit, it is a decoration.
@MainActor
@Observable
final class FreeTierLedger {
    /// Front + Back is free until every third press, which is then refused and
    /// spent on the paywall instead. Presses 1 and 2 go through, 3 does not; 4
    /// and 5 go through, 6 does not.
    static let capturesPerPaywall = 3

    /// A free user meets the paywall on every fourth cold launch. The count
    /// returns to zero afterwards, so the next one is four launches away rather
    /// than immediate.
    static let launchesPerPaywall = 4

    private(set) var captureAttempts: [CaptureKind: Int] = [:]
    private(set) var launches: Int = 0

    private let store: UserDefaults

    init(store: UserDefaults = .standard) {
        self.store = store
        for kind in CaptureKind.allCases {
            captureAttempts[kind] = store.integer(forKey: Self.captureKey(kind))
        }
        launches = store.integer(forKey: Self.launchKey)
    }

    private static func captureKey(_ kind: CaptureKind) -> String {
        "freeTier.captureAttempts.\(kind.rawValue)"
    }

    private static let launchKey = "freeTier.launches"

    /// Records one press and answers whether it may proceed.
    ///
    /// The refused press is counted too. It has to be: "every third press" is a
    /// count of presses, and skipping the blocked one would move the next
    /// paywall to the fourth press after it instead of the third.
    func registerCaptureAttempt(_ kind: CaptureKind) -> Bool {
        let next = (captureAttempts[kind] ?? 0) + 1
        captureAttempts[kind] = next
        store.set(next, forKey: Self.captureKey(kind))
        return !next.isMultiple(of: Self.capturesPerPaywall)
    }

    /// Records one cold launch and answers whether this is the one that shows
    /// the paywall.
    func registerLaunch() -> Bool {
        let next = launches + 1
        let isDue = next >= Self.launchesPerPaywall
        launches = isDue ? 0 : next
        store.set(launches, forKey: Self.launchKey)
        return isDue
    }

    /// Wipes the counters. Called when Pro is granted, so a lapsed subscription
    /// starts its free allowance over rather than resuming mid-cycle.
    func reset() {
        for kind in CaptureKind.allCases {
            captureAttempts[kind] = 0
            store.set(0, forKey: Self.captureKey(kind))
        }
        launches = 0
        store.set(0, forKey: Self.launchKey)
    }

    /// Overwrites the shutter counters, leaving the launch count alone.
    ///
    /// For the `-DCGateTest` diagnostic and nothing else. It has to run the gate
    /// nine times per shutter to show the pattern, so it zeroes the counters
    /// before each row and puts the real values back at the end — a diagnostic
    /// that spends the user's free captures changes the thing it is measuring.
    /// Deliberately *not* `reset()`: that clears the launch count too, which
    /// would push the every-fourth-launch reminder back to four whenever the
    /// diagnostic ran.
    func setCaptureAttempts(_ attempts: [CaptureKind: Int]) {
        for kind in CaptureKind.allCases {
            let value = attempts[kind] ?? 0
            captureAttempts[kind] = value
            store.set(value, forKey: Self.captureKey(kind))
        }
    }
}

// MARK: - Entitlement gate

/// The one place the rest of the app asks "may they?".
///
/// Doc 3 Phase 7 task 3 is explicit: *"never scatter entitlement checks through
/// view code"*. Scattered checks are how a gate gets added to four of five
/// call sites and the fifth ships unlocked.
@MainActor
@Observable
final class EntitlementGate {
    /// Everything behind the Pro tier (Doc 1 §4.5).
    ///
    /// Split and diagonal layouts are deliberately absent. Arranging two live
    /// streams is what the preview is *for*, and in the two dual modes the
    /// capture itself is already gated — charging for the arrangement as well
    /// meant a free user could be refused twice for one recording.
    nonisolated enum Feature: String, CaseIterable, Sendable {
        case resolution4K
        case frameRate60
        case cleanSourceFiles
        case pipParameters
        case dualFrontBackCapture
        case dualRearCapture
        case watermarkRemoval

        var displayName: String {
            switch self {
            case .resolution4K: "4K recording"
            case .frameRate60: "60 fps"
            case .cleanSourceFiles: "Clean source files"
            case .pipParameters: "PiP parameters"
            case .dualFrontBackCapture: "Unlimited Front + Back capture"
            case .dualRearCapture: "Rear + Rear capture"
            case .watermarkRemoval: "No watermark"
            }
        }

        /// The line under the paywall's headline. Written about what the user
        /// was just trying to do, not about the subscription — they already
        /// know they are looking at a subscription.
        var contextLine: String {
            switch self {
            case .resolution4K: "Recording in 4K is part of DuoRec Pro."
            case .frameRate60: "Recording at 60 fps is part of DuoRec Pro."
            case .cleanSourceFiles: "Keeping each camera's untouched footage is part of DuoRec Pro."
            case .pipParameters: "Sizing and styling the floating preview is part of DuoRec Pro."
            case .dualFrontBackCapture: "You've used your free Front + Back captures for now."
            case .dualRearCapture: "Recording both rear lenses at once is part of DuoRec Pro."
            case .watermarkRemoval: "Exporting without a watermark is part of DuoRec Pro."
            }
        }
    }

    private let subscriptions: SubscriptionManager

    /// The free-tier counters. Public because the camera chrome shows what is
    /// left, and hiding it behind the gate would mean duplicating the arithmetic.
    let freeTier: FreeTierLedger

    /// Set when a gated feature was tapped, so the paywall can open in context
    /// (Doc 3 Phase 7 task 6: contextual, never on cold launch — except for the
    /// deliberate every-fourth-launch reminder, which has no context to give).
    var pendingFeature: Feature?
    var isShowingPaywall = false

    /// Closes whatever sheet is on screen and reports whether it had to.
    ///
    /// Installed by the composition root. UIKit will not present a second sheet
    /// from the root while one is already up, so a gate fired from inside the
    /// Quality, Settings or PiP Parameter sheet has to hand the screen back
    /// before the paywall can take it — otherwise the tap does nothing at all,
    /// which reads as a dead control rather than a locked feature.
    @ObservationIgnored
    var dismissPresentedSheet: (() -> Bool)?

    /// Set for the length of the dismiss-then-present handoff below.
    @ObservationIgnored
    private var isPresentationPending = false

    /// The ledger is built here rather than defaulted in the signature: a
    /// `@MainActor` initialiser cannot be a default argument, which is
    /// evaluated in the caller's (nonisolated) context.
    init(subscriptions: SubscriptionManager, freeTier: FreeTierLedger? = nil) {
        self.subscriptions = subscriptions
        self.freeTier = freeTier ?? FreeTierLedger()
    }

    var isPro: Bool { subscriptions.isPro }

    func isUnlocked(_ feature: Feature) -> Bool { subscriptions.isPro }

    /// Raises the paywall, from wherever the caller happens to be.
    ///
    /// Idempotent while one is already up or on its way, which the gated sliders
    /// depend on: a slider's binding is written on every frame of a drag, so a
    /// single refused gesture asks for the paywall thirty times. Without the
    /// guard, the later calls fire `isShowingPaywall = true` while the sheet
    /// underneath is still animating out — a present racing a dismiss, which
    /// UIKit drops, so the drag that triggered the paywall was the one drag that
    /// never showed it.
    /// `trigger` is what makes the paywall's numbers readable.
    ///
    /// One `paywall_shown` count answers nothing — the every-fourth-launch
    /// reminder, a refused shutter and a tap on `Unlock DuoRec Pro` are three
    /// completely different intents, and only one of them was the user asking.
    /// Conversion has to be measurable per trigger or the periodic reminder will
    /// always look like the best-performing surface simply because it fires most.
    func present(_ feature: Feature?, trigger: String = AnalyticsValue.triggerFeatureGate) {
        guard !isShowingPaywall, !isPresentationPending else { return }
        pendingFeature = feature

        Analytics.log(AnalyticsEvent.paywallShown, [
            AnalyticsParam.trigger: trigger,
            AnalyticsParam.feature: feature?.rawValue ?? "none",
        ])

        guard dismissPresentedSheet?() == true else {
            isShowingPaywall = true
            return
        }

        // A sheet was on screen. The wait is that dismissal's own duration.
        isPresentationPending = true
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            isPresentationPending = false
            isShowingPaywall = true
        }
    }

    /// Returns `true` when the caller may proceed; otherwise raises the paywall
    /// and returns `false`.
    @discardableResult
    func require(_ feature: Feature) -> Bool {
        if isUnlocked(feature) { return true }
        Analytics.log(AnalyticsEvent.featureGateBlocked, [AnalyticsParam.feature: feature.rawValue])
        present(feature, trigger: AnalyticsValue.triggerFeatureGate)
        return false
    }

    /// The shutter gate.
    ///
    /// Three rules, one per mode, and the mode is the only thing that decides
    /// which applies:
    ///
    /// - **Single** is free outright. It is one camera doing what every camera
    ///   app does, and charging for it would make the app look like it is
    ///   charging for the camera.
    /// - **Front + Back** has a free allowance, counted per shutter, and spends
    ///   every third press on the paywall instead of on a capture.
    /// - **Rear + Rear** has no allowance. Both previews run — seeing it is the
    ///   demonstration — but neither shutter produces a file.
    @discardableResult
    func requireCapture(_ kind: CaptureKind, mode: CaptureMode) -> Bool {
        if isPro { return true }

        switch mode {
        case .single:
            return true

        case .dualRear:
            Analytics.log(AnalyticsEvent.captureGateBlocked, [
                AnalyticsParam.mediaType: kind.rawValue,
                AnalyticsParam.mode: mode.rawValue,
            ])
            present(.dualRearCapture, trigger: AnalyticsValue.triggerCaptureGate)
            return false

        case .dualFrontBack:
            guard freeTier.registerCaptureAttempt(kind) else {
                Analytics.log(AnalyticsEvent.captureGateBlocked, [
                    AnalyticsParam.mediaType: kind.rawValue,
                    AnalyticsParam.mode: mode.rawValue,
                    AnalyticsParam.attempt: freeTier.captureAttempts[kind] ?? 0,
                ])
                present(.dualFrontBackCapture, trigger: AnalyticsValue.triggerCaptureGate)
                return false
            }
            // The allowance being *spent* is as informative as it running out:
            // together the two say how far into the free tier people get before
            // they meet the wall, which is the number the allowance is tuned on.
            Analytics.log(AnalyticsEvent.freeCaptureUsed, [
                AnalyticsParam.mediaType: kind.rawValue,
                AnalyticsParam.mode: mode.rawValue,
                AnalyticsParam.attempt: freeTier.captureAttempts[kind] ?? 0,
            ])
            return true
        }
    }

    /// Called once per cold launch. `true` means show the paywall.
    func registerLaunch() -> Bool {
        guard !isPro else { return false }
        return freeTier.registerLaunch()
    }

    /// Free-tier exports carry a watermark (Doc 1 §4.5).
    var exportsWatermark: Bool { !subscriptions.isPro }

    func isUnlocked(resolution: Resolution) -> Bool {
        resolution == .uhd4K ? isUnlocked(.resolution4K) : true
    }

    func isUnlocked(frameRate: FrameRate) -> Bool {
        frameRate == .fps60 ? isUnlocked(.frameRate60) : true
    }
}
