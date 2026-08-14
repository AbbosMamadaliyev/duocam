# DuoCam — Agent Build Plan

> **Owner:** development agent
> **Derived from:** `01_PROJECT_OVERVIEW.md`, `02_UI_UX_SPECIFICATION.md`, `03_FEATURE_ROADMAP.md`
> **Status:** living document — updated as each phase completes

---

## 0. Ground Truth & Constraints

| Fact | Value |
|---|---|
| Xcode | 26.5 (build 17F42) |
| Project format | `objectVersion = 77`, `PBXFileSystemSynchronizedRootGroup` — **files added to `DuoCam/` are auto-included, no pbxproj editing needed** |
| Bundle ID | `com.altzet.DuoCam` |
| Deployment target | 17.0 (set to match spec §5.1; template shipped 26.5) |
| Verification device | **iPhone 17 Pro Max simulator** (`AEFEA9E8-1E5C-4AE5-9A98-BC02242866AB`) — never iPhone 17 Pro |

### The Simulator Problem — and the architectural answer

`AVCaptureMultiCamSession.isMultiCamSupported` is **always `false` in the simulator**, and there are no capture devices at all. Yet all iterative verification available to this agent is simulator-based.

**Answer: the capture layer is behind a protocol from day one.**

```
CaptureEngine (protocol)
├── MultiCamCaptureEngine   — real AVCaptureMultiCamSession   (physical device)
├── SingleCamCaptureEngine  — standard AVCaptureSession        (Single mode / fallback)
└── SimulatedCaptureEngine  — synthetic animated frames        (simulator + SwiftUI previews)
```

The engine is chosen once, at composition root, by `CapabilityProber`. Every layer above it — view models, geometry, chrome, gestures, compositor uniforms — is engine-agnostic. Consequences:

- 100% of Document 2 (UI/UX) is verifiable in the simulator.
- The real multi-cam connection graph stays isolated in one type, exactly where Doc 3 wants it.
- `SimulatedCaptureEngine` doubles as the SwiftUI `#Preview` provider, so every component gets a live preview.

This is a **deliberate deviation** from Doc 3's literal "verify on hardware only" instruction, not a replacement for it: hardware acceptance criteria remain the gate for phases touching real capture, and are marked ⚠️ HW below.

### Second deviation: phase order

Doc 3 orders Recording Core (its Phase 2) before Interface (its Phase 3). This plan swaps them.

**Rationale:** recording is 0% verifiable in the simulator; interface is 100% verifiable. Building the interface first produces continuously demonstrable progress. Doc 3's actual hard dependency — *"the thermal governor must exist before 4K"* — is preserved: the governor still lands well before quality tiers.

---

## 1. Phase Map

| # | Phase | Doc 3 origin | Verifiable in sim | Gate | Status |
|---|---|---|---|---|---|
| **A** | Foundation & Capability | Phase 0 | ✅ | Build + Inspector renders | **done** |
| **B** | Design System | Phase 3 (partial) | ✅ | Every component has a live preview | **done** |
| **C** | Capture Abstraction & Preview | Phase 1 | ✅ sim / ⚠️ HW real | Two previews render | **done**, HW-verified |
| **D** | Interface & Interaction | Phase 3 | ✅ | Full Doc 2 chrome, gestures, motion | **done**, D9 partial |
| **E** | Recording Core & Thermal Governor | Phase 2 | ⚠️ HW | Composited file saves | **done**, HW-verified |
| **F** | Complete Capture Feature Set | Phase 4 | partial | All modes/layouts/lenses | **done**, HW-verified |
| **G** | Quality Tiers & Performance | Phase 5 | ⚠️ HW | 4K/60 where genuinely supported | **done**, HW-verified |
| **H** | Review, Export & Onboarding | Phase 6 | ✅ | Gallery, trim, export, 4-page intro | **done** |
| **I** | Monetization & Release | Phase 7 | ✅ | StoreKit 2 sandbox flows | **built**, sandbox pending |

### Verifying states in the simulator

Without assistive access the simulator cannot be scripted to tap, so every
non-default state has a launch-argument entry point (`DebugFlags`, DEBUG only):

```
xcrun simctl launch <udid> com.altzet.DuoCam -DCDestination camera
    -DCInspector YES          # Capability Inspector
    -DCGallery YES            # design-system gallery  (+ -DCGalleryBottom YES)
    -DCRecording YES          # recording state        (+ -DCPaused YES)
    -DCLayout pipCircle       # pipRounded|pipTall|pipCircle|splitHorizontal|splitDiagonal
    -DCMode dualRear          # dualFrontBack|dualRear|single
    -DCSheet layout           # layout|adjustments|quality|settings
    -DCSimulatedEngine YES    # force synthetic streams even on hardware
    -DCPaywall YES            # the Pro paywall
    -DCResolution uhd4K       # uhd4K|hd1080p|hd720p
    -DCFrameRate 60           # 24|30|60
    -DCRecordTest 6           # record N seconds, then report
    -DCPhotoTest YES          # capture one still, then report
    -DCCleanSources YES       # enable clean-source writers for the test
    -DCDumpCapabilities YES   # print the capability report (device)
    -DCDumpMatrix YES         # print the quality constraint matrix (device)
    -DCSelfCheck YES          # print the live connection graph (device)
    -DCPerfHUD YES            # on-screen GPU / memory / cost / drop HUD
```

Reports are also written to `Library/Application Support/Captures/` —
`record-test.txt`, `photo-test.txt`, `quality-matrix.txt` — because
`simctl launch --console-pty` and `devicectl --console` both drop output
unpredictably, and the measurement is the evidence.

### Verified so far

- Capability Inspector reports the simulator honestly (no capture devices).
- Every design-system component renders over a bright scene; the 0.5pt hairline
  does its job; all five layout schematics are distinguishable.
- **P1 fixed** — the overlay resolves to a position *below* the top control
  trio instead of on top of it; measured 126pt vs the cluster's 114pt bottom.
- **P2 fixed** — layout options are a bottom sheet, preview stays visible.
- **P3 fixed** — two tiers, not three.
- **P4 fixed** — one morphing shutter, never two.
- **P5 fixed** — full-bleed preview, no letterbox bars.
- **P7 fixed** — 20pt continuous radius, 3pt white stroke, ambient shadow.
- Recording state: red screen border, left control stack, mode selector gone,
  quality pill dimmed, shutter morphed, gallery slot → still-capture button.

### Hardware verification — iPhone 14 Pro (iPhone15,2), iOS 26.6

Capability probe: multi-cam supported, all three modes available. Every camera
offers 4K30 and 1080p60 multi-cam formats. `hardwareCost` at the 1080p30
baseline is 0.143 per pairing; a live Front + Back session measures 0.449–0.500.

Connection graph self-check: 2 inputs, 2 preview connections + 2 data
connections, both active and enabled, front mirrored / rear not, rotation 90°.

Recording (6–8 s, Front + Back, PiP, 1080p30):

| Metric | Result | Budget |
|---|---|---|
| Frames appended | 215–220 | — |
| Frames dropped | **0** | — |
| Drop rate | **0.000%** | 0.100% |
| Unpaired (no overlay partner) | **0.65%** | — |
| File | plays back, correct composition | — |

Three real defects were found only because the pipeline was measured on
hardware rather than assumed:

1. **`hardwareCost` read 0.000 for every pairing.** Cost is a function of the
   *active formats*, and it was being read straight after `addInput`, before
   any format was selected. Both devices are now pinned to a 1080p30 baseline
   first, so the figure is real and comparable across pairings.
2. **The PiP overlay rendered flat green.** When no secondary frame paired, the
   compositor bound the primary's r8Unorm *luma* texture into the chroma slot;
   sampling `.rg` on it yields `(luma, 0)`, which decodes to green. The frame
   now composites primary-only instead.
3. **The overlay was upside down, and a third of frames had no overlay at all.**
   Two causes: the cameras were free-running at different rates (29% unpaired),
   fixed by pinning `activeVideoMin/MaxFrameDuration` on both; and rotation was
   hard-coded to 90°, which is right for the rear module and 180° wrong for the
   front, fixed by taking `videoRotationAngleForHorizonLevelCapture` per device
   from `RotationCoordinator`. Mirroring also had to move *before* the
   un-rotation in the transform chain, or it flips the image vertically instead
   of horizontally.

### Phase F on hardware

Photo capture produces a composited 1080×1920 still — rear full-frame, front in
the PiP with its 20pt radius and 3pt stroke, both upright — through the *same*
Metal layout engine as video, so framing matches the preview by construction.
Clean-source writing produces `-primary.mov` and `-secondary.mov` alongside the
composite with the composited drop rate still at 0.000%.

Two more defects surfaced only on device:

4. **Hard crash: `-[AVAssetWriter addInput:] Cannot call method when status is 1`.**
   `CleanSourceRecorder` called `startWriting()` before `add(input)`. The order
   is not interchangeable — `startWriting()` moves the writer to `.writing`,
   after which `addInput` raises rather than returning an error.
5. **Photo capture hung forever.** Default `AVCapturePhotoSettings` requests
   JPEG, and `AVCapturePhoto.pixelBuffer` is nil for compressed output. The
   controller then never resumed its continuation. Fixed by requesting BGRA and
   by resuming with an error whenever the primary buffer comes back nil — a
   dangling continuation is a hang, which is strictly worse than a failure.

### Phase G on hardware — the real capability ceiling

Probed constraint matrix, iPhone 14 Pro (cached per model thereafter):

| Mode | 4K | 1080p | 720p |
|---|---|---|---|
| Front + Back | 24 ✓ · 30 ✓ · **60 ✗** | all ✓ | all ✓ |
| Rear + Rear | 24 ✓ · 30 ✓ · **60 ✗** | all ✓ | all ✓ |
| Single | all ✓ | all ✓ | all ✓ |

The two blocked cells carry a real reason derived from the probe, not a guess,
so the Quality sheet cannot offer a combination that would then fail.

4K dual recording, 6 s, Front + Back, PiP:

| Metric | Result | Budget |
|---|---|---|
| Frames appended | 166 (5.55 s × 30) | — |
| Drop rate | **0.000%** | 0.100% |
| GPU per frame @ 4K | **2.76 ms** | 6.00 ms |
| Peak memory @ 4K dual | **167 MB** | 400 MB |
| Unpaired | 9.6% | — |

6. **4K delivered 7 fps instead of 30.** The compositor blocked the capture
   queue on `waitUntilCompleted()` for every frame; at 4K that stall exceeded
   the frame interval, and `alwaysDiscardsLateVideoFrames` threw away three
   frames in four — 27 appended out of an expected 180. Compositing now returns
   through `addCompletedHandler`, so capture rate is decoupled from GPU and
   encoder latency: 27 → 166 frames, with textures retained per-encode rather
   than in a shared array so two frames can be in flight safely.

### Phase H — Review, Export & Onboarding

Gallery (`LazyVGrid`, 3 columns, 2pt spacing) with async `NSCache`-backed
thumbnails, duration and clean-source badges, multi-select delete, and a
matched-geometry detail view with rubber-banded swipe dismissal. Detail carries
playback, a dual-handle trim, the four export presets, `ShareLink`, and save to
a dedicated Photos album with cancellable determinate progress.

The free-tier watermark is applied through `AVVideoCompositionCoreAnimationTool`
at **export** time only — the recorded master is never marked, so upgrading
removes it from footage already shot.

Onboarding is the four-page carousel of Doc 2 §11: diagonal gradient with two
radial glows, schematic device mockups, phase-offset floating platform badges,
staggered text entry, accent page dots, and a gradient CTA. Permission is asked
for on page 4 and nowhere else.

### Phase I — Monetization

`SubscriptionManager` (StoreKit 2, `Transaction.updates` listener started in
`init`, entitlement read from `currentEntitlements` so expiry re-locks) and a
single `EntitlementGate` every gated path routes through — 4K, 60 fps, split
layouts, clean sources, manual controls, watermark. The paywall is contextual,
annual pre-selected, dismissible, with no countdown and no dark pattern.
`Products.storekit` plus a shared scheme make it testable from Xcode's Run
action; `simctl launch` does not apply a scheme's StoreKit configuration, so
product loading is unverified from the command line.

### Three concurrent writers, 1080p30 (Doc 3 Phase 4 task 22)

| Metric | Result | Budget |
|---|---|---|
| Frames appended | 164 (5.48 s × 30) | — |
| Drop rate | **0.000%** | 0.100% |
| Unpaired | **3.66%** | — |
| GPU per frame | **1.89 ms** | 6.00 ms |
| Memory | **81 MB** | 400 MB |

Two more defects, both found only by measuring:

7. **Fresh-install recording delivered 34 frames in 6 s.** The quality
   constraint matrix probed at launch, building ~27 throwaway multi-cam
   sessions and locking every device for configuration *while the live session
   was running*. It now probes when the Quality sheet opens, never at launch
   and never while recording — a one-time per-model cost paid when the user
   asks to see the table.
8. **82% of frames lost their overlay with clean sources on.** The secondary
   stream appended to its clean writer *before* offering the frame to the
   pairer, pushing every secondary frame past the one-frame skew tolerance.
   Ordering is now pairer first, clean writer last, for both roles; and
   `CleanSourceRecorder` releases its lock before appending, so the two capture
   queues no longer serialise against each other.

Still outstanding on hardware: audio sync measurement, pause/resume continuity,
induced thermal load, the 10-minute sustained run, the 5-minute three-writer
run, and StoreKit sandbox flows.

---

## Phase A — Foundation & Capability

**Done when:** the app builds and launches on the iPhone 17 Pro Max simulator, showing the Capability Inspector, which correctly reports "multi-cam unsupported" rather than crashing.

### Tasks
1. Set `IPHONEOS_DEPLOYMENT_TARGET = 17.0`; add the four `INFOPLIST_KEY_NS*UsageDescription` values (Doc 1 §5.4).
2. Create the module tree under `DuoCam/`:
   `App/ · Capture/ · Presentation/ · DesignSystem/ · Domain/ · Persistence/ · Support/`
3. Domain types: `CaptureMode`, `LayoutType`, `StreamRole`, `CaptureConfiguration`, `QualityProfile`, `CameraSource`, `PhotoVideoMode`, `FlashMode`.
4. `Log` — `os.Logger` façade with subsystems `capture · composition · recording · thermal · ui`.
5. `CapabilityProber` — multi-cam support flag, device discovery, `isMultiCamSupported` format enumeration, `hardwareCost` per pairing. Must return an empty-but-valid report in the simulator.
6. `PermissionManager` — camera + mic, four-state, `@MainActor` observable.
7. `CapabilityInspectorView` — plain `List`, debug-gated, permanent.
8. `AppRouter` — root state machine: `launching → onboarding → permissions → camera`.

### Acceptance
- [ ] Builds with zero warnings
- [ ] Launches on iPhone 17 Pro Max sim; Inspector shows "Multi-cam: unsupported (simulator)"
- [ ] Logs categorized correctly
- [ ] ⚠️ HW: Inspector lists ≥1 valid front+rear-wide multi-cam format with `hardwareCost`

---

## Phase B — Design System

**Done when:** every Doc 2 §2 token and §6 component exists as a typed Swift value with a working `#Preview`.

### Tasks
1. **Tokens** — `DC.Color` (accent `#FFD426`, record `#FF3B30`, chrome tiers, scrim), `DC.Font` (8 named styles, monospaced digits), `DC.Radius`, `DC.Spacing` (grid 8, edge 20, control 44, shutter 76).
2. `.dcSurface()` modifier — `.ultraThinMaterial` + 0.5pt white@12% hairline + shadow. **The hairline is non-optional** (Doc 2 §2.4).
3. Reduce Transparency fallback: solid `#1C1C1E` @ 92%.
4. **Components**: `MaterialPill`, `CircularControlButton`, `MorphingShutter`, `CustomSegmentedControl`, `CameraSlider`, `LayoutCard`, `ToastView`, `QualityPill`, `ZoomPillGroup`, `ElapsedTimerPill`.
5. `MorphingShutter` — a **single** `RoundedRectangle` with animatable `size` + `cornerRadius` across all 5 states. Never a cross-fade.
6. `HapticEngine` — semantic API only (`.captureTaken()`, `.snapped()`, `.modeChanged()` …), generators pre-prepared. Doc 2 §10 table is the complete surface.
7. `MotionTokens` — the 8 curves of Doc 2 §9.1, each with a Reduce-Motion alternative resolved at call site.

### Acceptance
- [ ] Every component renders in `#Preview` in both idle and active states
- [ ] Shutter interpolates continuously between all 5 states — no pop
- [ ] Reduce Transparency swaps materials for solids with contrast preserved
- [ ] No raw hex, font size, or `UIImpactFeedbackGenerator` outside `DesignSystem/`

---

## Phase C — Capture Abstraction & Preview

**Done when:** two previews render simultaneously — synthetic in the simulator, real on hardware — through one identical view hierarchy.

### Tasks
1. `CaptureEngine` protocol: lifecycle, per-stream preview provider, focus/expose/zoom, format negotiation, `@Published` negotiated-quality reporting.
2. `SimulatedCaptureEngine` — two `CADisplayLink`-driven animated layers (distinct hues + moving elements so mirroring and swap are visually verifiable).
3. `MultiCamCaptureEngine` — the Doc 3 Phase 1 connection graph, exactly:
   - `addInputWithNoConnections` / `addOutputWithNoConnections`
   - `AVCaptureVideoPreviewLayer(sessionWithNoConnection:)` + explicit `AVCaptureConnection`
   - format filtered by `isMultiCamSupported`, nearest 1920×1080@30
   - `hardwareCost ≤ 1.0` validated, step-down loop, every step logged
   - front mirroring via `automaticallyAdjustsVideoMirroring = false`
   - rotation via `AVCaptureDevice.RotationCoordinator` → `videoRotationAngle`
4. `CameraPreviewView: UIViewRepresentable` over a `UIView` whose `layerClass` is the preview layer.
5. Scene-phase lifecycle; interruption / interruption-ended handling.
6. All session mutation on one dedicated serial queue; capture layer actor-isolated; UI `@MainActor`.

### Acceptance
- [ ] Sim: two distinct animated previews, correct geometry, correct mirroring semantics
- [ ] Backgrounding → foregrounding restores previews < 500 ms
- [ ] ⚠️ HW: both live, front mirrored, rotation correct, `hardwareCost ≤ 1.0` logged
- [ ] ⚠️ HW: 10-min idle preview — no memory growth, thermal ≤ `.fair`

---

## Phase D — Interface & Interaction  *(largest phase)*

**Done when:** Document 2 is implemented end to end and every prototype problem P1–P8 is verifiably fixed.

### D1 — Layout Geometry *(before the overlay — this is what fixes P1)*
`LayoutGeometry` as the **single source of truth**: screen bounds, safe insets, top/bottom/mode-selector frames, 8 snap-zone base positions, and `resolvedPosition(for:)` with control-aware displacement (`minimumClearance: 12`). Recomputed on rotation, safe-area, mode, recording-state, and sheet changes. Unit-tested.

### D2 — Screen architecture
Full-bleed preview (`ignoresSafeArea(.all)`), the two gradient scrims (120pt top @25%, 180pt bottom @35%), z-stack 0→70 per Doc 2 §3.1. **Fixes P5.**

### D3 — Idle chrome (two tiers, not three — **fixes P3**)
Top: quality pill (live-negotiated values — honest reporting), control trio, conditional overlay-rotate. Bottom tier 1: gallery thumb · shutter · swap · layout. Bottom tier 2: mode selector. Zoom pills 84pt above shutter, auto-hide 4s. Chrome auto-hide 6s → 30% opacity.

### D4 — Floating overlay
Velocity-projected magnetic snap (`velocity * 0.15`, `interpolatingSpring(220, 24)`), lift to 1.06 + shadow 24 during drag, 8 dashed zone guides with accent highlight on nearest, pinch-resize 25–50% with detent haptics, double-tap swap via `matchedGeometryEffect`. 20pt continuous radius + 3pt white@90% stroke + ambient shadow. **Fixes P7.** Position/size persisted per layout type.

### D5 — Split layouts
Divider handle (4pt line + 36×5pt grab pill), 30–70% range, **rigid detent at exactly 50%**, double-tap to swap sides, auto-hide 3s / ±40pt reappear. Diagonal seam −30°…+30° with 0° detent.

### D6 — Recording state
The 7-part 0.4s transition of Doc 2 §7.1, including the clockwise-drawing 1.5pt red screen border (animated `trim`). Elapsed timer with 1Hz pulsing dot. Left control stack (pause · adjustments · torch · audio meter). Still-during-video. Pause state (yellow border, `PAUSED` label, pulsing shutter).

### D7 — Sheets
Adjustments (stream selector + 5 sliders, live-applied), Layout (5 schematic cards, sheet stays open, preview dimmed only 15% — **fixes P2**), Quality (unavailable options greyed **with inline reason**, never hidden).

### D8 — Gestures
The complete Doc 2 §8 map, with a written resolution order for every overlap. Tap-to-focus reticle (1.3→1.0 + pulse, 2s fade) → vertical-drag exposure. Long-press AE/AF lock. Photo/Video by shutter swipe — **fixes P4** (one shutter, never two).

### D9 — Motion
Blur-masked reconfiguration transition (last frame → 0→20pt progressive blur over 0.2s → 0.25s cross-fade + 1.0→1.04→1.0 scale). **Never a black frame.** Layout transitions as geometry+radius+clip-shape interpolation. Full Reduce Motion alternates — motion degrades, haptics never do.

### Acceptance
- [ ] Overlay reaches all 8 zones and covers a control in **none** of them
- [ ] Flick carries further than a slow drag
- [ ] Shutter morph, layout morph, mode blur — no pop, no cut, no black frame
- [ ] Every Doc 2 §8 gesture works; no two gestures collide in one context
- [ ] Every Doc 2 §10 haptic fires at the right instant
- [ ] Renders correctly at both size extremes
- [ ] Reduce Motion + Reduce Transparency both fully honored
- [ ] P1–P8 each demonstrably resolved

---

## Phase E — Recording Core & Thermal Governor  ⚠️ HW

Metal compositor (`CVMetalTextureCache`, `CVPixelBufferPool`, layout-as-uniform), PTS-paired frame sync with 1-frame skew tolerance, `AVAssetWriter` (HEVC, `startSession(atSourceTime:)` with first PTS), pause/resume via accumulated-offset timestamps, single audio input + `AVAudioSession` data-source direction, the 5-step degradation ladder (never degrades upward mid-take), SwiftData `Capture` model + thumbnails, storage pre-flight (100 MB refuse / 500 MB warn).

---

## Phase F — Complete Capture Feature Set

Photo in all modes (paired by timestamp, same Metal layout engine), burst, self-timer, `Rear + Rear` (hidden when unsupported, never disabled), all 5 layouts as compositor uniforms, live layout switch **during** recording, per-stream lens picker, ramped pinch zoom, manual ISO/shutter/WB/focus, torch + screen-flash, grid + level, clean source writers (degrade these first, never the composite).

---

## Phase G — Quality Tiers & Performance  ⚠️ HW

Live constraint matrix (resolution × fps × mode × device) cached per model, Quality-sheet reasons traceable to the real blocking constraint, zero per-frame allocations, triple-buffered pool, GPU < 6 ms @ 4K, memory < 400 MB, memory-pressure observer, debug performance HUD, device-matrix validation.

---

## Phase H — Review, Export & Onboarding

Gallery `LazyVGrid` 3×2pt with async cached thumbnails and badges, matched-geometry zoom detail, rubber-banded swipe dismiss, context menu, multi-select. Trim + 4 export presets + free-tier watermark (export-time only, never capture-time), Photos album, `ShareLink`, cancellable determinate progress. Four-page onboarding with gradient background, phase-offset floating platform badges, parallax, staggered text; page 4 requests permission. Permission-denied recovery with Settings deep link; mic denial non-blocking. Full Settings list, all preferences persisted.

---

## Phase I — Monetization & Release

StoreKit 2 `SubscriptionManager` + a single `EntitlementGate` service (**never scatter entitlement checks into views**), contextual paywall (annual pre-selected, no dark patterns), restore, full sandbox matrix, App Store assets and privacy questionnaire.

---

## Standing Engineering Rules  *(Doc 3 cross-phase — apply from Phase A)*

1. Session mutation: one dedicated serial queue, never main. Sample-buffer delegates on their own queues.
2. Capture layer actor-isolated; view models `@MainActor`.
3. No `try!`, no force-unwrap in the capture layer. Every failure is typed and degrades — a dead secondary stream falls back to Single mode with a toast, never a crash.
4. **Never hard-code a format.** Enumerate `isMultiCamSupported` at runtime, every device, every mode.
5. Validate `hardwareCost` after every configuration change; recover with the ladder, not a dialog.
6. Geometry has exactly one source of truth (`LayoutGeometry`). Duplicating it is how P1 returns.
7. Never cut between camera states — every reconfiguration is blur-masked.
8. Report quality honestly — the pill shows what was *achieved*, immediately.
9. Tests: geometry/snap/collision, degradation ladder, pause-resume timestamps, entitlement gating.
10. Any deviation from Docs 1–2 is recorded in §"Deviation Log" below with its rationale.

---

## Deviation Log

| # | Deviation | Rationale |
|---|---|---|
| D-1 | Capture behind `CaptureEngine` with a `SimulatedCaptureEngine` sibling | Multi-cam cannot run in the simulator; without this, zero UI work is iteratively verifiable. Hardware criteria still gate capture phases. |
| D-2 | Interface (Doc 3 Ph3) built before Recording Core (Doc 3 Ph2) | Interface is fully sim-verifiable, recording is not. Doc 3's real ordering constraint — governor before 4K — is preserved. |
| D-3 | Elapsed timer sits on its own centred row *below* the top control row, not inside it (Doc 2 §4.2 places it in the row's horizontal centre) | At 440pt the quality pill + control trio + conditional overlay-rotate control leave under 60pt of centre; a 90pt timer pill drawn there renders behind the controls. Design principle 4 — "nothing important is ever covered" — outranks the literal placement, and Doc 2 §1 says to resolve conflicts by principle order. Still top, still centred. `LayoutGeometry.topClusterFrame` grows to match so snap zones avoid the timer too. |
| D-4 | Dynamic Type in camera chrome capped at `.accessibility1`, not "`.accessibilityMedium`" (Doc 2 §14) | That name has no `DynamicTypeSize` equivalent — the API offers `.accessibility1`…`.accessibility5`. The chrome's control sizes are fixed at 44–76pt and overflow above AX1. Sheets, Settings, Gallery and Onboarding stay uncapped, as Doc 2 requires. |
| D-5 | `SimulatedCaptureEngine` advertises all three capture modes | On hardware the mode list is the capability report and nothing else, per Doc 2 §4.3. The simulated engine genuinely *can* run two synthetic streams, so all three are real capabilities of that engine — hiding them would make the dual-stream interface unreviewable in the simulator. |
| D-6 | `.builtInUltraWideCamera`, not Doc 1 §5.3.5's `.builtInUltraWideAngleCamera` | The latter symbol does not exist in AVFoundation. |
