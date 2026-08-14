import SwiftUI

@main
struct DuoCamApp: App {
    @State private var permissions = PermissionManager()
    @State private var router: AppRouter
    @State private var subscriptions = SubscriptionManager()
    @State private var entitlements: EntitlementGate
    @Environment(\.scenePhase) private var scenePhase

    init() {
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
