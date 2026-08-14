# DualCam — UI/UX Specification

> **Document 2 of 3** · Complete interface, motion, and interaction specification
> **Audience:** AI development agent, iOS engineers, designers
> **Design language:** Native iOS 17+ (SwiftUI + UIKit interop)

---

## 1. Design Principles

These five principles resolve every ambiguity in this document. When two rules appear to conflict, apply them in this order.

**1. The preview is the interface.** Chrome floats on top of a full-bleed camera feed. There are no opaque bars, no letterboxing, no reserved rectangles that permanently cover the image. Every control uses translucent material so the user can always see what they are shooting.

**2. One primary action, always visible.** The shutter is the only element that is never hidden, never moved, and never ambiguous. Everything else can be dismissed, collapsed, or auto-hidden.

**3. Progressive disclosure.** The idle screen shows six controls. Everything else lives one deliberate gesture away — a tap on a disclosure control, a swipe, or a long press. A first-time user should be able to record without understanding any icon except the shutter.

**4. Nothing important is ever covered.** The floating overlay, the layout sheet, and the mode selector must never obscure the shutter, the elapsed-time readout, or an active control. This directly addresses prototype problems P1 and P2.

**5. Every state change is animated and felt.** No element appears, disappears, or moves instantly. Every discrete state change carries a haptic. Motion communicates causality; haptics confirm it.

---

## 2. Design System

### 2.1 Color

The app runs in permanent dark appearance. The camera feed provides all color; chrome is monochrome with a single accent.

| Token | Value | Usage |
|---|---|---|
| `accent` | `#FFD426` (System Yellow) | Active states, selected mode, recording-adjacent affordances |
| `record` | `#FF3B30` (System Red) | Record button fill, recording indicator dot |
| `chromePrimary` | `#FFFFFF` @ 100% | Icons, primary labels |
| `chromeSecondary` | `#FFFFFF` @ 60% | Inactive labels, secondary text |
| `chromeTertiary` | `#FFFFFF` @ 35% | Disabled controls |
| `surface` | `.ultraThinMaterial` | Control containers, pills, sheets |
| `surfaceElevated` | `.regularMaterial` | Modal sheets, settings panels |
| `scrim` | `#000000` @ 40% | Behind text when material is unavailable |

Yellow accent is chosen deliberately over blue: it is the accent used in the reference prototype, reads clearly against every camera scene, and does not compete with the red record state.

### 2.2 Typography

All type uses **SF Pro**. Camera UI favors rounded and monospaced variants for numeric readouts.

| Style | Font | Size | Weight | Usage |
|---|---|---|---|---|
| `timerLarge` | SF Mono | 17pt | Semibold | Elapsed recording time |
| `pillLabel` | SF Pro Rounded | 13pt | Semibold | `4K`, `30 FPS`, `1x` |
| `pillCaption` | SF Pro Rounded | 10pt | Medium | `RES`, `FPS` suffixes |
| `modeLabel` | SF Pro | 15pt | Semibold | Mode selector segments |
| `sheetTitle` | SF Pro | 17pt | Semibold | Sheet headers |
| `sheetBody` | SF Pro | 15pt | Regular | Sheet content |
| `onboardTitle` | SF Pro | 34pt | Bold | Onboarding headlines |
| `onboardBody` | SF Pro | 17pt | Regular | Onboarding subtitles |

All numeric readouts use monospaced digits (`.monospacedDigit()`) so values do not shift horizontally as they change.

### 2.3 Geometry

| Token | Value |
|---|---|
| `radiusPill` | Fully rounded (height / 2) |
| `radiusOverlay` | 20pt, continuous curve |
| `radiusSheet` | 28pt, continuous curve, top corners only |
| `radiusButton` | Fully rounded |
| `strokeOverlay` | 3pt, white @ 90% |
| `gridUnit` | 8pt |
| `edgeMargin` | 20pt |
| `controlSize` | 44pt diameter (minimum tap target) |
| `shutterSize` | 76pt outer ring, 64pt inner |

Corners use `RoundedRectangle(cornerRadius:style: .continuous)` throughout. Never use the default circular style — continuous curvature is what makes an interface read as iOS-native.

### 2.4 Materials and Depth

Every floating control sits in a `.ultraThinMaterial` container with a subtle border and shadow:

```swift
.background(.ultraThinMaterial, in: Capsule())
.overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
.shadow(color: .black.opacity(0.25), radius: 8, y: 2)
```

The 0.5pt white hairline border is critical. Without it, material containers disappear against bright camera scenes.

### 2.5 Iconography

All icons are **SF Symbols**, weight `.medium`, rendering mode `.hierarchical` for inactive and `.palette` for active states.

| Function | Symbol | Notes |
|---|---|---|
| Settings | `gearshape` | Top-right |
| Adjustments | `slider.horizontal.3` | Opens exposure/ISO/WB sheet |
| Flash off | `bolt.slash` | |
| Flash on | `bolt.fill` | Tint accent when on |
| Flash auto | `bolt.badge.a` | |
| Rotate overlay | `rectangle.portrait.rotate` | Toggles overlay aspect |
| Layout picker | `rectangle.split.2x1` | Opens layout sheet |
| Swap cameras | `arrow.triangle.2.circlepath.camera` | Bottom-right |
| Gallery | Live thumbnail | Bottom-left, not a symbol |
| Grid | `grid` | In settings sheet |
| Timer | `timer` | In settings sheet |
| Torch | `flashlight.on.fill` | |
| Pause | `pause.fill` | Recording state only |
| Resume | `record.circle` | Recording state only |

---

## 3. Screen Architecture

### 3.1 Layer Stack

Rendered back to front:

```
z=0   Camera preview (full bleed, ignores all safe areas)
z=10  Composition layer — split divider, seam handles
z=20  Floating overlay (PiP) — draggable, resizable
z=30  Focus reticle, exposure slider, zoom feedback (transient)
z=40  Top control cluster
z=50  Bottom control cluster
z=60  Layout sheet / adjustments sheet (modal, dims z=40–50)
z=70  Toasts, permission prompts, thermal warnings
```

### 3.2 Full-Bleed Rule

**The camera preview extends to every physical edge of the display**, including behind the Dynamic Island, the status bar, and the home indicator. This corrects prototype problem P5, where opaque black bars consumed roughly 25% of the screen.

Legibility over bright scenes is achieved by material containers on the controls themselves, not by darkening the preview. A gradient scrim is applied only in two narrow bands:

- Top: `LinearGradient(black@25% → clear)`, 120pt tall
- Bottom: `LinearGradient(clear → black@35%)`, 180pt tall

These gradients are subtle enough to be invisible on most scenes but guarantee icon contrast on white backgrounds.

### 3.3 Safe Area Handling

```swift
CameraPreview()
    .ignoresSafeArea(.all)

ControlsOverlay()
    .safeAreaPadding(.all)   // respects Island + home indicator
```

The top control cluster begins **8pt below** the safe area top inset. The bottom cluster ends **12pt above** the safe area bottom inset. On devices with a Dynamic Island the top cluster is centered in the horizontal band beside it, never underneath.

---

## 4. Idle State — Control Placement

The idle state is the app's resting appearance: camera live, nothing recording.

### 4.1 Layout Map

```
┌─────────────────────────────────────────────┐
│  ╭──────────────╮        ╭──╮ ╭──╮ ╭──╮    │  ← Top cluster
│  │ 4K RES 30FPS │        │⚙︎ │ │⚡︎│ │≡ │    │    (y = safeTop + 8)
│  ╰──────────────╯        ╰──╯ ╰──╯ ╰──╯    │
│                                             │
│                              ┌───────────┐  │
│                              │           │  │  ← Floating overlay
│                              │  OVERLAY  │  │    (default: top-right)
│                              │           │  │
│                              └───────────┘  │
│                                             │
│                                             │
│            PRIMARY CAMERA PREVIEW           │
│                                             │
│                                             │
│                                             │
│            ╭───────────────────╮            │  ← Zoom pills
│            │ 0.5x  1x  2x  3x  │            │    (y = shutter - 84)
│            ╰───────────────────╯            │
│                                             │
│  ╭────╮   ╭─────────╮   ╭────╮   ╭────╮    │  ← Primary control row
│  │ 🖼 │   │  ◉ SHUT │   │ ⇄  │   │ ▤  │    │
│  ╰────╯   ╰─────────╯   ╰────╯   ╰────╯    │
│                                             │
│     ╭─────────────────────────────────╮     │  ← Mode selector
│     │ Front+Back │ Rear+Rear │ Single │     │
│     ╰─────────────────────────────────╯     │
└─────────────────────────────────────────────┘
```

This is **two tiers**, not three — correcting prototype problem P3. The layout picker is no longer a permanent row; it opens as a sheet from the `▤` control.

### 4.2 Top Cluster — Detailed

**Left: Quality pill**

- Content: `4K` in `pillLabel` + `RES` in `pillCaption` + vertical divider + `30` + `FPS`
- Container: capsule, `.ultraThinMaterial`, height 34pt, horizontal padding 14pt
- Position: `x = edgeMargin`, aligned left
- Tap: opens the Quality sheet (§6.4)
- Live-updating: reflects the *actual* negotiated format, not the requested one. If the user asks for 4K and hardware cost forces 1080p, this pill shows `1080p` immediately. Honest reporting is a product pillar.

**Right: Control trio**, spaced 12pt apart, right-aligned at `edgeMargin`

| Position | Control | Behavior |
|---|---|---|
| Rightmost | Settings `gearshape` | Pushes the full Settings screen |
| Middle | Flash `bolt.slash` / `bolt.fill` / `bolt.badge.a` | Cycles Off → On → Auto on tap; long-press opens torch slider |
| Left | Adjustments `slider.horizontal.3` | Opens the Adjustments sheet (§6.2) |

**Conditional fourth control:** when a PiP layout is active, `rectangle.portrait.rotate` appears to the left of Adjustments. It toggles the overlay between portrait and landscape aspect. It is not shown in split layouts because it has no meaning there.

**Center (recording only):** the elapsed-time readout replaces nothing; it occupies the horizontal center of the top cluster, which is empty in the idle state.

### 4.3 Bottom Cluster — Detailed

**Tier 1 — Primary control row**, `y = safeBottom - 12 - 76` (shutter height)

| Position | Control | Size | Behavior |
|---|---|---|---|
| `x = edgeMargin` | Gallery thumbnail | 48pt, radius 12pt continuous | Shows last capture; tap opens Gallery. Empty state: `photo.on.rectangle` glyph. |
| Center | **Shutter** | 76pt | See §6.1 |
| `x = center + 84` | Swap cameras | 48pt | Swaps primary and secondary sources |
| `x = width - edgeMargin - 48` | Layout picker `▤` | 48pt | Opens the Layout sheet |

A zoom pill group floats 84pt above the shutter, horizontally centered. It shows the available lens stops for the current primary camera (e.g. `0.5x · 1x · 2x`). The active stop is filled with `accent`; the others use `.ultraThinMaterial`. This group **auto-hides after 4 seconds of no interaction** and reappears on any pinch or tap in the preview area.

**Tier 2 — Mode selector**, `y = safeBottom - 12`

A custom segmented control, 44pt tall, capsule shape, `.ultraThinMaterial` background. Segments: `Front + Back` · `Rear + Rear` · `Single`. The selected segment is a filled `accent` capsule with black text; unselected segments use `chromeSecondary` text.

The selection indicator animates between positions with a spring, and the whole control supports a horizontal swipe gesture that advances the selection — matching iOS Camera's mode wheel behavior.

Unsupported modes are not displayed. On a device without a usable ultra-wide, `Rear + Rear` is absent, not disabled — a disabled control that can never be enabled is noise.

### 4.4 Photo / Video Sub-Mode

Photo versus Video is **not** a separate row. It is a swipe on the shutter area, mirroring the system Camera app:

- Swipe **left** on the shutter region → Photo
- Swipe **right** on the shutter region → Video

The shutter morphs to communicate state (§6.1). A small label above the shutter (`PHOTO` / `VIDEO`, 11pt, `chromeSecondary`, letter-spaced) appears for 1.2s after a mode change, then fades. This eliminates the prototype's two-shutter ambiguity (problem P4).

---

## 5. The Floating Overlay (PiP)

The overlay is the app's signature element. Its behavior must feel physical.

### 5.1 Default Placement and Size

- Default position: **top-right snap zone**
- Default size: **32% of screen width**
- Aspect ratio: matches the layout type (`pipRounded` = 3:4, `pipTall` = 9:16, `pipCircle` = 1:1)
- Position and size persist across app launches per layout type

### 5.2 Visual Treatment

```swift
.clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
.overlay(
    RoundedRectangle(cornerRadius: 20, style: .continuous)
        .strokeBorder(.white.opacity(0.9), lineWidth: 3)
)
.shadow(color: .black.opacity(0.35), radius: 16, y: 6)
```

The 3pt white stroke plus ambient shadow is what separates a polished overlay from the prototype's hard-cornered rectangle (problem P7). The shadow is what tells the eye this element floats *above* the scene rather than being punched into it.

For `pipCircle`, replace the shape with `Circle()` and keep the same stroke and shadow.

### 5.3 Drag Interaction

The drag must use **velocity-projected magnetic snapping**, not simple release-position snapping.

```swift
// On drag change
offset = dragStart + translation
// live: highlight the nearest snap zone with a 2pt accent outline

// On drag end
let projected = currentPosition + (velocity * 0.15)
let target = nearestSnapZone(to: projected)
withAnimation(.interpolatingSpring(stiffness: 220, damping: 24)) {
    position = target
}
```

The 0.15 velocity multiplier means a quick flick carries the overlay across the screen while a slow drag settles where released. This is the same feel as iOS's own PiP video window.

**During drag:**
- Overlay scales to `1.06` and shadow radius increases to 24 — it lifts off the surface
- All eight snap zones render as faint 1pt dashed outlines at 20% opacity
- The nearest zone brightens to a 2pt solid `accent` outline
- Haptic: `.impact(.light)` when the nearest zone changes

**On release:**
- Spring to target, scale back to `1.0`
- Haptic: `.impact(.medium)`
- Snap-zone guides fade out over 0.2s

### 5.4 Snap Zones and Control Avoidance

Eight zones: four corners plus four edge-midpoints. Each is inset by `edgeMargin` from the screen edge.

**This is the fix for prototype problem P1.** Each snap zone computes its final position by subtracting the bounding rect of any active control cluster:

```swift
func resolvedPosition(for zone: SnapZone) -> CGPoint {
    var point = zone.basePosition(in: screenBounds, overlaySize: size)
    let obstacles = [topClusterFrame, bottomClusterFrame, modeSelectorFrame]
    for obstacle in obstacles where obstacle.intersects(overlayRect(at: point)) {
        // push perpendicular to the shorter overlap axis
        point = displace(point, awayFrom: obstacle, minimumClearance: 12)
    }
    return point
}
```

Result: the top-right snap zone lands **below** the settings/flash/adjustments trio, not on top of it. The overlay can never make a control untappable.

Zone bounds are recomputed whenever a control cluster's frame changes (mode switch, recording state change, sheet presentation).

### 5.5 Resize

Pinch on the overlay resizes it between 25% and 50% of screen width.

- The overlay's snap-zone anchor is preserved during resize (a top-right overlay grows down and left)
- Haptic: `.impact(.rigid)` at each 5% boundary
- Haptic: `.impact(.heavy)` at the 25% and 50% limits
- Scale animates with `.interactiveSpring()` so it tracks the fingers precisely

### 5.6 Swap Gesture

**Double-tap the overlay** swaps primary and secondary streams.

The transition is a shared-geometry crossfade, not a cut:

```swift
withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
    // overlay content scales up to fill the screen
    // primary content scales down into the overlay frame
}
```

Both streams remain live throughout — this is a pure presentation change, so there is no camera reconfiguration and no interruption. Haptic on completion: `.impact(.medium)`.

The same swap is available from the `⇄` control in the bottom row, and it works identically during recording.

### 5.7 Split Layouts

For `splitHorizontal` and `splitDiagonal`, the overlay is replaced by a **divider handle**:

- A 4pt line at 50% opacity with a 36×5pt rounded grab pill centered on it
- Draggable between 30% and 70% of screen height
- **Detent at exactly 50%** — a `.impact(.rigid)` haptic and a brief 2pt accent flash when crossing it
- Double-tap the divider swaps which stream is on top
- The handle auto-hides after 3s of inactivity and reappears on touch anywhere near the divider (±40pt)

For `splitDiagonal`, an additional rotation handle at the divider's midpoint adjusts the seam angle between −30° and +30°, with a detent at 0°.

---

## 6. Component Specifications

### 6.1 The Shutter

A single morphing element. This replaces the prototype's dual red/white buttons entirely.

**Structure:** an outer ring (76pt, 4pt white stroke) containing an inner shape.

| State | Inner shape | Fill | Animation into state |
|---|---|---|---|
| Photo idle | Circle, 64pt | White | — |
| Photo pressed | Circle, 56pt | White @ 80% | 0.08s ease-out |
| Video idle | Circle, 64pt | `record` red | Morph 0.3s spring |
| Video recording | Rounded square, 32pt, radius 8pt | `record` red | Morph 0.35s spring |
| Video paused | Rounded square, 32pt, radius 8pt | `record` red @ 50%, pulsing | Opacity pulse, 1.4s loop |
| Disabled | Circle, 64pt | `chromeTertiary` | 0.2s fade |

The circle→square morph is implemented as an animatable `cornerRadius` and `size` on a single `RoundedRectangle`, so it interpolates continuously rather than cross-fading between two views.

**Interactions:**
- Tap: capture photo / start-stop recording
- Long press in Photo mode: burst capture, with the ring filling clockwise as a progress indicator
- Long press in Video mode from idle: quick-record — records while held, stops on release (matching iOS Camera)
- Swipe left/right: change Photo/Video sub-mode (§4.4)

**Haptics:**
- Photo capture: `.impact(.medium)`
- Recording start: `.notification(.success)`
- Recording stop: `.impact(.heavy)`
- Recording pause: `.impact(.light)`

### 6.2 Adjustments Sheet

Presented via `.sheet` with `.presentationDetents([.height(280), .medium])` and `.presentationBackground(.regularMaterial)`.

Because there are two live streams, the sheet's first row is a **stream selector segment**: `Primary` · `Secondary`. All controls below apply to the selected stream.

Controls, vertically stacked:

| Control | Type | Range |
|---|---|---|
| Exposure | Horizontal slider with center detent at 0 | −2.0 to +2.0 EV |
| ISO | Horizontal slider, `AUTO` toggle at the left end | Device min–max |
| Shutter | Horizontal slider, `AUTO` toggle | Device min–max |
| White balance | Horizontal slider + preset chips (`AWB`, `☀︎`, `☁︎`, `💡`, `🌙`) | 2000K–8000K |
| Focus | Horizontal slider, `AF` toggle | 0.0–1.0 |

Each slider uses a custom track: 4pt height, `chromeTertiary` background, `accent` filled portion, 28pt circular knob with a shadow. Sliders emit `.impact(.light)` on crossing their detent and display their numeric value in a small pill above the knob while dragging.

A `Reset` button at the bottom returns all values to auto with a `.notification(.success)` haptic.

### 6.3 Layout Sheet

**This is the fix for prototype problem P2.** The five layout options no longer float in the middle of the screen over the subject's face. They live in a sheet presented from the `▤` control, with detent `.height(200)`, anchored at the bottom.

Content: a horizontal row of five layout cards, each 72×88pt.

Each card contains a **schematic diagram** of the layout — a rounded rectangle representing the screen with a smaller filled shape showing where the secondary stream sits — plus a caption below (`PiP` · `Tall` · `Circle` · `Split` · `Diagonal`).

- Selected card: `accent` 2pt border, `accent` @ 15% fill, caption in `accent`
- Unselected: `chromeTertiary` 1pt border, caption in `chromeSecondary`
- Tap: applies the layout immediately with a live animated transition (the sheet stays open so the user can compare)
- Haptic on selection: `.selection()`

The sheet dims the camera preview by only 15% — the user must be able to see the effect of each layout while choosing.

**Layout transition animation:** switching between layouts never cuts. The secondary stream's frame animates from its old geometry to its new geometry with `.spring(response: 0.5, dampingFraction: 0.8)`, and its corner radius and clip shape interpolate simultaneously. Going from `pipCircle` to `splitHorizontal`, for example, shows the circle growing and squaring off into the bottom half of the screen.

### 6.4 Quality Sheet

Presented from the quality pill. Detent `.height(320)`.

| Section | Options |
|---|---|
| Resolution | `4K` · `1080p` · `720p` |
| Frame rate | `24` · `30` · `60` |
| Codec | `HEVC` · `H.264` |
| Save clean sources | Toggle |
| Stabilization | `Off` · `Standard` · `Cinematic` (multi-cam availability varies) |

**Critical behavior:** options that are unavailable in the current mode are shown **greyed with an inline reason**, not hidden. Example: `4K — unavailable in Rear + Rear on this device`. This teaches the user the real constraints instead of leaving them confused. When the user taps a greyed option, a toast explains and offers to switch to Single mode if that would enable it.

The available set is queried live from `AVCaptureDevice.formats` filtered by `isMultiCamSupported`, then validated against `session.hardwareCost`. Never hard-code.

### 6.5 Toasts

A single toast slot at `y = safeTop + 60`, horizontally centered.

- Capsule, `.regularMaterial`, 44pt tall, max width 320pt
- Optional leading SF Symbol, then 15pt text
- Enters: slide down 20pt + fade, `.spring(response: 0.4, dampingFraction: 0.8)`
- Exits after 2.5s: fade + slide up 12pt, 0.25s
- Swipe up to dismiss early
- Queued, never stacked — a new toast replaces the current one with a crossfade

Toast triggers: quality auto-reduced, thermal warning, low storage, recording saved, permission denied, mode unsupported.

---

## 7. Recording State

Recording is a visually distinct state, not a small badge change. This follows the competitor pattern observed in the reference screenshots.

### 7.1 State Transition (Idle → Recording)

Over 0.4 seconds, simultaneously:

1. Shutter morphs circle → rounded square
2. Mode selector slides down and fades out (it is not changeable during recording)
3. Quality pill fades to 50% opacity and becomes non-interactive
4. Elapsed timer fades in at the top-center
5. A 1.5pt `record` red border draws around the entire screen edge, inset 2pt, animating in clockwise from the top-center over 0.5s
6. The secondary control stack slides in from the left edge
7. Haptic: `.notification(.success)`

### 7.2 Recording-Only Elements

**Elapsed timer** — top-center, `MM:SS` in `timerLarge` monospaced, preceded by a 8pt `record` red dot that pulses at 1Hz (opacity 1.0 → 0.4 → 1.0, ease-in-out). Container: capsule, `.ultraThinMaterial`, height 32pt.

**Left control stack** — vertical column at `x = edgeMargin`, vertically centered, 12pt spacing, each control 44pt:

| Control | Function |
|---|---|
| `pause.fill` / `record.circle` | Pause and resume within the same output file |
| `slider.horizontal.3` | Adjustments sheet (live-applied) |
| `flashlight.on.fill` | Torch toggle |
| `waveform` | Audio level meter — tap to mute, shows live input level as an animated bar |

This stack mirrors the pattern seen in the reference competitor screenshots, where recording-time controls occupy a screen edge rather than the bottom bar.

**Still-during-video** — the gallery thumbnail position is replaced by a small white circle (40pt) that captures a full-resolution still without interrupting the recording. Haptic: `.impact(.light)`, plus a 0.1s white screen flash at 30% opacity.

### 7.3 What Remains Available During Recording

- Layout switching (via `▤`, live transition, no interruption)
- Primary/secondary swap (via `⇄` or overlay double-tap)
- Overlay drag and resize
- Zoom (pinch and pill taps)
- Tap to focus
- Adjustments

### 7.4 What Is Disabled During Recording

- Mode selector (hidden entirely)
- Quality sheet (pill dimmed, tapping shows a toast: *"Stop recording to change quality"*)
- Gallery access
- Photo/Video swipe

### 7.5 Pause State

- Shutter fills pulse between 100% and 50% opacity, 1.4s loop
- Timer stops but stays visible; the red dot stops pulsing and holds at 40%
- Screen border changes from `record` red to `accent` yellow
- A `PAUSED` label (11pt, letter-spaced, `accent`) appears below the timer

---

## 8. Gesture Vocabulary

Complete map. No gesture may be assigned two meanings in the same context.

| Gesture | Target | Action |
|---|---|---|
| Tap | Preview | Focus + expose at point |
| Tap | Overlay | Focus + expose on secondary stream |
| Double-tap | Overlay | Swap primary / secondary |
| Double-tap | Preview (outside overlay) | Toggle chrome visibility |
| Long press | Preview | Lock AE/AF — reticle turns `accent`, `AE/AF LOCK` label appears |
| Pinch | Preview | Continuous zoom on primary |
| Pinch | Overlay | Resize overlay |
| Drag | Overlay | Reposition with magnetic snap |
| Drag | Split divider | Adjust split ratio |
| Vertical drag | After tap-to-focus | Exposure compensation (sun icon slides along a vertical track) |
| Swipe left/right | Shutter region | Photo ↔ Video |
| Swipe left/right | Mode selector | Cycle capture mode |
| Swipe up | Preview (from bottom edge) | Open Gallery |
| Swipe down | Any sheet | Dismiss |
| Long press | Flash icon | Torch brightness slider |
| Long press | Shutter (Video, idle) | Quick-record while held |
| Long press | Shutter (Photo) | Burst capture |
| Long press | Gallery thumbnail | Quick-look preview of last capture |

**Chrome auto-hide:** after 6 seconds with no interaction in the idle state, the quality pill and zoom pills fade to 30% opacity. Any touch restores them instantly. The shutter, mode selector, and control row never fade.

---

## 9. Motion Specification

### 9.1 Animation Curves

| Purpose | Curve |
|---|---|
| Standard UI transition | `.spring(response: 0.4, dampingFraction: 0.8)` |
| Layout transition | `.spring(response: 0.5, dampingFraction: 0.8)` |
| Overlay snap | `.interpolatingSpring(stiffness: 220, damping: 24)` |
| Gesture tracking | `.interactiveSpring(response: 0.2, dampingFraction: 0.85)` |
| Sheet present/dismiss | System default (do not override) |
| Micro-feedback (press) | `.easeOut(duration: 0.08)` |
| Fade in/out | `.easeInOut(duration: 0.25)` |
| Shutter morph | `.spring(response: 0.35, dampingFraction: 0.7)` |

### 9.2 Camera Transition Handling

Any operation that reconfigures the capture session (mode switch, resolution change) produces a brief black frame. This must be masked:

1. Capture the last preview frame into an image
2. Apply a progressive blur (0 → 20pt radius) over 0.2s while the session reconfigures
3. Cross-fade from the blurred still to the new live preview over 0.25s

The user perceives a smooth focus-pull rather than a flicker. This is the single highest-impact polish item in the app.

Additionally, on mode switch, apply a subtle scale (`1.0 → 1.04 → 1.0`) to the preview container. The combination of blur and scale reads as a lens change rather than a software reload.

### 9.3 Reduce Motion

When `UIAccessibility.isReduceMotionEnabled`:

- Springs become `.easeInOut(duration: 0.2)`
- The overlay snaps without a scale-lift
- Layout transitions cross-fade instead of morphing geometry
- The screen recording border appears instantly rather than drawing in
- All haptics remain — motion reduction must not remove feedback

---

## 10. Haptic Specification

Haptics are part of the interface, not decoration. Use `UIImpactFeedbackGenerator` and `UINotificationFeedbackGenerator`, with generators pre-prepared before gesture start to avoid latency.

| Event | Feedback |
|---|---|
| Photo captured | `.impact(.medium)` |
| Recording started | `.notification(.success)` |
| Recording stopped | `.impact(.heavy)` |
| Recording paused / resumed | `.impact(.light)` |
| Overlay snap-zone change (during drag) | `.impact(.light)` |
| Overlay released into zone | `.impact(.medium)` |
| Overlay resize boundary (5% steps) | `.impact(.rigid)` |
| Overlay resize limit reached | `.impact(.heavy)` |
| Primary/secondary swap | `.impact(.medium)` |
| Layout selected | `.selection()` |
| Mode changed | `.selection()` |
| Split divider crosses 50% | `.impact(.rigid)` |
| Slider detent crossed | `.impact(.light)` |
| Focus locked (long press) | `.impact(.rigid)` |
| Error / unsupported action | `.notification(.error)` |
| Thermal warning | `.notification(.warning)` |
| Toast appeared | none |

---

## 11. Onboarding

Four full-screen pages in a horizontally paged `TabView`, matching the visual pattern in the reference screenshots.

### 11.1 Visual Template

- Background: diagonal `LinearGradient` from `#1E1B4B` (top-left) to `#7C1D6F` (bottom-right), with two large soft radial glows at 15% opacity for depth
- A device mockup occupies the upper 60% of the screen, showing a real captured result for that page's concept
- Floating platform badges (TikTok, YouTube, Instagram) at 56pt with a soft shadow, positioned asymmetrically around the mockup, each with an independent slow float animation (±6pt vertical, 3–4s period, offset phases)
- Headline in `onboardTitle`, centered
- Subtitle in `onboardBody`, centered, two lines maximum, `chromeSecondary`
- Page dots below the subtitle: 8pt circles, 10pt spacing, active dot fills `accent` and scales to 1.2
- Primary action: full-width gradient capsule, 56pt tall, `edgeMargin` horizontal inset, `#5B5BF0 → #E0407F` gradient, 17pt Semibold white label

### 11.2 Page Content

| Page | Headline | Subtitle | Mockup |
|---|---|---|---|
| 1 | **Shoot Once. Two Videos.** | Perfect for TikTok, YouTube, Reels, and more | Creator in frame with a PiP of the scene |
| 2 | **Portrait & Landscape** | No editing, no cropping. 4K recording, pro results. | Portrait capture with social action rail |
| 3 | **Front & Back Mode** | Front camera on you. Back camera on the action. | Landmark primary with a selfie PiP |
| 4 | **Ready When You Are** | We'll need camera and microphone access to get started. | Simplified illustration, no mockup |

Page 4 replaces the `Continue` button with `Enable Camera Access`, which triggers the permission flow directly. This is the correct pattern — permission is requested at the moment of stated need, not at cold launch.

### 11.3 Onboarding Mechanics

- `Skip` in the top-right, 15pt, `chromeSecondary`, present on pages 1–3
- Swipe or button both advance
- Page transitions carry a parallax: the mockup translates at 1.0× while the background glows translate at 0.4×, producing depth
- Headline and subtitle fade in with a 40pt upward slide, staggered 80ms apart, when a page becomes active
- Shown once. A `Replay Introduction` item lives in Settings.

### 11.4 Permission Flow

If camera permission is denied, the app does **not** show a blank screen. It shows a dedicated state:

- `camera.fill.badge.ellipsis` glyph, 64pt, `chromeSecondary`
- Headline: *Camera Access Needed*
- Body explaining what the app does with the camera, one short paragraph
- Primary button: `Open Settings` → `UIApplication.openSettingsURLString`

Microphone permission denial is non-blocking: recording proceeds silently, and a persistent, dismissible banner offers to enable audio.

---

## 12. Secondary Screens

### 12.1 Gallery

- `LazyVGrid`, 3 columns, 2pt spacing, square cells
- Video cells show duration bottom-right in 11pt on a gradient scrim; dual-source captures show a small `rectangle.on.rectangle` badge top-right
- Tap opens the detail view with a matched-geometry zoom transition
- Long press opens a context menu: Share, Save to Photos, Delete, Show Clean Sources
- Detail view: full-screen player, scrub bar, and a bottom action row (Share, Export, Trim, Delete)
- Swipe down to dismiss with an interactive, rubber-banded transition

### 12.2 Settings

Grouped `List` with `.insetGrouped` style:

**Capture** — Default mode, Default layout, Save clean sources, Mirror front camera, Audio source, Grid, Level, Timer
**Quality** — Resolution, Frame rate, Codec, Stabilization
**Export** — Default preset, Watermark (Pro), Save location
**About** — Replay introduction, Restore purchases, Privacy policy, Terms, Version

### 12.3 Paywall

Presented as a `.sheet` with `.presentationDetents([.large])`.

- Header: app icon, headline *Unlock DualCam Pro*
- Feature list with `checkmark.circle.fill` in `accent`: 4K recording, 60fps, all layouts, clean source files, manual controls, no watermark
- Three plan cards: Monthly, Annual (with a `SAVE 40%` accent badge), Lifetime. Annual is pre-selected.
- Primary CTA: full-width gradient capsule
- Below: `Restore Purchases` and legal links in 12pt `chromeSecondary`
- Dismissible without friction — no dark patterns, no fake countdowns

---

## 13. Error and Edge States

| Condition | Presentation |
|---|---|
| Multi-cam unsupported on device | Full-screen explanatory state at launch; app operates in Single mode only |
| Thermal state `.serious` | Toast: *Reducing quality to keep recording* + automatic step-down. Quality pill updates. |
| Thermal state `.critical` | Recording stops and saves automatically. Alert explaining why. Camera stays live at reduced quality. |
| Storage below 500 MB | Persistent amber banner above the control row |
| Storage below 100 MB | Recording disabled; shutter greyed with an explanatory toast |
| Session interrupted (call, another app) | Preview shows a blurred freeze frame + `Camera Paused` label; auto-resumes on return |
| Recording interrupted | File is finalized and saved up to the interruption point. Toast: *Recording saved* |
| Hardware cost exceeded during configuration | Automatic degradation ladder runs silently; only the final result is surfaced via the quality pill and a single toast |
| Low battery (< 10%) during recording | Toast warning at the 10% threshold; recording continues |

---

## 14. Accessibility

- Every control carries an `accessibilityLabel` and, where behavior is non-obvious, an `accessibilityHint`
- The shutter exposes `accessibilityValue` reflecting mode and recording state
- The overlay is a single accessibility element with custom actions: Swap, Move to Corner, Resize
- Dynamic Type is supported in all sheets, Settings, Gallery, and Onboarding. Camera-overlay numeric readouts are capped at `.accessibilityMedium` to preserve layout.
- All text meets 4.5:1 contrast against its material background under worst-case scene brightness
- VoiceOver announces recording start, stop, and elapsed time at 30-second intervals
- Full Reduce Motion support (§9.3)
- Full Reduce Transparency support: materials fall back to solid `#1C1C1E` at 92% opacity

---

## 15. Implementation Notes for the Development Agent

1. **Preview layers are UIKit.** `AVCaptureVideoPreviewLayer` is a `CALayer`. Wrap it in a `UIViewRepresentable`. Do not attempt to render camera output through SwiftUI's own rendering path.

2. **Composition runs on Metal, not SwiftUI.** The composited output for recording is produced in the sample-buffer pipeline. The on-screen preview during PiP layouts uses two independent preview layers for lowest latency; only the recorded output is composited. In split layouts, use two preview layers with masked frames rather than a single composited preview.

3. **Never block the main thread with session work.** All `AVCaptureSession` configuration runs on a dedicated serial queue. UI updates hop back to `@MainActor`.

4. **Frame the geometry math in a single source of truth.** Snap zones, control cluster frames, and overlay bounds must all derive from one `LayoutGeometry` struct so collision avoidance (§5.4) has consistent inputs.

5. **Build the degradation ladder before building 4K support.** It is far easier to add higher quality tiers onto a working governor than to retrofit thermal handling into a pipeline that assumes maximum quality.

6. **Verify capability at runtime on physical devices.** Enumerate and log every `isMultiCamSupported` format on each target device before finalizing the Quality sheet options. Documentation lists are not authoritative; the device is.
