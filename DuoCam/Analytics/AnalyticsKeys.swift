import Foundation

/// Every analytics key the app can emit, in one place.
///
/// Nothing outside this file may spell an event or parameter name as a literal.
/// A name typed at the call site is a name that can be typed differently at the
/// next call site, and Firebase has no way to tell the two apart — the dashboard
/// simply grows a second, near-identical event that splits the funnel in half.
///
/// **Firebase's rules, which every name below already obeys:**
///
/// - Event names: ≤ 40 characters, letters/digits/underscore, must start with a
///   letter, and must not begin with `firebase_`, `google_` or `ga_`.
/// - Parameter names: ≤ 40 characters, same character set.
/// - String parameter values: ≤ 100 characters (longer values are truncated by
///   the SDK, silently).
/// - At most 25 parameters per event, and at most 500 distinct event names for
///   the whole app.
///
/// Names are `snake_case` because that is what the Firebase console, BigQuery
/// export and GA4 UI all display verbatim.
enum AnalyticsEvent {
    // MARK: App lifecycle

    /// The first frame after the root state machine has decided where to go.
    /// Carries the launch's whole shape, so a session can be segmented by it
    /// without joining against anything else.
    static let appLaunched = "app_launched"
    /// The capability probe finished — what this hardware can actually do.
    static let deviceCapabilityProbed = "device_capability_probed"
    /// Which engine the composition root picked: real multi-cam or simulated.
    static let captureEngineSelected = "capture_engine_selected"

    // MARK: Onboarding

    static let onboardingStarted = "onboarding_started"
    static let onboardingPageViewed = "onboarding_page_viewed"
    static let onboardingSkipped = "onboarding_skipped"
    static let onboardingContinueTapped = "onboarding_continue_tapped"
    static let onboardingCompleted = "onboarding_completed"

    // MARK: Permissions

    /// One per medium, after the system prompt returns.
    static let permissionResult = "permission_result"
    /// The Settings deep link — the only way out of a denied camera.
    static let permissionSettingsOpened = "permission_settings_opened"

    // MARK: Recording (the product)

    static let recordingStarted = "recording_started"
    static let recordingStopped = "recording_stopped"
    static let recordingSaved = "recording_saved"
    static let recordingSaveFailed = "recording_save_failed"
    static let recordingStartFailed = "recording_start_failed"
    static let recordingPauseToggled = "recording_pause_toggled"

    // MARK: Photo

    static let photoCaptured = "photo_captured"
    static let photoCaptureFailed = "photo_capture_failed"
    /// The white shutter pressed *during* a take (Doc 2 §7.2).
    static let stillDuringVideoCaptured = "still_during_video_captured"

    // MARK: Photo library

    static let savedToPhotoLibrary = "saved_to_photo_library"
    static let photoLibrarySaveFailed = "photo_library_save_failed"

    // MARK: Camera controls

    static let captureModeChanged = "capture_mode_changed"
    static let photoVideoModeChanged = "photo_video_mode_changed"
    static let layoutSelected = "layout_selected"
    static let streamsSwapped = "streams_swapped"
    static let streamsSwapBlocked = "streams_swap_blocked"
    static let zoomStopSelected = "zoom_stop_selected"
    static let aspectRatioToggled = "aspect_ratio_toggled"
    static let aspectRatioBlocked = "aspect_ratio_blocked"
    static let flashModeToggled = "flash_mode_toggled"
    static let torchToggled = "torch_toggled"
    static let torchUnavailable = "torch_unavailable"
    static let gridToggled = "grid_toggled"
    static let levelToggled = "level_toggled"
    static let mirrorFrontToggled = "mirror_front_toggled"
    static let selfTimerChanged = "self_timer_changed"
    static let saveToPhotosToggled = "save_to_photos_toggled"
    static let lensSourceChanged = "lens_source_changed"

    // MARK: Preview gestures

    static let focusTapped = "focus_tapped"
    static let focusLocked = "focus_locked"
    static let chromeVisibilityToggled = "chrome_visibility_toggled"
    static let overlayRepositioned = "overlay_repositioned"
    static let overlayPinchResized = "overlay_pinch_resized"

    // MARK: Sheets

    /// Which modal surface was opened, and from where. The matching
    /// `screen_view` is logged too; this one carries the *source*, which a
    /// screen view has no room for.
    static let sheetOpened = "sheet_opened"

    // MARK: Quality

    static let resolutionSelected = "resolution_selected"
    static let frameRateSelected = "frame_rate_selected"
    static let codecSelected = "codec_selected"
    static let cleanSourcesToggled = "clean_sources_toggled"
    /// A combination this hardware refused, with the device's own reason.
    static let qualityOptionBlocked = "quality_option_blocked"
    static let qualityDegraded = "quality_degraded"

    // MARK: PiP parameters

    static let pipParameterChanged = "pip_parameter_changed"
    static let pipBorderColorSelected = "pip_border_color_selected"
    static let pipParametersReset = "pip_parameters_reset"

    // MARK: Manual controls

    static let manualControlChanged = "manual_control_changed"
    static let manualControlsReset = "manual_controls_reset"

    // MARK: Gallery

    static let galleryOpened = "gallery_opened"
    static let galleryCaptureOpened = "gallery_capture_opened"
    static let gallerySelectionStarted = "gallery_selection_started"
    static let gallerySelectionCancelled = "gallery_selection_cancelled"
    static let captureDeleted = "capture_deleted"
    static let captureShareTapped = "capture_share_tapped"
    static let cleanSourcesOpened = "clean_sources_opened"

    // MARK: Export and trim

    static let exportStarted = "export_started"
    static let exportCompleted = "export_completed"
    static let exportCancelled = "export_cancelled"
    static let exportFailed = "export_failed"
    static let trimToggled = "trim_toggled"

    // MARK: Monetization

    static let paywallShown = "paywall_shown"
    static let paywallDismissed = "paywall_dismissed"
    static let paywallPlanSelected = "paywall_plan_selected"
    static let paywallPurchaseTapped = "paywall_purchase_tapped"
    static let paywallLegalLinkTapped = "paywall_legal_link_tapped"
    static let purchaseSucceeded = "purchase_succeeded"
    static let purchaseCancelled = "purchase_cancelled"
    static let purchasePending = "purchase_pending"
    static let purchaseFailed = "purchase_failed"
    static let restoreTapped = "restore_tapped"
    static let restoreSucceeded = "restore_succeeded"
    static let restoreFailed = "restore_failed"
    static let productsLoadFailed = "products_load_failed"
    static let entitlementChanged = "entitlement_changed"

    // MARK: The gate

    /// A Pro feature was tapped without the entitlement.
    static let featureGateBlocked = "feature_gate_blocked"
    /// A shutter press refused by the free-tier allowance.
    static let captureGateBlocked = "capture_gate_blocked"
    /// A shutter press that spent one of the free allowance.
    static let freeCaptureUsed = "free_capture_used"

    // MARK: Session health

    static let captureSessionInterrupted = "capture_session_interrupted"
    static let captureSessionFailed = "capture_session_failed"
    static let captureRecoverableFailure = "capture_recoverable_failure"
    static let thermalStateChanged = "thermal_state_changed"

    // MARK: Diagnostics

    static let capabilityInspectorOpened = "capability_inspector_opened"
}

/// Parameter names. Same rule as the events: never spelled at a call site.
enum AnalyticsParam {
    // Firebase's own reserved parameter names, restated so callers do not have
    // to import the SDK to use them.
    static let screenName = "screen_name"
    static let screenClass = "screen_class"

    // What
    static let source = "source"
    static let trigger = "trigger"
    static let feature = "feature"
    static let reason = "reason"
    static let result = "result"
    static let enabled = "enabled"
    static let value = "value"
    static let parameter = "parameter"
    static let control = "control"
    static let count = "count"
    static let index = "index"
    static let name = "name"

    // Capture shape
    static let mode = "mode"
    static let previousMode = "previous_mode"
    static let subMode = "sub_mode"
    static let layout = "layout"
    static let previousLayout = "previous_layout"
    static let aspectRatio = "aspect_ratio"
    static let resolution = "resolution"
    static let frameRate = "frame_rate"
    static let codec = "codec"
    static let primarySource = "primary_source"
    static let secondarySource = "secondary_source"
    static let streamRole = "stream_role"
    static let zoomLabel = "zoom_label"
    static let zoomFactor = "zoom_factor"
    static let flashMode = "flash_mode"
    static let selfTimer = "self_timer"

    // Recording outcome
    static let durationSeconds = "duration_seconds"
    static let dropPercent = "drop_percent"
    static let framesAppended = "frames_appended"
    static let hasCleanSources = "has_clean_sources"
    static let duringRecording = "during_recording"

    // Overlay
    static let widthFraction = "width_fraction"
    static let heightFraction = "height_fraction"
    static let overlayX = "overlay_x"
    static let overlayY = "overlay_y"

    // Media
    static let mediaType = "media_type"
    static let preset = "preset"
    static let trimmed = "trimmed"
    static let watermark = "watermark"

    // Money
    static let plan = "plan"
    static let previousPlan = "previous_plan"
    static let productId = "product_id"
    static let price = "price"
    static let currency = "currency"
    static let isPro = "is_pro"
    static let attempt = "attempt"
    /// Which RevenueCat offering the shown prices came from. Without it, a
    /// price test run from the dashboard is invisible here: two cohorts paying
    /// different amounts collapse into one row.
    static let offering = "offering"
    /// RevenueCat's numeric error code, kept alongside the message. The message
    /// is localised and reworded between SDK releases; the code is neither, so
    /// it is the only part of a failure worth grouping on.
    static let errorCode = "error_code"

    // Device
    static let deviceModel = "device_model"
    static let systemVersion = "system_version"
    static let multiCamSupported = "multi_cam_supported"
    static let engine = "engine"
    static let availableModes = "available_modes"
    static let thermalState = "thermal_state"
    static let destination = "destination"
    static let locked = "locked"
}

/// `screen_name` values. One per surface the user can be looking at.
///
/// Screen *class* is filled in automatically from the SwiftUI view type, so
/// these stay short and stable even when a view is renamed.
enum AnalyticsScreen {
    static let launching = "launching"
    static let onboarding = "onboarding"
    static let cameraAccessNeeded = "camera_access_needed"
    static let camera = "camera"
    static let gallery = "gallery"
    static let captureDetail = "capture_detail"
    static let paywall = "paywall"
    static let capabilityInspector = "capability_inspector"

    static let sheetLayout = "sheet_layout"
    static let sheetQuality = "sheet_quality"
    static let sheetSettings = "sheet_settings"
    static let sheetPiPParameter = "sheet_pip_parameter"
    static let sheetAdjustments = "sheet_adjustments"
    static let manualControls = "manual_controls"
    static let qualityOptions = "quality_options"
}

/// User properties — the slow-moving facts a session is segmented *by*, as
/// opposed to the things that happen inside it.
///
/// Firebase allows 25 per project and the names are permanent, so this list is
/// deliberately short: only what a funnel would actually be split on.
enum AnalyticsUserProperty {
    static let isPro = "is_pro"
    static let multiCamSupported = "multi_cam_supported"
    static let captureEngine = "capture_engine"
    static let preferredMode = "preferred_mode"
    static let preferredLayout = "preferred_layout"
    static let onboardingCompleted = "onboarding_completed"
}

/// The small closed vocabularies that appear as parameter *values*.
///
/// Free-form strings here would do the same damage as free-form event names —
/// `"settings"` and `"Settings"` are two rows in the dashboard.
enum AnalyticsValue {
    // Where a paywall came from.
    static let triggerFeatureGate = "feature_gate"
    static let triggerCaptureGate = "capture_gate"
    static let triggerLaunchReminder = "launch_reminder"
    static let triggerSettings = "settings"
    static let triggerDebugFlag = "debug_flag"

    // Where an action was taken from.
    static let sourceCameraChrome = "camera_chrome"
    static let sourceRecordingStack = "recording_stack"
    static let sourceQualityPill = "quality_pill"
    static let sourceSettings = "settings"
    static let sourcePaywall = "paywall"
    static let sourceGalleryGrid = "gallery_grid"
    static let sourceGalleryContextMenu = "gallery_context_menu"
    static let sourceCaptureDetail = "capture_detail"
    static let sourceOnboarding = "onboarding"
    static let sourcePermissionScreen = "permission_screen"
    static let sourcePreviewGesture = "preview_gesture"
    static let sourceSplitDivider = "split_divider"
    static let sourceZoomPill = "zoom_pill"
    static let sourceLayoutSheet = "layout_sheet"
    static let sourceModeSelector = "mode_selector"
    static let sourceDebugFlag = "debug_flag"

    // Media kinds.
    static let mediaPhoto = "photo"
    static let mediaVideo = "video"

    // Legal links on the paywall.
    static let legalTerms = "terms_of_use"
    static let legalPrivacy = "privacy_policy"

    // PiP parameters.
    static let pipWidth = "width"
    static let pipHeight = "height"
    static let pipCornerRadius = "corner_radius"
    static let pipThickness = "thickness"
    static let pipColor = "color"
    static let pipColorCustom = "custom"

    // Engines.
    static let engineMultiCam = "multi_cam"
    static let engineSimulated = "simulated"

    // Generic outcomes.
    static let resultGranted = "granted"
    static let resultDenied = "denied"
}
