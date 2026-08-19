import Foundation
import os
import RevenueCat

/// Everything about the store that lives in the RevenueCat dashboard rather than
/// in this repository.
///
/// The subscription itself is defined there — products, offerings, packages,
/// entitlements and the prices App Store Connect will actually charge — so the
/// app holds only the three identifiers needed to *find* that configuration.
/// Filling them in is the whole of "connecting DuoCam to RevenueCat"; nothing
/// below this file needs to change when the real values arrive.
///
/// The type mirrors `Analytics`: one file talks to the SDK's global state, and
/// everything else goes through `SubscriptionManager`, which is the only other
/// place that imports RevenueCat.
nonisolated enum Purchasing {
    private static let logger = Logger(subsystem: Log.subsystem, category: "purchasing")

    // MARK: The three values from the dashboard

    /// The **public** SDK key: RevenueCat → Project → API keys → *App Store*.
    /// It starts with `appl_`, is safe to ship, and is not the secret key.
    ///
    /// An empty key means the SDK is never configured at all, and the app
    /// behaves exactly as it does with no store reachable: the paywall shows its
    /// listed prices, the purchase button is disabled, and every entitlement
    /// check answers "free". That is the same degraded path a network failure
    /// takes, so an unconfigured build is not a special case anyone has to
    /// remember — and blanking this line is a complete way to turn the store off.
    static let apiKey = "appl_kIMOwWjwKzwqdquoAzpweFUFkKm"

    /// The entitlement every paid plan grants — the one thing `isPro` reads.
    ///
    /// Named on the entitlement rather than on the products deliberately: a
    /// fourth plan, a promotional grant, a family-shared purchase and a win-back
    /// offer all arrive as the same entitlement, so nothing in the app has to
    /// learn about them.
    ///
    /// Spelled exactly as the dashboard spells it, space and all: RevenueCat
    /// matches entitlement identifiers by literal string, so `duorec pro` or
    /// `DuoRec Pro` would silently resolve to "free" for a paying customer.
    static let entitlementIdentifier = "Duorec Pro"

    /// Which offering the paywall draws its plans from. `nil` means "whatever
    /// the dashboard currently marks as the default", which is what makes the
    /// price and plan mix changeable without an app release.
    static let offeringIdentifier: String? = nil

    /// The key actually used, so a real dashboard can be pointed at a debug run
    /// without editing and rebuilding:
    ///
    /// ```
    /// xcrun simctl launch <udid> com.altzet.DuoCam -DCRevenueCatKey appl_xxx
    /// ```
    static var resolvedAPIKey: String { DebugFlags.revenueCatAPIKey ?? apiKey }

    /// Whether there is a store to talk to at all.
    static var isEnabled: Bool { !resolvedAPIKey.isEmpty }

    // MARK: Configuration

    /// Called once, from the app's initialiser, before any purchase code runs.
    ///
    /// After `Analytics.configure()` on purpose: the Firebase app instance ID
    /// below only exists once Firebase is up, and it is what lets a purchase in
    /// RevenueCat's charts be joined to the funnel that produced it in Firebase.
    static func configure() {
        guard isEnabled else {
            logger.error("RevenueCat API key is not set — purchases are off for this build")
            return
        }
        guard !Purchases.isConfigured else { return }

        #if DEBUG
        Purchases.logLevel = .debug
        #else
        Purchases.logLevel = .warn
        #endif

        Purchases.configure(withAPIKey: resolvedAPIKey)

        if let instanceID = Analytics.appInstanceID {
            Purchases.shared.attribution.setFirebaseAppInstanceID(instanceID)
        }

        logger.info("RevenueCat configured")
    }

    // MARK: Errors

    /// Turns a RevenueCat failure into something a person can act on.
    ///
    /// The SDK's own `localizedDescription` is written for a developer — it
    /// names the API that failed — and putting that under a purchase button
    /// tells the user nothing about what to do next. Only the codes worth a
    /// different action are spelled out; everything else keeps the SDK's text
    /// rather than being flattened into "Something went wrong", which would
    /// hide the one error a support message needs.
    static func message(for error: Error) -> String {
        switch code(for: error) {
        case .purchaseNotAllowedError:
            "Purchases are not allowed on this device."
        case .productNotAvailableForPurchaseError, .productAlreadyPurchasedError:
            "This plan isn't available from the App Store right now."
        case .networkError, .offlineConnectionError:
            "No connection to the App Store. Check your network and try again."
        case .storeProblemError:
            "The App Store is having trouble. Try again in a moment."
        case .configurationError, .invalidCredentialsError:
            "This build isn't set up for purchases yet."
        default:
            error.localizedDescription
        }
    }

    /// RevenueCat throws `NSError`s in its own domain rather than the `ErrorCode`
    /// enum itself, so the code is read back out rather than cast to.
    static func code(for error: Error) -> ErrorCode? {
        let error = error as NSError
        guard error.domain == ErrorCode.errorDomain else { return nil }
        return ErrorCode(rawValue: error.code)
    }

    /// A cancelled purchase is not a failure and must never be reported as one —
    /// it is the single most common way a paywall ends.
    static func isCancellation(_ error: Error) -> Bool {
        code(for: error) == .purchaseCancelledError
    }

    /// Ask to Buy and other deferred purchases. The customer info stream
    /// delivers the approval later, whenever it comes.
    static func isPending(_ error: Error) -> Bool {
        code(for: error) == .paymentPendingError
    }
}
