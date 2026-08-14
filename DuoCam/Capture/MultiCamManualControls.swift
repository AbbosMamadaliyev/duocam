import AVFoundation
import os

/// Manual exposure, focus and white balance, applied to one device.
///
/// Kept out of `MultiCamCaptureEngine` because every one of these follows the
/// same three-step shape — check support, lock, set — and inlining five copies
/// of it in the engine buries the connection-graph logic that actually needs
/// attention there.
enum DeviceManualControls {
    /// Applies a control on the session queue with the device lock held.
    ///
    /// Silently ignores unsupported controls rather than throwing: Doc 3's
    /// error-handling rule is that capture failures degrade, and a telephoto
    /// module that cannot do manual white balance should still record.
    static func apply(
        _ control: ManualControl,
        to device: AVCaptureDevice,
        on queue: DispatchQueue
    ) {
        queue.async {
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                perform(control, on: device)
            } catch {
                Log.capture.error("Manual control failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func perform(_ control: ManualControl, on device: AVCaptureDevice) {
        switch control {
        case .exposureBias(let bias):
            let clamped = bias.clamped(to: device.minExposureTargetBias...device.maxExposureTargetBias)
            device.setExposureTargetBias(clamped)

        case .iso(let iso):
            guard device.isExposureModeSupported(.custom) else { return }
            guard let iso else {
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                return
            }
            let range = device.activeFormat.minISO...device.activeFormat.maxISO
            device.setExposureModeCustom(
                duration: AVCaptureDevice.currentExposureDuration,
                iso: iso.clamped(to: range)
            )

        case .shutterSpeed(let denominator):
            guard device.isExposureModeSupported(.custom) else { return }
            guard let denominator, denominator > 0 else {
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                return
            }
            let requested = CMTime(seconds: 1 / denominator, preferredTimescale: 1_000_000)
            let range = device.activeFormat.minExposureDuration...device.activeFormat.maxExposureDuration
            let duration = min(max(requested, range.lowerBound), range.upperBound)
            device.setExposureModeCustom(duration: duration, iso: AVCaptureDevice.currentISO)

        case .whiteBalance(let kelvin):
            guard device.isWhiteBalanceModeSupported(.locked) else { return }
            guard let kelvin else {
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }
                return
            }
            let temperature = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                temperature: kelvin, tint: 0
            )
            var gains = device.deviceWhiteBalanceGains(for: temperature)
            // Gains outside the device's range throw rather than clamp, so the
            // clamp has to happen here.
            let maxGain = device.maxWhiteBalanceGain
            gains.redGain = min(max(1, gains.redGain), maxGain)
            gains.greenGain = min(max(1, gains.greenGain), maxGain)
            gains.blueGain = min(max(1, gains.blueGain), maxGain)
            device.setWhiteBalanceModeLocked(with: gains)

        case .focus(let position):
            guard let position else {
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                return
            }
            guard device.isLockingFocusWithCustomLensPositionSupported else { return }
            device.setFocusModeLocked(lensPosition: position.clamped(to: 0...1))

        case .resetAll:
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            device.setExposureTargetBias(0)
        }
    }

    /// Torch with a brightness level (Doc 2 §8, long-press on the flash icon).
    static func setTorch(
        enabled: Bool,
        level: Float,
        on device: AVCaptureDevice,
        queue: DispatchQueue
    ) {
        guard device.hasTorch, device.isTorchAvailable else { return }
        queue.async {
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if enabled {
                    try device.setTorchModeOn(level: max(0.01, min(level, 1)))
                } else {
                    device.torchMode = .off
                }
            } catch {
                Log.capture.error("Torch failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
