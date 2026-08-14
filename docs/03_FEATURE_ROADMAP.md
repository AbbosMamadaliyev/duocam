# DualCam — Feature & Implementation Roadmap

> **Document 3 of 3** · Phased build plan with scope, tasks, and acceptance criteria
> **Audience:** AI development agent
> **Dependencies:** Read `01_PROJECT_OVERVIEW.md` and `02_UI_UX_SPECIFICATION.md` first

---

## How to Use This Document

Each phase is a **shippable increment**. A phase is complete only when every acceptance criterion passes on physical hardware — not in the simulator, which cannot run `AVCaptureMultiCamSession` at all.

Phases must be built in order. Later phases assume the architecture established earlier. In particular, **Phase 2's thermal governor must exist before Phase 5's 4K support**, because retrofitting graceful degradation into a pipeline that assumes maximum quality requires rewriting the session layer.

Every phase specifies:
- **Goal** — the single sentence that defines done
- **Scope** — what is built
- **Technical tasks** — concrete implementation work
- **Acceptance criteria** — verifiable pass/fail conditions
- **Explicitly out of scope** — what must *not* be built yet, to prevent scope creep

---

## Phase 0 — Foundation

**Goal:** A running app that proves the device's real multi-camera capabilities and establishes the project's architecture.

### Why This Phase Exists

Multi-camera capability varies by device, by iOS version, and by camera combination in ways that are not reliably documented. Building UI on assumptions about available formats leads to a rewrite. This phase produces ground truth first.

### Scope

- Xcode project, targets, schemes, dependency setup
- Complete architectural skeleton (folders, protocols, dependency injection)
- A hidden **Capability Inspector** screen that enumerates and displays real device capabilities
- Permission handling
- Logging and crash reporting

### Technical Tasks

1. Create the project targeting iOS 17.0, Swift 5.9, SwiftUI lifecycle.
2. Establish the module structure:
   ```
   DualCam/
   ├── App/               entry point, root coordinator
   ├── Capture/           session, streams, compositor, recorder
   ├── Presentation/      SwiftUI views, view models
   ├── DesignSystem/      tokens, reusable components, haptics
   ├── Domain/            models, capture configuration types
   ├── Persistence/       SwiftData stack
   └── Support/           logging, capability probing, extensions
   ```
3. Define core domain types: `CaptureMode`, `LayoutType`, `StreamRole`, `CaptureConfiguration`, `QualityProfile`.
4. Implement `CapabilityProber`:
   - Check `AVCaptureMultiCamSession.isMultiCamSupported`
   - Enumerate all `AVCaptureDevice` instances via `AVCaptureDevice.DiscoverySession`
   - For each device, list formats where `format.isMultiCamSupported == true`, recording dimensions, max frame rate, and supported color spaces
   - Compute and log `hardwareCost` for each candidate device pairing
5. Build the Capability Inspector screen — a plain `List` displaying the above. This is a developer tool, gated behind a debug flag, but it stays in the codebase permanently for field diagnostics.
6. Implement `PermissionManager` covering camera and microphone, with `.notDetermined`, `.authorized`, `.denied`, `.restricted` states.
7. Add `os.Logger`-based structured logging with subsystems for `capture`, `composition`, `recording`, `thermal`, `ui`.
8. Add all required `Info.plist` usage descriptions.

### Acceptance Criteria

- [ ] App launches on a physical A12+ device and displays the Capability Inspector
- [ ] The Inspector lists at least one valid multi-cam-supported format for the front + rear-wide pairing
- [ ] `hardwareCost` is computed and displayed for each pairing
- [ ] On a device without multi-cam support, the Inspector reports this clearly instead of crashing
- [ ] Permission prompts appear with the correct, human-readable usage strings
- [ ] Logs are visible in Console.app, correctly categorized by subsystem

### Out of Scope

No camera preview. No UI beyond the Inspector. No capture.

---

## Phase 1 — Dual Preview

**Goal:** Two live camera previews render simultaneously and correctly on screen.

### Why This Phase Exists

The multi-cam connection graph is the single most error-prone part of the project. `addInput` and `addOutput` silently fail to create working connections in a multi-cam session; every connection must be built by hand. Getting this correct in isolation, before compositing or recording exist, means every later bug has a known-good foundation.

### Scope

- `AVCaptureMultiCamSession` configured with front and rear-wide inputs
- Two `AVCaptureVideoPreviewLayer` instances, manually connected
- Basic full-screen primary preview with a fixed-position secondary preview
- Session lifecycle tied to app lifecycle

### Technical Tasks

1. Implement `SessionManager` as an actor with a dedicated serial `DispatchQueue` for all session operations.
2. Session configuration sequence:
   ```swift
   session.beginConfiguration()
   defer { session.commitConfiguration() }

   // Inputs — NO automatic connections
   session.addInputWithNoConnections(frontInput)
   session.addInputWithNoConnections(backInput)

   // Preview layers created with sessionWithNoConnection:
   let frontPreview = AVCaptureVideoPreviewLayer(sessionWithNoConnection: session)
   let backPreview  = AVCaptureVideoPreviewLayer(sessionWithNoConnection: session)

   // Manual connections
   guard let frontPort = frontInput.ports(
       for: .video, sourceDeviceType: .builtInTrueDepthCamera,
       sourceDevicePosition: .front).first else { throw ... }

   let frontConn = AVCaptureConnection(inputPort: frontPort,
                                       videoPreviewLayer: frontPreview)
   guard session.canAddConnection(frontConn) else { throw ... }
   session.addConnection(frontConn)
   // repeat for back
   ```
3. Select the correct format per device: filter `device.formats` by `isMultiCamSupported`, then pick the closest match to 1920×1080 at 30fps. Apply via `device.activeFormat` inside `lockForConfiguration()`.
4. Validate `session.hardwareCost <= 1.0` after configuration. If exceeded, step the secondary stream down one format tier and retry. Log every step.
5. Build `CameraPreviewView: UIViewRepresentable` wrapping a `UIView` whose `layerClass` is `AVCaptureVideoPreviewLayer`. Handle bounds changes and orientation.
6. Set `videoGravity = .resizeAspectFill` on both layers.
7. Apply front-camera mirroring via `connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = true`.
8. Handle orientation through `connection.videoRotationAngle` (iOS 17 API), driven by an `AVCaptureDevice.RotationCoordinator`.
9. Wire session start/stop to scene phase: start on `.active`, stop on `.background`.
10. Handle `AVCaptureSessionWasInterrupted` and `AVCaptureSessionInterruptionEnded` notifications.

### Acceptance Criteria

- [ ] Both previews render live simultaneously with no visible frame drops
- [ ] The front preview is correctly mirrored; the rear preview is not
- [ ] Rotating the device updates both previews correctly
- [ ] Backgrounding and returning restores both previews within 500 ms
- [ ] A phone call interrupts and then correctly resumes the session
- [ ] `hardwareCost` stays at or below 1.0, logged on every configuration
- [ ] No memory growth over a 10-minute idle preview session
- [ ] Sustained 10-minute preview does not trigger a thermal state above `.fair` at room temperature

### Out of Scope

No recording. No compositing. No UI chrome. No gestures. No layout switching. A fixed rectangle for the secondary preview is sufficient.

---

## Phase 2 — Recording Core

**Goal:** The user can record a dual-camera video that saves to disk and plays back correctly.

### Why This Phase Exists

This is the app's core promise. Everything before it is preparation; everything after it is refinement. It also establishes the thermal governor, which every subsequent phase depends on.

### Scope

- Metal-based frame compositor
- `AVAssetWriter` recording pipeline
- Audio capture and routing
- Thermal and system-pressure governor
- File output and local persistence

### Technical Tasks

**Compositor**

1. Add `AVCaptureVideoDataOutput` per stream with manual connections. Set `alwaysDiscardsLateVideoFrames = true` and a `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange` pixel format.
2. Deliver sample buffers on two separate serial queues; synchronize them through a small ring buffer that pairs frames by presentation timestamp, tolerating up to one frame of skew.
3. Implement `MetalCompositor`:
   - `CVMetalTextureCache` for zero-copy texture creation from pixel buffers
   - A `CVPixelBufferPool` for output buffers
   - A vertex/fragment shader pair that draws the primary texture full-frame, then the secondary texture into a parameterized rounded rectangle with a stroke
   - The layout is passed as a uniform struct so it can change between frames without pipeline recreation
4. Verify the compositor sustains 30fps at 1080p with under 8 ms per frame on the oldest supported device.

**Recording**

5. Implement `RecordingController` wrapping `AVAssetWriter`:
   - Video input: HEVC, `AVVideoExpectedSourceFrameRateKey` set, bitrate scaled to resolution
   - Audio input: AAC, 44.1 kHz
   - `expectsMediaDataInRealTime = true` on both
   - Use `AVAssetWriterInputPixelBufferAdaptor` fed from the compositor's output pool
6. Handle the session start timestamp correctly: call `startSession(atSourceTime:)` with the first video buffer's PTS, not with `.zero`.
7. Implement pause/resume by tracking accumulated pause duration and offsetting subsequent buffer timestamps, so the output file is continuous.
8. Finalize with `finishWriting` and move the file into the app's media directory.

**Audio**

9. Add a single `AVCaptureDeviceInput` for the microphone with a manual connection to an `AVCaptureAudioDataOutput`.
10. Configure `AVAudioSession` with `.playAndRecord`, `.videoRecording` mode, and `.allowBluetooth`.
11. Implement directional selection through `AVAudioSession.preferredInput` data sources (front/back), defaulting to whichever matches the primary camera.

**Thermal Governor**

12. Observe `ProcessInfo.processInfo.thermalState` and each device's `systemPressureState`.
13. Define the degradation ladder, applied in order:
    | Step | Action |
    |---|---|
    | 1 | Reduce secondary stream resolution one tier |
    | 2 | Reduce primary stream resolution one tier |
    | 3 | Apply `videoMinFrameDurationOverride` to cap effective frame rate at 24fps |
    | 4 | Reduce composited output resolution |
    | 5 | Stop recording, finalize the file, notify the user |
14. Steps 1–4 apply automatically and silently except for a single toast and a quality-pill update. Step 5 shows an alert.
15. Never degrade *upward* during an active recording — quality must not visibly fluctuate mid-take.

**Persistence**

16. SwiftData model: `Capture { id, createdAt, duration, mode, layout, compositedURL, primarySourceURL?, secondarySourceURL?, thumbnailURL }`
17. Generate a thumbnail on finalize via `AVAssetImageGenerator`.
18. Pre-flight storage check: refuse to start recording below 100 MB free, warn below 500 MB.

### Acceptance Criteria

- [ ] Tapping record produces a composited file matching the on-screen preview exactly
- [ ] Recorded audio is synchronized within 40 ms across the full duration
- [ ] A 5-minute 1080p/30 dual recording completes without frame drops exceeding 0.1%
- [ ] Pause and resume produce a single continuous file with no timestamp gap
- [ ] Under induced thermal load, the governor steps down and the recording survives
- [ ] Force-quitting mid-recording leaves a recoverable or cleanly finalized file, never a corrupt one
- [ ] Peak memory during 1080p dual recording stays below 250 MB
- [ ] A recording interrupted by a phone call finalizes and saves the footage captured up to that point
- [ ] Files play back correctly in the system Photos app after export

### Out of Scope

No 4K. No 60fps. No layout switching. No clean source files. No photo capture. No gallery UI — verify output via Xcode's container inspector or a temporary share button.

---

## Phase 3 — Interface & Interaction

**Goal:** The complete native camera interface, fully implementing Document 2.

### Why This Phase Exists

Phases 0–2 produce a working capture engine with a placeholder UI. This phase is where the product becomes a product. It is the largest phase and should be treated as such.

### Scope

- Full design system implementation
- Idle-state and recording-state chrome
- The floating overlay with drag, snap, resize, and swap
- Complete gesture vocabulary
- All sheets
- Motion and haptics

### Technical Tasks

**Design System**

1. Implement all tokens from Document 2 §2 as Swift types: `Color+DualCam`, `Font+DualCam`, `Radius`, `Spacing`.
2. Build reusable components: `MaterialPill`, `CircularControlButton`, `MorphingShutter`, `CustomSegmentedControl`, `CameraSlider`, `LayoutCard`, `ToastView`.
3. Implement `HapticEngine` — a single service that pre-prepares generators and exposes semantic methods (`.captureTaken()`, `.snapped()`, `.modeChanged()`) rather than raw impact styles. This keeps the haptic vocabulary from drifting.

**Layout Geometry — build this before the overlay**

4. Implement `LayoutGeometry` as the single source of truth for frames:
   - Screen bounds and safe area insets
   - Computed frames for the top cluster, bottom cluster, and mode selector
   - The eight snap zone base positions
   - `resolvedPosition(for:)` implementing control-aware collision avoidance per Document 2 §5.4
5. Recompute geometry on: rotation, safe-area change, mode change, recording-state change, and sheet presentation.

**Overlay**

6. Implement `FloatingOverlayView` with a `DragGesture`:
   - During drag: apply the translation, scale to 1.06, increase shadow radius, render snap-zone guides, highlight the nearest zone, fire `.impact(.light)` on zone change
   - On end: project position by `velocity * 0.15`, resolve the nearest zone through `LayoutGeometry`, spring to it, fire `.impact(.medium)`
7. Add a simultaneous `MagnificationGesture` for resizing, clamped to 25%–50% of screen width, with detent haptics.
8. Add a double-tap gesture for swap, animating with `matchedGeometryEffect` between the overlay and primary frames.
9. Persist position and size per layout type in `UserDefaults`.

**Chrome**

10. Build the top cluster: quality pill (left), control trio (right), conditional overlay-rotate control, recording timer (center, recording only).
11. Build the bottom cluster: gallery thumbnail, morphing shutter, swap control, layout control, zoom pills, mode selector.
12. Implement the shutter morph as an animatable `RoundedRectangle` whose `cornerRadius` and `size` interpolate — not a cross-fade between two views.
13. Implement the recording-state transition per Document 2 §7.1, including the clockwise-drawing screen border (an animated `trim` on a `RoundedRectangle` stroke).
14. Implement the recording-only left control stack.
15. Implement chrome auto-hide after 6 seconds of idle inactivity.

**Gestures**

16. Implement the full gesture map from Document 2 §8. Use `.simultaneousGesture` and `.highPriorityGesture` deliberately; document the resolution order for any overlapping gestures.
17. Tap-to-focus: draw a reticle that scales from 1.3 to 1.0 and pulses once, then fades after 2 s. Follow-up vertical drag adjusts exposure with a sun icon on a vertical track.
18. Long-press to lock AE/AF: reticle turns `accent`, `AE/AF LOCK` label appears above it.

**Sheets**

19. Adjustments sheet with a stream selector and five parameter sliders, all live-applied.
20. Layout sheet with five schematic cards, staying open during selection, dimming the preview only 15%.
21. Quality sheet with availability reasons for unavailable options.
22. Settings screen and Gallery navigation entry points.

**Motion**

23. Implement the blur-masked camera transition per Document 2 §9.2 — capture last frame, progressive blur, cross-fade to new preview. This applies to every session reconfiguration.
24. Implement layout transitions as animated geometry interpolation, including corner radius and clip shape morphing.
25. Implement `Reduce Motion` alternatives throughout.

### Acceptance Criteria

- [ ] The overlay can be dragged to all eight snap zones and never covers a control in any of them
- [ ] Dragging feels physical — a flick carries further than a slow drag
- [ ] The shutter morphs smoothly between all five states with no visual pop
- [ ] Layout changes animate; the secondary stream's frame interpolates rather than cutting
- [ ] Mode switches show the blur transition with no visible black frame
- [ ] Every gesture in Document 2 §8 works and no gesture conflicts with another
- [ ] Every haptic in Document 2 §10 fires at the correct moment with no perceptible latency
- [ ] The recording-state transition completes in 0.4 s and all elements animate
- [ ] With Reduce Motion enabled, all animations degrade correctly and all haptics remain
- [ ] With Reduce Transparency enabled, all materials fall back to solid backgrounds with maintained contrast
- [ ] The full interface renders correctly on the smallest (iPhone SE-class where supported) and largest (Pro Max) target devices
- [ ] Chrome auto-hide works and any touch restores it instantly

### Out of Scope

No onboarding. No monetization. No gallery detail view. No export. Photo capture may remain a stub.

---

## Phase 4 — Complete Capture Feature Set

**Goal:** Every capture mode, layout, lens, and control from the feature inventory works.

### Scope

- Photo capture in all modes
- All three capture modes including `Rear + Rear`
- All five layouts
- Per-stream lens selection
- Manual controls
- Clean source file recording
- Live layout switching during recording

### Technical Tasks

**Photo**

1. Add `AVCapturePhotoOutput` per stream with manual connections.
2. In dual modes, trigger both captures within the same run loop iteration and pair the results by timestamp.
3. Composite the two stills using the same Metal layout engine, producing an image identical in framing to the video composition.
4. Implement the capture animation: 0.1 s white flash at 30% opacity, shutter scale-down, thumbnail fly-in from the shutter to the gallery position.
5. Implement burst capture on long press with a ring progress indicator.
6. Implement the self-timer (3 s / 10 s) with a large countdown numeral and a haptic per second.

**Modes**

7. Implement `Rear + Rear` — wide plus ultra-wide. Validate `hardwareCost` for this pairing specifically; it is typically higher than front + rear.
8. Hide unsupported modes entirely rather than disabling them.
9. Implement mode switching as a full session reconfiguration inside a single `beginConfiguration`/`commitConfiguration` transaction, masked by the blur transition.

**Layouts**

10. Implement all five layouts in the Metal compositor as parameterized uniforms.
11. Implement `splitHorizontal` with a draggable divider, 30%–70% range, 50% detent.
12. Implement `splitDiagonal` with an adjustable seam angle, −30° to +30°, 0° detent.
13. Implement live layout switching during recording. Because the layout is a compositor uniform, this requires no session reconfiguration and must be seamless.

**Lenses and Controls**

14. Per-stream lens selection: build a source picker accessible by long-pressing a stream. Switching a stream's lens requires reconfiguring that stream's connection only, within a configuration transaction.
15. Continuous pinch zoom on the primary stream via `videoZoomFactor` with `ramp(toVideoZoomFactor:withRate:)` for smoothness.
16. Discrete zoom stops on the zoom pills, ramping rather than jumping.
17. Manual ISO, shutter, white balance, and focus, applied per stream, wired to the Adjustments sheet.
18. Torch control with a brightness slider on long press.
19. Screen flash for front-primary capture: a full-screen white overlay at maximum brightness for the exposure duration, restoring the previous brightness after.
20. Grid overlay (rule of thirds) and a level indicator.

**Clean Sources**

21. Add two additional `AVAssetWriter` instances writing the unmodified per-stream output.
22. Gate behind a setting, default on for Pro. Validate that three concurrent writers stay within thermal and hardware budgets; if not, degrade the clean sources first, never the composited output.

### Acceptance Criteria

- [ ] Photo capture in dual mode produces a composited still that matches the preview framing exactly
- [ ] Both clean stills are saved when the setting is enabled
- [ ] `Rear + Rear` mode works on all supported target devices and is absent on unsupported ones
- [ ] All five layouts render correctly and transition smoothly between every pair
- [ ] Layout switching during recording produces no dropped frames and no visible seam in the output file
- [ ] Per-stream lens switching works without interrupting the other stream
- [ ] Pinch zoom is smooth with no stepping artifacts
- [ ] Manual controls apply to the correct stream and persist until reset
- [ ] Clean source files are frame-accurate to the composited file
- [ ] Recording with three concurrent writers stays within the thermal budget for at least 5 minutes at 1080p/30

### Out of Scope

No 4K or 60fps. No gallery or export. No monetization.

---

## Phase 5 — Quality Tiers & Performance

**Goal:** The app reliably captures at the highest quality each device genuinely supports.

### Why This Phase Comes Here

4K dual-camera recording is where hardware cost, thermal pressure, and memory pressure all peak simultaneously. Attempting it before the governor, compositor, and writer pipeline are proven produces failures that are extremely difficult to attribute.

### Scope

- 4K and 60fps where supported
- Codec selection
- Stabilization
- Deep performance optimization
- Comprehensive quality reporting

### Technical Tasks

1. Expand format selection to enumerate all `isMultiCamSupported` formats and expose the genuinely available combinations, computed live rather than assumed.
2. Implement the constraint matrix: resolution × frame rate × mode × device, with `hardwareCost` validation for every combination. Cache results per device model.
3. Implement the Quality sheet's availability reasons — each unavailable option must state *why*, referencing the actual constraint that blocks it.
4. Optimize the Metal compositor:
   - Eliminate all per-frame allocations
   - Use a triple-buffered pixel buffer pool
   - Move all texture creation to `CVMetalTextureCache`
   - Profile with Metal System Trace and reduce GPU time below 6 ms per frame at 4K
5. Optimize the writer: tune bitrate per resolution, verify HEVC hardware encoding is engaged, provide an H.264 fallback for compatibility-focused export.
6. Implement stabilization selection, probing `isVideoStabilizationModeSupported` per format — cinematic stabilization is frequently unavailable in multi-cam and must not be offered when it is not.
7. Implement a memory pressure observer that releases caches and reduces the buffer pool on warning.
8. Add a hidden performance HUD (debug builds): FPS, GPU time, dropped frames, thermal state, hardware cost, memory footprint.
9. Run a full device matrix validation and record the real capability ceiling for each supported device.

### Acceptance Criteria

- [ ] 4K dual recording works on every device where the capability probe reports it as available
- [ ] The Quality sheet never offers a combination that subsequently fails
- [ ] Every unavailable option displays an accurate reason
- [ ] GPU composition time stays below 6 ms per frame at 4K on the oldest device supporting it
- [ ] Peak memory during 4K dual recording stays below 400 MB
- [ ] Sustained 1080p/30 dual recording runs at least 10 minutes at 22°C before the first degradation step
- [ ] Frame drops remain below 0.1% at every supported quality tier
- [ ] The degradation ladder is verified end-to-end under induced thermal load at each tier

### Out of Scope

No new features. This phase adds no user-facing capability beyond quality options.

---

## Phase 6 — Review, Export & Onboarding

**Goal:** The user can find, review, export, and share what they captured — and a new user understands the app within 30 seconds.

### Scope

- Gallery grid and detail view
- Trim and export
- Share integration
- Four-page onboarding
- Settings screen
- Permission recovery states

### Technical Tasks

**Gallery**

1. `LazyVGrid`, 3 columns, 2 pt spacing, thumbnails loaded asynchronously with a memory-and-disk cache.
2. Badges: duration for video, `rectangle.on.rectangle` for captures with clean sources.
3. Detail view with `AVPlayer`, a custom scrub bar, and a bottom action row.
4. Matched-geometry zoom transition from grid cell to detail.
5. Interactive swipe-down dismissal with rubber-banding.
6. Context menu on long press: Share, Save to Photos, Delete, Show Clean Sources.
7. Multi-select mode for batch delete and batch export.

**Export**

8. Trim using `AVAssetExportSession` with a `timeRange`, driven by a dual-handle scrub bar with frame-accurate thumbnails.
9. Export presets applying `AVMutableVideoComposition` transforms:
   | Preset | Output |
   |---|---|
   | TikTok / Reels | 1080×1920, 9:16 |
   | YouTube | 1920×1080, 16:9 |
   | Square | 1080×1080, 1:1 |
   | Original | Unmodified |
10. Watermark rendering for the free tier — a subtle bottom-right mark composited during export, never during capture.
11. Save to Photos via `PHPhotoLibrary` with a dedicated album.
12. Share sheet via `ShareLink`.
13. Export progress with a determinate indicator and cancellation support.

**Onboarding**

14. Four-page `TabView` per Document 2 §11, including gradient backgrounds, floating platform badges with independent phase-offset float animations, parallax page transitions, and staggered text entry.
15. Page 4 triggers the permission request directly.
16. Permission-denied recovery state with a Settings deep link.
17. Non-blocking microphone denial with a dismissible banner.
18. `Replay Introduction` in Settings.

**Settings**

19. Full grouped `List` per Document 2 §12.2, with every preference persisted and applied on next session configuration.

### Acceptance Criteria

- [ ] The gallery loads 500+ items with smooth scrolling and no thumbnail flicker
- [ ] The detail transition is a true matched-geometry zoom, not a cross-fade
- [ ] Trim produces frame-accurate output
- [ ] All four export presets produce correctly framed, correctly oriented video
- [ ] Save to Photos succeeds and the file plays correctly in the system Photos app
- [ ] Onboarding completes in under 30 seconds at a normal reading pace
- [ ] The permission-denied state provides a working Settings deep link
- [ ] Denying microphone access still permits silent recording
- [ ] Every Settings preference persists across app restarts and takes effect

### Out of Scope

No monetization. No cloud, no accounts, no analytics beyond crash reporting.

---

## Phase 7 — Monetization & Release

**Goal:** The app is on the App Store with a working subscription.

### Scope

- StoreKit 2 subscriptions
- Paywall
- Entitlement gating
- App Store assets and submission

### Technical Tasks

1. Configure App Store Connect products: monthly, annual, lifetime (non-consumable).
2. Implement `SubscriptionManager` using StoreKit 2 with `Transaction.currentEntitlements` observation and a listener task for external transactions.
3. Implement `EntitlementGate` as a single service other code queries — never scatter entitlement checks through view code.
4. Gate the Pro features: 4K, 60 fps, split and diagonal layouts, clean source files, manual controls, watermark removal.
5. Build the paywall per Document 2 §12.3. Annual pre-selected with a savings badge. No countdown timers, no fake scarcity.
6. Trigger the paywall contextually — when the user taps a gated feature — never on cold launch.
7. Implement restore purchases.
8. Verify all StoreKit flows in Sandbox: purchase, restore, upgrade, downgrade, cancellation, expiry, refund, family sharing.
9. Prepare App Store assets: icon, screenshots per device class, preview video, description, keywords, privacy nutrition label.
10. Complete the App Privacy questionnaire accurately.
11. Prepare and host the privacy policy and terms.

### Acceptance Criteria

- [ ] All three products purchase correctly in Sandbox
- [ ] Restore purchases works on a fresh install
- [ ] Every gated feature is correctly locked for free users and unlocked for Pro
- [ ] The watermark appears on free-tier exports and is absent for Pro
- [ ] The paywall is dismissible without friction and never blocks core capture
- [ ] Subscription state survives app restart and network loss
- [ ] Expiry correctly re-locks Pro features
- [ ] The build passes App Store review guidelines self-audit, particularly §3.1 (payments) and §5.1 (privacy)

---

## Phase 8 — Post-Launch Enhancements

Prioritized by expected impact. Ship independently as separate releases.

| Priority | Feature | Rationale |
|---|---|---|
| P0 | **Landscape orientation** | Full landscape support including vertical split layouts. Frequently requested for YouTube-oriented creators. |
| P0 | **Live layout presets** | Save named combinations of mode, layout, overlay position, and quality. Recall with one tap. Reduces setup friction for repeat creators. |
| P1 | **Three-stream capture** | Front plus two rear lenses, where hardware cost permits. Genuinely differentiating; requires careful thermal work. |
| P1 | **Speed controls** | Slow motion on one stream while the other records at normal speed. |
| P1 | **External display output** | AirPlay or wired mirroring of the composited preview for monitoring. |
| P2 | **Voice-activated recording** | Start and stop by keyword, for solo creators without a remote. |
| P2 | **Apple Watch remote** | Start, stop, and layout switch from the wrist. |
| P2 | **Background blur on the secondary stream** | Portrait-style separation using person segmentation, applied only to the overlay. |
| P2 | **Custom watermark** | User-supplied logo, Pro tier. |
| P3 | **Timeline editor** | Multi-clip assembly, transitions, music. Significant scope; only if data shows users are leaving to edit elsewhere. |
| P3 | **Cloud backup** | Optional iCloud sync of captures. |

---

## Cross-Phase Engineering Standards

These apply from Phase 0 onward and are not optional.

### Concurrency

- All `AVCaptureSession` mutation occurs on one dedicated serial queue, never the main queue
- Sample buffer delegates run on their own serial queues, never shared
- UI state updates are `@MainActor`-isolated
- The capture layer is actor-isolated; view models are `@MainActor` observable objects

### Error Handling

- No `try!`, no force unwrapping in the capture layer
- Every capture failure mode maps to a typed error with a user-facing message
- Failures degrade rather than crash — a failed secondary stream falls back to Single mode with a toast, not a crash

### Testing

- Unit tests: layout geometry, snap-zone resolution, collision avoidance, the degradation ladder, entitlement gating, timestamp offsetting for pause/resume
- Snapshot tests: every UI component in every state
- Integration tests on physical devices: full record/save/playback cycle at every quality tier
- Manual device matrix: minimum iPhone XS, iPhone 12, iPhone 14 Pro, iPhone 15 Pro, and the current flagship

### Performance Budgets

| Metric | Budget |
|---|---|
| Cold launch to live preview | 800 ms |
| Layout switch (idle) | 200 ms |
| Mode switch | 600 ms |
| GPU composition per frame @ 4K | 6 ms |
| Peak memory @ 4K dual | 400 MB |
| Frame drop rate | 0.1% |
| Main thread hitches | 0 during recording |

### Definition of Done (per phase)

1. All acceptance criteria pass on at least three physical devices spanning the supported range
2. No new crashes over a 30-minute stress session
3. Instruments profiling shows no memory leaks and no main-thread blocking
4. All new UI supports VoiceOver, Dynamic Type, Reduce Motion, and Reduce Transparency
5. Code passes SwiftLint with the project's ruleset and has no compiler warnings
6. Any deviation from Documents 1 and 2 is documented with its rationale

---

## Critical Reminders for the Development Agent

1. **The simulator cannot run multi-camera sessions.** All capture work must be verified on physical A12+ hardware.

2. **Never assume a format is available.** Enumerate `isMultiCamSupported` formats at runtime, on every device, in every mode. The documentation is not authoritative; the device is.

3. **Manual connections are mandatory.** `addInput(_:)` and `addOutput(_:)` do not create working connections in a multi-cam session. Use the `WithNoConnections` variants and build every `AVCaptureConnection` explicitly, including those for preview layers.

4. **Validate `hardwareCost` after every configuration change.** Exceeding 1.0 causes the configuration to be rejected. Handle this with the degradation ladder, not with an error dialog.

5. **Build the thermal governor in Phase 2, before high quality tiers exist.** Retrofitting it later requires rewriting the session layer.

6. **Computational photography is unavailable in multi-cam.** Night Mode, Deep Fusion, ProRAW, and Cinematic Mode require a standard `AVCaptureSession`. This is exactly why Single mode exists as a separate code path.

7. **One audio input per session.** Directional capture uses `AVAudioSession` data sources, not a second input.

8. **Geometry has one source of truth.** Snap zones, control frames, and overlay bounds all derive from `LayoutGeometry`. Duplicating this math is how prototype problem P1 — the overlay covering controls — reappears.

9. **Never cut between camera states.** Every reconfiguration is masked by the blur transition. A visible black frame is the single most damaging polish failure in a camera app.

10. **Report quality honestly.** If the requested quality is not achievable, show the achieved quality immediately in the quality pill. Users forgive limitations; they do not forgive being misled about what they just recorded.
