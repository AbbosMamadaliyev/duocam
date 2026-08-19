import SwiftUI

@main
struct DuoCamApp: App {
    @State private var permissions = PermissionManager()
    @State private var router: AppRouter
    @State private var subscriptions = SubscriptionManager()
    @State private var entitlements: EntitlementGate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // First line of the app's life, before any type that logs can be built.
        // Firebase drops events sent before `configure()` returns, and the very
        // first thing this initialiser goes on to do — build the permission and
        // subscription managers — is something worth an event.
        Analytics.configure()

        // Second, and in this order: the RevenueCat SDK is handed Firebase's
        // app instance ID as it comes up, and that ID does not exist until
        // Firebase is configured. Still before `SubscriptionManager`, which
        // subscribes to the SDK's customer info the moment it is built.
        Purchasing.configure()

        let permissions = PermissionManager()
        let subscriptions = SubscriptionManager()
        _permissions = State(initialValue: permissions)
        _router = State(initialValue: AppRouter(permissions: permissions))
        _subscriptions = State(initialValue: subscriptions)
        _entitlements = State(initialValue: EntitlementGate(subscriptions: subscriptions))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(permissions)
                .environment(router)
                .environment(subscriptions)
                .environment(entitlements)
                .task { await subscriptions.load() }
                // Doc 2 §2.1: the app runs in permanent dark appearance. The
                // camera feed provides all colour; chrome is monochrome plus a
                // single accent.
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active { router.handleReturnToForeground() }
        }
    }
}
