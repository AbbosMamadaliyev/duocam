# DuoCam — Analytics Event Reference

Firebase Analytics, project `duocam-f49e3`, bundle `com.altzet.DuoCam`.

Every key below is declared in `DuoCam/Analytics/AnalyticsKeys.swift` and logged
through `DuoCam/Analytics/Analytics.swift`. **Nothing outside those two files
spells an event or parameter name as a literal** — a name typed at a call site is
a name that can be typed differently at the next one, and Firebase has no way to
tell the two apart. It simply grows a second, near-identical event that splits
the funnel in half.

- **89 events**, **15 screens**, **6 user properties**.
- Firebase's ceilings: 500 distinct event names, 25 parameters per event, 25 user
  properties, 40 characters per name, 100 characters per string value. Every name
  here obeys them, and `Analytics.sanitized` enforces the value rules at runtime.

## Contents

1. [How to add an event](#how-to-add-an-event)
2. [Screens](#screens)
3. [User properties](#user-properties)
4. [Events](#events)
5. [Shared parameters](#shared-parameters)
6. [What is deliberately *not* tracked](#what-is-deliberately-not-tracked)
7. [Verifying it in the simulator](#verifying-it-in-the-simulator)

---

## How to add an event

1. Declare the name in `AnalyticsEvent`, the parameters in `AnalyticsParam`, and
   any closed vocabulary of values in `AnalyticsValue`.
2. Log it from the **view model**, not the view, wherever a view model exists.
   The camera's controls are logged inside `CameraViewModel` so a second call
   site — a debug override, a keyboard shortcut, a future widget — cannot reach
   the same action past the instrumentation.
3. For anything driven by a slider, a drag or a pinch, use
   `CameraViewModel.analyticsSettled(_:key:_:)`. It logs the value the control
   **settled** on, 700 ms after the last change. Logging directly would send one
   event per display frame — a single sweep of the width slider is over a hundred
   writes describing a number nobody chose.
4. Add a row to this file.

---

## Screens

Logged as Firebase's own `screen_view`, via `.analyticsScreen(_:class:)`.

Firebase's automatic screen tracking watches `UIViewController` transitions, and
a SwiftUI app has exactly one — so left alone every screen in DuoCam reports as
`UIHostingController`. These are named explicitly for that reason.

| `screen_name` | `screen_class` | Where |
|---|---|---|
| `launching` | `LaunchingView` | Capability probe is running |
| `onboarding` | `OnboardingView` | The four-page carousel |
| `camera_access_needed` | `CameraAccessNeededView` | Camera permission denied |
| `camera` | `CameraScreen` | The product |
| `gallery` | `GalleryView` | The app's own captures |
| `capture_detail` | `CaptureDetailView` | Full-screen playback, trim, export |
| `paywall` | `PaywallView` | The Pro upgrade sheet |
| `capability_inspector` | `CapabilityInspectorView` | Diagnostics |
| `sheet_layout` | `LayoutSheet` | Layout picker |
| `sheet_quality` | `QualitySheet` | Quality sheet, from the pill |
| `sheet_settings` | `SettingsSheet` | Settings |
| `sheet_pip_parameter` | `PiPParameterSheet` | PiP size, border, colour |
| `sheet_adjustments` | `AdjustmentsSheet` | Manual controls, debug-flag only |
| `manual_controls` | `ManualControls` | Manual controls, pushed from Settings |
| `quality_options` | `QualityOptionRows` | Quality, pushed from Settings |

---

## User properties

The slow-moving facts a session is segmented *by*, as opposed to the things that
happen inside it. Deliberately few: Firebase caps them at 25 per project and the
names are permanent.

| Property | Values | Set when |
|---|---|---|
| `is_pro` | `true` / `false` | Every entitlement refresh, not only on change |
| `multi_cam_supported` | `true` / `false` | After the capability probe |
| `capture_engine` | `multi_cam` / `simulated` | Composition root picks an engine |
| `preferred_mode` | `dualFrontBack` / `dualRear` / `single` | Mode selector changes |
| `preferred_layout` | `pipRounded` … `splitDiagonal` | Layout card chosen |
| `onboarding_completed` | `true` / `false` | Launch, and on finishing onboarding |

---

## Events

### App lifecycle

| Event | Parameters | Notes |
|---|---|---|
| `app_launched` | `destination`, `is_pro`, `engine`, `multi_cam_supported`, `mode` | Logged **after** the root state machine resolves. Where a launch *lands* is the useful part: an install that opens onto the permission wall and one that opens onto a live camera are two different sessions. |
| `device_capability_probed` | `device_model`, `system_version`, `multi_cam_supported`, `available_modes` | The hardware answer, once per launch. Everything downstream follows from it. |
| `capture_engine_selected` | `engine`, `multi_cam_supported` | Real multi-cam or the simulated engine. |

### Onboarding

| Event | Parameters | Notes |
|---|---|---|
| `onboarding_started` | `count` | |
| `onboarding_page_viewed` | `index`, `name` | Every page, not just the first and last — the carousel is swipeable, so the drop-off *between* pages is what says which promise stops holding attention. `name` comes from the mockup style, not the headline: headlines get rewritten, and a page identified by its copy silently becomes a new page in the dashboard. |
| `onboarding_continue_tapped` | `index`, `name`, `value` | `value` is the button's title. |
| `onboarding_skipped` | `index`, `name` | |
| `onboarding_completed` | — | Logged **after** the permission prompts, so it sits after the two `permission_result`s in the session. |

### Permissions

| Event | Parameters | Notes |
|---|---|---|
| `permission_result` | `name` (`camera`/`microphone`), `result` (`granted`/`denied`) | Only when a prompt was actually shown. Without the `notDetermined` guard the grant rate would climb towards 100% on its own. |
| `permission_settings_opened` | `source`, `name` | The one exit from a denied camera. |

### Recording

| Event | Parameters | Notes |
|---|---|---|
| `recording_started` | capture shape + `is_pro`, `has_clean_sources`, `codec` | Logged where the **writer came up**, not where the button was pressed. A failed start never reaches here, which is what keeps the start-to-save ratio readable. |
| `recording_start_failed` | capture shape + `reason` | |
| `recording_stopped` | capture shape + `duration_seconds` | The user action. |
| `recording_saved` | capture shape + `duration_seconds`, `drop_percent`, `frames_appended`, `has_clean_sources` | The pipeline's answer to it. The gap between the two counts is the failure rate of everything downstream of the shutter. `drop_percent` is the field number for Doc 3's 0.1% budget. |
| `recording_save_failed` | capture shape + `duration_seconds`, `reason` | |
| `recording_pause_toggled` | `enabled`, `duration_seconds` | |

### Photo

| Event | Parameters | Notes |
|---|---|---|
| `photo_captured` | capture shape + `during_recording`, `self_timer`, `flash_mode`, `value` | `value` is `screen_flash` or `none` — whether the front camera's only light source is ever used is the question behind having built it. |
| `photo_capture_failed` | capture shape + `reason`, `during_recording` | |
| `still_during_video_captured` | capture shape + `duration_seconds` | The white shutter pressed during a take. |

### Photo library

| Event | Parameters |
|---|---|
| `saved_to_photo_library` | `media_type`, `source` |
| `photo_library_save_failed` | `media_type`, `source` |

### Camera controls

| Event | Parameters | Notes |
|---|---|---|
| `capture_mode_changed` | `mode`, `previous_mode` | Also sets `preferred_mode`. |
| `photo_video_mode_changed` | `sub_mode`, `previous_mode` | |
| `layout_selected` | `layout`, `previous_layout`, `mode` | Also sets `preferred_layout`. |
| `streams_swapped` | capture shape + `source`, `during_recording` | `source` distinguishes the bottom-cluster button from the split divider's double-tap. |
| `streams_swap_blocked` | `source`, `mode` | Every one of these is a dual session whose second stream never came up. |
| `zoom_stop_selected` | `zoom_label`, `zoom_factor`, `primary_source`, `mode`, `during_recording` | |
| `aspect_ratio_toggled` | `aspect_ratio`, `layout` | |
| `aspect_ratio_blocked` | `reason`, `aspect_ratio` | Refused mid-take. |
| `flash_mode_toggled` | `flash_mode`, `primary_source` | |
| `torch_toggled` | `source`, `enabled`, `during_recording` | |
| `torch_unavailable` | `source`, `primary_source` | The front camera has no LED. |
| `grid_toggled` | `enabled` | |
| `level_toggled` | `enabled` | |
| `mirror_front_toggled` | `enabled` | |
| `self_timer_changed` | `self_timer` | |
| `save_to_photos_toggled` | `enabled` | |
| `lens_source_changed` | `stream_role`, `value`, `source` | |

### Preview gestures

| Event | Parameters | Notes |
|---|---|---|
| `focus_tapped` | `stream_role`, `during_recording` | **Debounced** — people tap repeatedly while a scene settles, and three taps in a second is one intention. |
| `focus_locked` | `stream_role`, `during_recording` | Long press. |
| `chrome_visibility_toggled` | `enabled`, `during_recording` | The app's one completely invisible gesture — nothing on screen advertises the double-tap, so how often it is found at all is the question. |
| `overlay_repositioned` | `overlay_x`, `overlay_y`, `layout`, `during_recording` | At the **end** of the drag. |
| `overlay_pinch_resized` | `width_fraction`, `height_fraction`, `layout` | **Debounced.** The pinch and the two sliders reach the same numbers by different routes; which one people use decides whether the parameter sheet earns its place in Settings. |

### Sheets

| Event | Parameters | Notes |
|---|---|---|
| `sheet_opened` | `name`, `source`, `mode` / `locked` | Every sheet goes through `CameraViewModel.presentSheet(_:from:)`. Quality is reachable from the pill *and* from Settings, and the two are completely different moments — assigning `activeSheet` directly at the call site lost that. |

### Quality

| Event | Parameters | Notes |
|---|---|---|
| `resolution_selected` | `resolution`, `mode` | Logged **after** the Pro gate. A refusal already has `feature_gate_blocked`; counting it here too would make 4K adoption read as high among users who never got it. |
| `frame_rate_selected` | `frame_rate`, `mode` | Same rule. |
| `codec_selected` | `codec` | |
| `clean_sources_toggled` | `enabled` | |
| `quality_option_blocked` | `name`, `mode`, `reason` | The device's own refusal, established by building a real session. The only evidence of which tiers hardware in the field actually declines. |
| `quality_degraded` | capture shape + `reason`, `during_recording` | What the device actually gave, per model. |

### PiP parameters (Pro)

| Event | Parameters | Notes |
|---|---|---|
| `pip_parameter_changed` | `parameter` (`width`/`height`/`corner_radius`/`thickness`), `value`, `layout` | **Debounced.** |
| `pip_border_color_selected` | `name`, `value` | `name` is the swatch's own, or `custom` from the colour picker — the split worth knowing, since seven presets exist precisely to make the picker unnecessary. Custom is debounced. |
| `pip_parameters_reset` | `layout` | |

### Manual controls

| Event | Parameters | Notes |
|---|---|---|
| `manual_control_changed` | `control`, `stream_role`, `value`, `enabled` | **Debounced.** `enabled: false` means the control was returned to automatic — a manual control that did not work for the user. |
| `manual_controls_reset` | `stream_role` | |

### Gallery

| Event | Parameters | Notes |
|---|---|---|
| `gallery_opened` | `source` | |
| `gallery_capture_opened` | `source`, `media_type`, `mode`, `layout`, `has_clean_sources` | Both routes in — a plain tap and the context menu's "Show clean sources" — land here, or the dual-source feature would look unused because its entry point was untracked. |
| `gallery_selection_started` | `count` | |
| `gallery_selection_cancelled` | `count` | |
| `capture_deleted` | `source`, `media_type`, `count` | One event per **batch**, not per file: the user pressed Delete once. |
| `capture_share_tapped` | `source`, `media_type` | |
| `clean_sources_opened` | `source`, `mode` | |

### Export and trim

| Event | Parameters | Notes |
|---|---|---|
| `export_started` | `preset`, `media_type`, `trimmed`, `watermark`, `duration_seconds` | Three parts, because export is the app's one long-running user-facing operation and a single "exported" count cannot tell a preset nobody picks from one that never finishes. `watermark` marks the free-tier population the paywall is arguing with. |
| `export_completed` | same | |
| `export_cancelled` | same | |
| `export_failed` | same + `reason` | |
| `trim_toggled` | `enabled`, `duration_seconds` | |

### Monetization

| Event | Parameters | Notes |
|---|---|---|
| `paywall_shown` | `trigger`, `feature` | `trigger` is what makes these numbers readable: the every-fourth-launch reminder, a refused shutter and a tap on *Unlock DuoCam Pro* are three different intents, and only one is the user asking. Without it the reminder always looks best-performing simply because it fires most. |
| `paywall_dismissed` | `feature`, `plan`, `result` (`purchased`/`abandoned`) | On disappear, not on the close button — the sheet is also swipe-dismissible. |
| `paywall_plan_selected` | `plan`, `previous_plan`, `feature` | |
| `paywall_purchase_tapped` | `plan`, `product_id`, `feature`, `price`, `currency`, `offering` | The last point that still knows *why* the sheet was open. |
| `paywall_legal_link_tapped` | `name` (`terms_of_use`/`privacy_policy`), `plan` | |
| `purchase_succeeded` | `plan`, `product_id`, `price`, `currency`, `offering` | |
| `purchase_cancelled` | `plan`, `product_id`, `offering` | RevenueCat reports a cancelled sheet as a result rather than an error, so this is the common exit, not an edge case. |
| `purchase_pending` | `plan`, `product_id`, `offering` | Ask to Buy. The customer-info stream delivers the approval later. |
| `purchase_failed` | `plan`, `product_id`, `offering`, `reason`, `error_code` | Every branch is reported, not only the sale: a funnel that counts purchases alone cannot tell a price objection from a broken product identifier. `error_code` is RevenueCat's numeric code — the message is localised and reworded between SDK releases, the code is neither. |
| `products_load_failed` | `reason` (`no_current_offering`, `unmatched_packages` + `count`, or the SDK's message) | The paywall stays usable when this fails, so it is invisible from outside — and it is the difference between a paywall nobody bought from and one nobody *could* buy from. The two named reasons mean the dashboard and the app disagree about what is on sale; nothing else would say so. |
| `restore_tapped` | `source` | Restore lives in two places; which one people find is the whole question behind putting it in both. |
| `restore_succeeded` | `source` | |
| `restore_failed` | `source`, `reason` | |
| `entitlement_changed` | `is_pro` | |

### The gate

| Event | Parameters | Notes |
|---|---|---|
| `feature_gate_blocked` | `feature` | A Pro feature tapped without the entitlement. |
| `capture_gate_blocked` | `media_type`, `mode`, `attempt` | A shutter press refused by the free-tier allowance. |
| `free_capture_used` | `media_type`, `mode`, `attempt` | The allowance being *spent*. Together with the row above, this says how far into the free tier people get before they meet the wall — the number the allowance is tuned on. |

### Session health

| Event | Parameters | Notes |
|---|---|---|
| `capture_session_interrupted` | capture shape + `reason`, `during_recording` | |
| `capture_session_failed` | capture shape + `reason`, `during_recording` | |
| `capture_recoverable_failure` | capture shape + `reason`, `during_recording` | |
| `thermal_state_changed` | capture shape + `thermal_state`, `during_recording`, `duration_seconds` | Every transition, not only the two that act — `fair` mid-take is the early warning that `serious` is coming, and the distribution across models says whether the quality ceiling is set too high for the hardware. |

### Diagnostics

| Event | Parameters |
|---|---|
| `capability_inspector_opened` | `source` |

---

## Shared parameters

**The capture shape** is attached to every camera event by
`CameraViewModel.analyticsCaptureShape`, so `recording_started` and
`photo_captured` are comparable on the same axes:

`mode`, `layout`, `aspect_ratio`, `resolution`, `frame_rate`, `primary_source`,
`secondary_source`

Quality is read from `negotiatedQuality` — what the hardware **granted** — not
from what was requested. The two differ on exactly the devices where the answer
matters.

**`source` / `trigger` vocabularies** are closed sets in `AnalyticsValue`, because
free-form strings do the same damage as free-form event names: `"settings"` and
`"Settings"` are two rows in the dashboard.

---

## What is deliberately *not* tracked

- **`trackOverlayDrag`** — runs at the display's refresh rate during an overlay
  drag. The settled position is logged once, by `overlay_repositioned`.
- **The split divider's ratio** — `SplitDividerHandle`'s `DragGesture` has no
  `onEnded`, so there is no moment that means "the user chose this". Its
  double-tap-to-swap *is* tracked, as `streams_swapped` with
  `source=split_divider`.
- **Anything below `CaptureEngine`** — frame pairing, the Metal compositor,
  writer internals. Those are `os.Logger` territory; per-frame telemetry would
  exhaust the event quota in one take.
- **Debug-flag runs**, when `-DCNoAnalytics` is passed. See below.

---

## Verifying it in the simulator

Every event is mirrored to `os.Logger` under
`subsystem: com.altzet.DuoCam, category: analytics`, in DEBUG builds, **whether or
not Firebase is configured**. That is what makes the instrumentation reviewable
on a simulator that cannot be tapped.

```sh
UDID=$(xcrun simctl list devices | grep "iPhone 17 Pro Max" | grep -oE "[0-9A-F-]{36}")

xcrun simctl spawn "$UDID" log stream --level debug \
  --predicate 'subsystem == "com.altzet.DuoCam" AND category == "analytics"' \
  --style compact &

xcrun simctl launch "$UDID" com.altzet.DuoCam -DCDestination camera
```

Each line reads `▸ <event> key=value key=value`, parameters sorted.

**`-DCNoAnalytics YES` skips `FirebaseApp.configure()` entirely.** Use it with any
of the other debug flags. They drive the app through states no user would reach —
`-DCGateTest` alone fires 54 gate events in under a second — and without this every
one of them lands in the same property as real traffic.

To watch what Firebase itself is doing with the events, add the SDK's own flag to
the scheme's arguments:

```
-FIRAnalyticsDebugEnabled
```

That puts the app into DebugView in the Firebase console, where events appear
within seconds instead of being batched for up to an hour.
