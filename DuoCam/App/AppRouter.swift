import Observation
import os
import SwiftUI

/// Root-level destinations. Deliberately a small closed set: the app has one
/// job, and every extra root state is a state that can strand a user away from
/// the camera.
enum AppDestination: Equatable {
    /// Probing hardware; the launch screen is still visible underneath.
    case launching
    /// First run only — the four-page carousel (Doc 2 §11).
    case onboarding
    /// Camera permission was denied. Doc 2 §11.4: this is a dedicated,
    /// explanatory state with a Settings deep link, never a blank screen.
    case cameraAccessNeeded
    /// The product.
    case camera
}

/// Root state machine (Doc 3 Phase 0 task 8).
///
/// Cold-launch budget is 800 ms to live preview (Doc 1 §6.1), so this must not
/// do slow work itself — it decides a destination from already-known state and
/// gets out of the way.
@MainActor
@Observable
final class AppRouter {
    private(set) var destination: AppDestination = .launching

    /// Doc 2 §11.3: onboarding is shown once, with a `Replay Introduction`
    /// item in Settings.
    @ObservationIgnored
    @AppStorageBacked(key: "onboarding.hasCompleted", default: false)
    var hasCompletedOnboarding: Bool

    /// Doc 3 Phase 0 task 5: the Inspector is debug-gated but permanent.
    var isShowingCapabilityInspector = false

    private let permissions: PermissionManager

    init(permissions: PermissionManager) {
        self.permissions = permissions
    }

    /// Called once the capability probe has finished.
    func resolveDestination() {
        permissions.refresh()

        if let forced = DebugFlags.forcedDestination {
            destination = forced
            isShowingCapabilityInspector = DebugFlags.opensCapabilityInspector
            Log.ui.info("Root destination forced → \(String(describing: forced), privacy: .public)")
            return
        }

        isShowingCapabilityInspector = DebugFlags.opensCapabilityInspector

        if !hasCompletedOnboarding {
            destination = .onboarding
        } else if permissions.camera.isUsable {
            destination = .camera
        } else {
            destination = .cameraAccessNeeded
        }

        Log.ui.info("Root destination → \(String(describing: self.destination), privacy: .public)")
    }

    func completeOnboarding() {
        hasCompletedOnboarding = true
        resolveDestination()
    }

    /// Re-evaluate after returning from Settings — the user may have granted
    /// camera access while the app was backgrounded.
    func handleReturnToForeground() {
        guard destination == .cameraAccessNeeded || destination == .camera else { return }
        resolveDestination()
    }
}

/// A tiny `@AppStorage` equivalent usable outside a `View`.
///
/// `@AppStorage` only works in view bodies, and the router needs the same
/// value. Rather than duplicating the key as a string constant in two places —
/// which is how persisted flags drift apart — the storage lives here and views
/// read it through the router.
@propertyWrapper
struct AppStorageBacked<Value> {
    let key: String
    let defaultValue: Value
    private let store: UserDefaults

    init(key: String, default defaultValue: Value, store: UserDefaults = .standard) {
        self.key = key
        self.defaultValue = defaultValue
        self.store = store
    }

    var wrappedValue: Value {
        get { store.object(forKey: key) as? Value ?? defaultValue }
        nonmutating set { store.set(newValue, forKey: key) }
    }
}
