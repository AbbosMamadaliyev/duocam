import FirebaseAnalytics
import FirebaseCore
import Foundation
import os

/// The one place the app talks to Firebase.
///
/// Every other file logs through this façade and imports nothing from Firebase
/// — the same containment `CaptureEngine` gives the capture layer. Two things
/// come out of that: the SDK can be swapped or removed by editing one file, and
/// a call site cannot reach past the key registry to log a name that was never
/// declared in `AnalyticsKeys`.
///
/// The type is deliberately named `Analytics`, which shadows nothing: Firebase's
/// own class is reached as `FirebaseAnalytics.Analytics` below, and only below.
nonisolated enum Analytics {
    private static let logger = Logger(subsystem: Log.subsystem, category: "analytics")

    /// Set once `FirebaseApp.configure()` has actually run. Every `log` call
    /// checks it, because Firebase drops — and warns about — events sent before
    /// configuration, and a launch-time event is exactly the kind that would be
    /// sent too early.
    private static let isConfigured = OSAllocatedUnfairLock(initialState: false)

    // MARK: Configuration

    /// Called once, from the app's initialiser, before anything can log.
    ///
    /// `FirebaseApp.configure()` raises an exception when `GoogleService-Info.plist`
    /// is missing, which would turn a misconfigured build into a launch crash for
    /// every user. The file's presence is checked first so the app degrades to
    /// "no analytics" instead — Doc 3's rule that failures degrade applies to the
    /// telemetry as much as to the camera.
    static func configure() {
        guard !DebugFlags.disablesAnalytics else {
            logger.info("Analytics disabled by launch flag")
            return
        }
        guard Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist") != nil else {
            logger.error("GoogleService-Info.plist is missing — analytics is off for this build")
            return
        }
        FirebaseApp.configure()
        isConfigured.withLock { $0 = true }
        logger.info("Firebase configured")
    }

    /// Firebase's own identifier for this install.
    ///
    /// Handed to RevenueCat at configuration time so a subscription in
    /// RevenueCat's charts can be joined to the funnel that produced it here.
    /// Without it the two consoles describe the same person twice and neither
    /// can answer "which paywall trigger actually sold".
    static var appInstanceID: String? {
        guard isConfigured.withLock({ $0 }) else { return nil }
        return FirebaseAnalytics.Analytics.appInstanceID()
    }

    // MARK: Events

    /// Logs one event.
    ///
    /// `parameters` is filtered rather than trusted: Firebase silently discards
    /// an event whose parameter values are of an unsupported type, and silently
    /// truncates strings past 100 characters. Both failures are invisible until
    /// someone notices a missing row in the console weeks later, so they are
    /// handled here instead.
    static func log(_ event: String, _ parameters: [String: Any] = [:]) {
        #if DEBUG
        logger.debug("▸ \(event, privacy: .public) \(describe(parameters), privacy: .public)")
        #endif
        guard isConfigured.withLock({ $0 }) else { return }
        FirebaseAnalytics.Analytics.logEvent(event, parameters: sanitized(parameters))
    }

    /// Logs a `screen_view`, Firebase's own event, so the console's screen
    /// reports work rather than needing a custom funnel.
    ///
    /// SwiftUI has no `viewDidAppear`, and Firebase's automatic screen tracking
    /// only sees `UIViewController`s — in a SwiftUI app that means every screen
    /// reports as the one hosting controller. So screens are named explicitly,
    /// through `.analyticsScreen(_:)`.
    static func screen(_ name: String, class className: String) {
        log(AnalyticsEventScreenView, [
            AnalyticsParam.screenName: name,
            AnalyticsParam.screenClass: className,
        ])
    }

    // MARK: User properties

    /// Sets a user property. `nil` clears it.
    ///
    /// Firebase caps these at 25 per project and the names are permanent, which
    /// is why the callers all draw from `AnalyticsUserProperty` rather than
    /// inventing one at the call site.
    static func setUserProperty(_ value: String?, for name: String) {
        #if DEBUG
        logger.debug("▸ property \(name, privacy: .public) = \(value ?? "nil", privacy: .public)")
        #endif
        guard isConfigured.withLock({ $0 }) else { return }
        FirebaseAnalytics.Analytics.setUserProperty(value.map(truncate), forName: name)
    }

    /// The `Bool` overload, so no call site has to decide between `"true"`,
    /// `"YES"` and `"1"` — three spellings of one fact is three rows in the
    /// console's segment picker.
    static func setUserProperty(_ value: Bool, for name: String) {
        setUserProperty(value ? "true" : "false", for: name)
    }

    // MARK: Sanitisation

    /// Firebase accepts `String`, `NSNumber` and `Bool` values and nothing else.
    ///
    /// Doubles are rounded to three places on the way through: a raw
    /// `0.3199999928474426` from a `CGFloat` slider is not a number anyone reads
    /// in a dashboard, and the extra digits make every event a distinct value in
    /// a histogram.
    private static func sanitized(_ parameters: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in parameters {
            switch value {
            case let text as String:
                result[key] = truncate(text)
            case let flag as Bool:
                result[key] = flag ? "true" : "false"
            case let number as Double:
                result[key] = (number * 1000).rounded() / 1000
            case let number as CGFloat:
                result[key] = (Double(number) * 1000).rounded() / 1000
            case let number as Float:
                result[key] = (Double(number) * 1000).rounded() / 1000
            case let number as Int:
                result[key] = number
            default:
                result[key] = String(describing: value)
            }
        }
        // The 25-parameter ceiling. Nothing here comes close, but an event that
        // silently loses its tail is worse than one that logs a truncated set
        // deterministically.
        guard result.count > 25 else { return result }
        let kept = result.sorted { $0.key < $1.key }.prefix(25)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    private static func truncate(_ text: String) -> String {
        text.count <= 100 ? text : String(text.prefix(100))
    }

    #if DEBUG
    private static func describe(_ parameters: [String: Any]) -> String {
        guard !parameters.isEmpty else { return "" }
        return parameters
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
    }
    #endif
}
