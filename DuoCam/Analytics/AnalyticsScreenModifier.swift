import SwiftUI

/// Marks a view as a tracked screen.
///
/// Firebase's automatic screen tracking watches `UIViewController` transitions,
/// and a SwiftUI app has exactly one of those — so left alone, every screen in
/// DuoCam reports as `UIHostingController` and the console's screen report says
/// nothing. Naming them explicitly is the only way to get a real one.
///
/// Applied at the *screen* level and nowhere else. A `screen_view` on a
/// component would make the report a list of view types rather than a list of
/// places the user has been.
private struct AnalyticsScreenModifier: ViewModifier {
    let name: String
    let className: String

    func body(content: Content) -> some View {
        content.onAppear {
            Analytics.screen(name, class: className)
        }
    }
}

extension View {
    /// Logs a `screen_view` when this view appears.
    ///
    /// `class` is passed as a literal rather than read from `Self`: a modifier
    /// on a view's body sees the *modified content* type, so `String(describing:)`
    /// there yields a page of `ModifiedContent<Tuple<…>>` rather than the screen's
    /// name. It defaults to the screen name so a caller with nothing useful to add
    /// can leave it out.
    func analyticsScreen(_ name: String, class className: String? = nil) -> some View {
        modifier(AnalyticsScreenModifier(name: name, className: className ?? name))
    }
}
