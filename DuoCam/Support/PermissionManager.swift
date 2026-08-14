import AVFoundation
import os
import Observation
import SwiftUI
import UIKit

/// Authorization state for one capture medium.
enum PermissionState: String, Sendable, Equatable {
    case notDetermined
    case authorized
    case denied
    case restricted

    nonisolated init(_ status: AVAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .authorized: self = .authorized
        case .denied: self = .denied
        case .restricted: self = .restricted
        @unknown default: self = .denied
        }
    }

    nonisolated var isUsable: Bool { self == .authorized }

    /// `.restricted` cannot be resolved by the user (parental controls, MDM),
    /// so offering a Settings deep link would be a dead end.
    nonisolated var isRecoverableBySettings: Bool { self == .denied }
}

/// Camera and microphone authorization (Doc 3 Phase 0 task 6).
///
/// Doc 2 §11.2 sets the policy this type serves: permission is requested at the
/// moment of stated need — onboarding page 4 — never at cold launch. So this
/// only ever *reads* state until something explicitly asks it to prompt.
///
/// Doc 2 §11.4 sets the other half: camera denial is blocking and gets a
/// dedicated recovery screen; microphone denial is **not** blocking — recording
/// proceeds silently with a dismissible banner.
@MainActor
@Observable
final class PermissionManager {
    private(set) var camera: PermissionState = .notDetermined
    private(set) var microphone: PermissionState = .notDetermined

    /// Set once the user dismisses the "audio is off" banner, so it does not
    /// reappear every session.
    var hasDismissedMicrophoneBanner = false

    init() {
        refresh()
    }

    func refresh() {
        camera = PermissionState(AVCaptureDevice.authorizationStatus(for: .video))
        microphone = PermissionState(AVCaptureDevice.authorizationStatus(for: .audio))
    }

    /// True when capture can start at all. Audio is intentionally not part of
    /// this test.
    var canStartCapture: Bool { camera.isUsable }

    /// True when the mic banner should be visible: permission is unusable, the
    /// camera is fine, and the user has not waved it away.
    var shouldShowMicrophoneBanner: Bool {
        camera.isUsable && !microphone.isUsable && !hasDismissedMicrophoneBanner
    }

    @discardableResult
    func requestCameraAccess() async -> PermissionState {
        guard camera == .notDetermined else { return camera }
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        camera = granted ? .authorized : .denied
        Log.ui.info("Camera permission → \(self.camera.rawValue, privacy: .public)")
        return camera
    }

    @discardableResult
    func requestMicrophoneAccess() async -> PermissionState {
        guard microphone == .notDetermined else { return microphone }
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        microphone = granted ? .authorized : .denied
        Log.ui.info("Microphone permission → \(self.microphone.rawValue, privacy: .public)")
        return microphone
    }

    /// Onboarding page 4 asks for both in sequence. Camera first — if it is
    /// denied, the mic prompt is pointless noise on top of a blocking failure.
    func requestCaptureAccess() async {
        await requestCameraAccess()
        await requestMicrophoneAccess()
    }

    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
