import Observation
import SwiftUI

/// A transient message in the single toast slot (Doc 2 §6.5).
struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    var systemImage: String?
    var isWarning: Bool = false

    static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id }
}

/// Owns the *single* toast slot.
///
/// Doc 2 §6.5: toasts are **queued, never stacked** — a new toast replaces the
/// current one with a crossfade. Stacked toasts in a camera app march down the
/// screen and start covering the thing the user is trying to frame, which
/// violates design principle 4.
@MainActor
@Observable
final class ToastCenter {
    private(set) var current: Toast?
    private var dismissTask: Task<Void, Never>?

    func show(_ message: String, systemImage: String? = nil, isWarning: Bool = false) {
        show(Toast(message: message, systemImage: systemImage, isWarning: isWarning))
    }

    func show(_ toast: Toast) {
        dismissTask?.cancel()
        current = toast
        dismissTask = Task { [dwell = DC.Duration.toastDwell] in
            try? await Task.sleep(for: .seconds(dwell))
            guard !Task.isCancelled else { return }
            current = nil
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        current = nil
    }
}

/// The toast slot itself: `y = safeTop + 60`, horizontally centred.
struct ToastView: View {
    let toast: Toast
    var onDismiss: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage = toast.systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(toast.isWarning ? DC.Color.accent : DC.Color.chromePrimary)
            }
            Text(toast.message)
                .font(DC.Font.sheetBody)
                .foregroundStyle(DC.Color.chromePrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 44)
        .frame(maxWidth: 320)
        .dcSurfaceElevated(in: Capsule())
        // Swipe up to dismiss early.
        .gesture(
            DragGesture(minimumDistance: 12)
                .onEnded { value in
                    if value.translation.height < -12 { onDismiss() }
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(toast.message)
        .accessibilityAddTraits(.isStaticText)
    }
}

/// Places the toast slot and animates entry/exit per Doc 2 §6.5:
/// enters sliding down 20pt with a fade, leaves fading and sliding up 12pt.
struct ToastSlot: ViewModifier {
    let center: ToastCenter

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let toast = center.current {
                ToastView(toast: toast) { center.dismiss() }
                    .padding(.top, 60)
                    .transition(
                        .asymmetric(
                            insertion: .offset(y: -20).combined(with: .opacity),
                            removal: .offset(y: -12).combined(with: .opacity)
                        )
                    )
                    .id(toast.id)
                    .zIndex(DC.Layer.toast)
            }
        }
        .dcAnimation(DC.Motion.standard, value: center.current)
    }
}

extension View {
    func toastSlot(_ center: ToastCenter) -> some View {
        modifier(ToastSlot(center: center))
    }
}

#Preview("Toast") {
    VStack(spacing: 16) {
        ToastView(toast: Toast(
            message: "Reducing quality to keep recording",
            systemImage: "thermometer.high",
            isWarning: true
        ))
        ToastView(toast: Toast(message: "Recording saved", systemImage: "checkmark.circle.fill"))
        ToastView(toast: Toast(message: "Stop recording to change quality"))
    }
    .padding(40)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(
        LinearGradient(colors: [.green, .black], startPoint: .top, endPoint: .bottom)
    )
    .preferredColorScheme(.dark)
}
