import os
import SwiftUI

/// The composition root's view side: it owns nothing, it only routes.
///
/// Each destination is a self-contained screen. Phase A ships the launching and
/// permission states plus the Capability Inspector; onboarding and the camera
/// arrive in later phases and are stubbed here so the state machine is
/// exercisable end to end from day one.
struct RootView: View {
    @Environment(AppRouter.self) private var router
    @Environment(PermissionManager.self) private var permissions
    @Environment(EntitlementGate.self) private var entitlements

    /// Built once the capability probe knows which engine this device needs.
    @State private var cameraModel: CameraViewModel?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if DebugFlags.opensDesignSystemGallery {
                DesignSystemGalleryView()
            } else {
                switch router.destination {
                case .launching:
                    LaunchingView()
                case .onboarding:
                    OnboardingView(
                        onFinish: { router.completeOnboarding() },
                        onRequestPermissions: { await permissions.requestCaptureAccess() }
                    )
                case .cameraAccessNeeded:
                    CameraAccessNeededView()
                case .camera:
                    if let cameraModel {
                        CameraScreen(model: cameraModel)
                    } else {
                        LaunchingView()
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: router.destination)
        .task {
            // Warm the capability probe before deciding where to go, so the
            // camera screen never has to ask "is multi-cam available?" while
            // it is trying to render.
            // Forcing a destination skips onboarding, which is where Doc 2
            // §11.2 says permission is asked for. The debug path has to do
            // what it bypassed, or the engine comes up against a camera it was
            // never allowed to open.
            if DebugFlags.forcedDestination == .camera {
                await permissions.requestCaptureAccess()
            }

            let report = await CapabilityProber().report()
            if DebugFlags.dumpsCapabilities {
                print(report.consoleDump)
                fflush(stdout)
            }
            let engine = Self.makeEngine(for: report)
            let model = CameraViewModel(
                engine: engine,
                availableModes: Self.availableModes(for: report, engine: engine),
                library: try? CaptureLibrary()
            )
            model.capabilityReport = report
            model.entitlements = entitlements
            if DebugFlags.opensPaywall { entitlements.isShowingPaywall = true }
            cameraModel = model
            router.resolveDestination()
        }
        .sheet(isPresented: Binding(
            get: { router.isShowingCapabilityInspector },
            set: { router.isShowingCapabilityInspector = $0 }
        )) {
            CapabilityInspectorView()
        }
        // Doc 3 Phase 7 task 6: the paywall is raised by a gate, in context —
        // never on cold launch. Presenting it here rather than inside the
        // camera screen means a gate in Settings or the gallery reaches it too.
        .sheet(isPresented: Binding(
            get: { entitlements.isShowingPaywall },
            set: { entitlements.isShowingPaywall = $0 }
        )) {
            PaywallView(context: entitlements.pendingFeature)
                .presentationDetents([.large])
        }
    }

    /// The composition root's one real decision (build plan deviation D-1).
    ///
    /// Everything above `CaptureEngine` is identical either way, which is what
    /// makes the whole interface reviewable in the simulator where
    /// `AVCaptureMultiCamSession` cannot run at all.
    private static func makeEngine(for report: CapabilityReport) -> any CaptureEngine {
        guard report.isMultiCamSupported, !DebugFlags.forcesSimulatedEngine else {
            Log.capture.info("Using SimulatedCaptureEngine (multi-cam unavailable or forced)")
            return SimulatedCaptureEngine()
        }
        return MultiCamCaptureEngine()
    }

    /// Which modes the mode selector may offer.
    ///
    /// On real hardware this is the capability report and nothing else — Doc
    /// 2 §4.3 requires unsupported modes to be *absent*, and offering one the
    /// device cannot deliver would be exactly the dishonesty Doc 1 §1.1 rules
    /// out. The simulated engine is a different case: it genuinely can run two
    /// synthetic streams, so all three modes are real capabilities *of that
    /// engine*, and hiding them would make the entire dual-stream interface
    /// unreviewable in the simulator.
    private static func availableModes(
        for report: CapabilityReport,
        engine: any CaptureEngine
    ) -> [CaptureMode] {
        engine is SimulatedCaptureEngine ? CaptureMode.allCases : report.availableModes
    }
}

// MARK: - Launching

private struct LaunchingView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.on.rectangle.fill")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.white.opacity(0.9))
            ProgressView()
                .tint(.white.opacity(0.6))
        }
    }
}

// MARK: - Permission recovery (Doc 2 §11.4)

/// Doc 2 §11.4: *"If camera permission is denied, the app does not show a blank
/// screen."* It explains what the camera is for and offers a working way out.
struct CameraAccessNeededView: View {
    @Environment(PermissionManager.self) private var permissions
    @Environment(EntitlementGate.self) private var entitlements

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "camera.fill.badge.ellipsis")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.white.opacity(0.6))

            Text("Camera Access Needed")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)

            Text("DuoCam records from your front and back cameras at the same time, "
                 + "so you can capture the scene and your reaction in one take. "
                 + "Without camera access there is nothing to record.")
            .font(.system(size: 16))
            .foregroundStyle(.white.opacity(0.6))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)

            Spacer()

            Button {
                permissions.openSystemSettings()
            } label: {
                Text("Open Settings")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(.white, in: Capsule())
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
    }
}

// MARK: - Phase placeholders


#Preview("Camera access needed") {
    CameraAccessNeededView()
        .environment(PermissionManager())
        .preferredColorScheme(.dark)
}
