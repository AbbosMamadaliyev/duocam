import Foundation

/// Launch-argument overrides for driving the app into a specific state.
///
/// The simulator has no capture hardware and — without assistive access — no
/// way to script taps, so the only reliable way to *see* a given screen or
/// state during development is to launch straight into it:
///
/// ```
/// xcrun simctl launch <udid> com.altzet.DuoCam -DCInspector YES
/// xcrun simctl launch <udid> com.altzet.DuoCam -DCDestination onboarding
/// ```
///
/// Arguments prefixed with `-` are folded into `UserDefaults` by the system, so
/// no argument parsing is needed. Every flag is inert in release builds.
enum DebugFlags {
    #if DEBUG
    private static let defaults = UserDefaults.standard
    #endif

    private static func flag(_ key: String) -> Bool {
        #if DEBUG
        return defaults.bool(forKey: key)
        #else
        return false
        #endif
    }

    private static func string(_ key: String) -> String? {
        #if DEBUG
        return defaults.string(forKey: key)
        #else
        return nil
        #endif
    }

    /// Present the Capability Inspector immediately on launch.
    static var opensCapabilityInspector: Bool { flag("DCInspector") }

    /// Replace the root with the design-system gallery.
    static var opensDesignSystemGallery: Bool { flag("DCGallery") }

    /// Open the gallery scrolled to the bottom — the simulator cannot be
    /// scripted to scroll, so reaching the lower half needs its own entry.
    static var galleryStartsAtBottom: Bool { flag("DCGalleryBottom") }

    /// Force a root destination, bypassing onboarding and permission state.
    /// Accepts `onboarding`, `cameraAccessNeeded`, `camera`.
    static var forcedDestination: AppDestination? {
        switch string("DCDestination") {
        case "onboarding": .onboarding
        case "cameraAccessNeeded": .cameraAccessNeeded
        case "camera": .camera
        default: nil
        }
    }

    /// Force the simulated capture engine even on hardware, to compare the
    /// synthetic previews against real ones (Phase C onward).
    static var forcesSimulatedEngine: Bool { flag("DCSimulatedEngine") }

    /// Show the performance HUD — FPS, GPU time, dropped frames, thermal state,
    /// hardware cost, memory (Doc 3 Phase 5 task 8).
    static var showsPerformanceHUD: Bool { flag("DCPerfHUD") }

    /// Print the full capability report to stdout on launch.
    ///
    /// `os.Logger` output does not reach `devicectl --console`, and Doc 3
    /// Phase 5 task 9 requires the real capability ceiling of each device to be
    /// *recorded*, not merely read off a screen. This makes the report
    /// capturable from the command line on physical hardware.
    static var dumpsCapabilities: Bool { flag("DCDumpCapabilities") }

    /// After the session comes up, print the live connection graph to stdout —
    /// the Doc 3 Phase 1 acceptance criteria that only physical hardware can
    /// answer. Waits a few seconds so rotation and mirroring have settled.
    static var dumpsSelfCheck: Bool { flag("DCSelfCheck") }

    /// Record for N seconds on launch, then stop, save, and print the result.
    ///
    /// The recording pipeline has no visible UI state to screenshot and no tap
    /// to script, so this is how Doc 3 Phase 2's criteria — a playable file,
    /// the drop rate, the pairing rate — get measured rather than assumed.
    /// `0` disables it.
    /// Capture a still on launch and report what came out.
    static var photoTest: Bool { flag("DCPhotoTest") }

    /// Walk the primary stream through every available lens, printing the live
    /// connection graph after each switch.
    ///
    /// Doc 3 Phase 4 task 14's criterion — switching one stream's lens leaves
    /// the other stream running — is invisible in a screenshot and untappable
    /// from the command line. The per-stream frame counts either side of a
    /// switch are what actually answer it.
    static var lensSwitchTest: Bool { flag("DCLensTest") }

    /// Tap the swap control twice on a *live* session, dumping the connection
    /// graph around each.
    ///
    /// `DCSwapped` is not the same test: it swaps during launch, before the
    /// session is running, so it never exercises the path a user's tap takes —
    /// which is the one that fell back to a full session rebuild in Rear + Rear.
    static var swapTest: Bool { flag("DCSwapTest") }

    /// Print the probed quality constraint matrix — the per-device capability
    /// ceiling Doc 3 Phase 5 task 9 asks to be recorded.
    static var dumpsQualityMatrix: Bool { flag("DCDumpMatrix") }

    /// Request a resolution: `uhd4K`, `hd1080p`, `hd720p`.
    static var forcedResolution: Resolution? {
        string("DCResolution").flatMap(Resolution.init(rawValue:))
    }

    /// Request a frame rate: 24, 30, 60.
    static var forcedFrameRate: FrameRate? {
        #if DEBUG
        let value = defaults.integer(forKey: "DCFrameRate")
        return value > 0 ? FrameRate(rawValue: value) : nil
        #else
        return nil
        #endif
    }

    /// Turn on clean-source writing for the test run.
    static var cleanSources: Bool { flag("DCCleanSources") }

    static var recordTestSeconds: Double {
        #if DEBUG
        return defaults.double(forKey: "DCRecordTest")
        #else
        return 0
        #endif
    }

    // MARK: Camera state overrides
    //
    // Doc 2 specifies the idle state, the recording state, five layouts and
    // four sheets. Without assistive access the simulator cannot be tapped
    // into any of them, so each gets an entry point. These are how the
    // recording transition, the layout morphs and the sheets are reviewed at
    // all before hardware is available.

    /// Enter the camera already recording (Doc 2 §7).
    static var startsRecording: Bool { flag("DCRecording") }

    /// Enter recording already paused (Doc 2 §7.5). Implies `DCRecording`.
    static var startsPaused: Bool { flag("DCPaused") }

    /// Enter the camera with the two streams already swapped (Doc 2 §5.6).
    ///
    /// The swap is a role remap inside the engine rather than anything visual,
    /// so whether it worked is only answerable by looking at which stream is
    /// filling the screen — and that is exactly the kind of tap the simulator
    /// cannot be scripted into.
    static var startsSwapped: Bool { flag("DCSwapped") }

    /// Force a layout: `pipRounded`, `pipTall`, `pipWide`, `pipCircle`,
    /// `splitHorizontal`, `splitDiagonal`.
    static var forcedLayout: LayoutType? {
        string("DCLayout").flatMap(LayoutType.init(rawValue:))
    }

    /// Force the overlay's width and height, as fractions of the picture:
    /// `-DCOverlayWidth 0.9 -DCOverlayHeight 0.5`.
    ///
    /// The two size sliders in the PiP Parameter sheet are drags on a control
    /// inside a sheet — two inputs the simulator cannot be scripted into — and
    /// what they change is entirely geometric, so it has to be *seen*. Applied
    /// after the forced layout, since choosing a layout resets both.
    static var forcedOverlayWidth: CGFloat? { fraction("DCOverlayWidth") }
    static var forcedOverlayHeight: CGFloat? { fraction("DCOverlayHeight") }

    private static func fraction(_ key: String) -> CGFloat? {
        #if DEBUG
        let value = defaults.double(forKey: key)
        return value > 0 ? CGFloat(value) : nil
        #else
        return nil
        #endif
    }

    /// Force a capture mode: `dualFrontBack`, `dualRear`, `single`.
    static var forcedMode: CaptureMode? {
        string("DCMode").flatMap(CaptureMode.init(rawValue:))
    }

    /// Force a frame shape: `sixteenByNine`, `fourByThree`.
    ///
    /// The control that changes it is a single tap in the top row, which is
    /// precisely the input the simulator cannot be scripted into — and the whole
    /// claim being verified is geometric, so it has to be *seen*.
    static var forcedAspectRatio: AspectRatio? {
        string("DCAspect").flatMap(AspectRatio.init(rawValue:))
    }

    /// Present the paywall on launch.
    static var opensPaywall: Bool { flag("DCPaywall") }

    /// Present a sheet on launch: `layout`, `adjustments`, `quality`,
    /// `settings`, `pipParameters`.
    static var forcedSheet: CameraSheet? {
        string("DCSheet").flatMap(CameraSheet.init(rawValue:))
    }
}
