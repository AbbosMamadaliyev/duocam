# DualCam — Project Overview

> **Document 1 of 3** · Product definition, scope, and technical foundation
> **Audience:** AI development agent, iOS engineers, product stakeholders
> **Status:** Specification v1.0

---

## 1. Executive Summary

**DualCam** is a native iOS camera application that captures video and photos from two cameras **simultaneously in a single session**. The user records the world in front of them and their own reaction at the same time — no editing, no second take, no external app.

The product exists because Apple's system Camera app does not expose multi-camera capture to users, while the demand for reaction-style content (TikTok, Instagram Reels, YouTube Shorts, vlogs, POV sports) is enormous. The iOS platform provides the underlying capability through `AVCaptureMultiCamSession`, but no first-party consumer experience wraps it.

**Core value proposition:** *Shoot once. Get two perspectives.*

### 1.1 Product Pillars

| Pillar | Meaning |
|---|---|
| **Instant** | Camera is live within 800ms of launch. Zero configuration required to record. |
| **Native** | Feels like it was built by Apple. iOS design language, system gestures, haptics, motion. |
| **Flexible** | Any camera combination, any layout, repositionable overlay, live layout switching. |
| **Honest quality** | Highest resolution the hardware genuinely allows, clearly communicated to the user. |

### 1.2 What This App Is Not

- Not a video editor. Editing is post-capture and minimal (trim, export presets).
- Not a social network. No feed, no accounts required for core capture.
- Not a filter/AR app. Beauty and effects are a deliberate non-goal for v1.

---

## 2. Competitive Analysis

The reference screenshots supplied for this project fall into two groups: shipping competitor apps and an in-progress internal prototype. The analysis below drives every design decision in Documents 2 and 3.

### 2.1 What Competitors Do Well

**Free-position overlay.** Across the reference set the small preview appears in the top-right, mid-left, and bottom-center. This confirms that a freely draggable overlay is a baseline expectation, not a premium feature.

**Circular translucent control buttons.** Competitors place controls in circular, blurred, semi-transparent containers directly over the live preview rather than in opaque black bars. This preserves preview area and reads as native iOS.

**Contextual recording controls.** During recording, competitors surface a vertical secondary control stack (pause, ISO, flash, expand) along one screen edge, and replace the idle UI with a prominent elapsed-time indicator. Idle UI and recording UI are treated as two distinct states.

**Onboarding sells outcomes, not features.** The three onboarding screens in the reference set lead with benefit statements — *"Shoot Once. Two Videos"*, *"Portrait & Landscape"*, *"Front & Back Mode"* — supported by device mockups showing the actual result, with recognizable platform icons (TikTok, YouTube, Instagram) establishing context. Each screen has a single full-width gradient primary action.

### 2.2 Problems Identified in the Current Prototype

These are documented explicitly so the development agent does not reproduce them.

| # | Problem | Evidence | Resolution |
|---|---|---|---|
| P1 | **Overlay collides with controls.** The floating preview covers the adjustment and flash icons in the top-right, making them untappable. | Front/Back mode screenshots | Magnetic snap zones with a control-aware exclusion region (Doc 2 §5.4) |
| P2 | **Layout picker floats over the subject.** The five-option layout row sits in the vertical middle of the screen, obscuring the person being filmed. | Dual and Front/Back mode screenshots | Move to a dismissible bottom sheet anchored above the control bar (Doc 2 §6.3) |
| P3 | **Three stacked control tiers.** Layout row + primary control row + mode selector row consume the lower third of the screen. | All prototype screenshots | Collapse to two tiers; layout becomes on-demand (Doc 2 §4) |
| P4 | **Two shutter buttons visible at once.** A red record circle and a white photo circle appear side by side with no indication of which is active. | All prototype screenshots | Single morphing shutter driven by Photo/Video mode (Doc 2 §6.1) |
| P5 | **Opaque letterbox bars.** Solid black bars at top and bottom waste screen area and break immersion. | Early prototype screenshots | Full-bleed preview with blurred material overlays (Doc 2 §3.2) |
| P6 | **Unclear mode names.** "Dual", "Single", and "Front/Back" do not communicate what differs between them. | Mode selector in all prototype screenshots | Renamed and re-grouped with explicit source pickers (§3.2 below) |
| P7 | **Hard-cornered overlay without separation.** Early builds show a sharp-cornered rectangle with no border or shadow, reading as a rendering artifact rather than an intentional element. | First prototype screenshot | Continuous corner radius, 3pt white stroke, ambient shadow (Doc 2 §5.2) |
| P8 | **Unlabeled icon row.** Five bare glyphs (magnifier, sun, bulb, face frame, gear) with no labels or grouping logic. | Early prototype screenshot | Reduced to four canonical controls with a consolidated adjustments sheet (Doc 2 §4.2) |

### 2.3 Differentiation Strategy

Competitors have solved *capture*. None have solved *feel*. DualCam's differentiation is execution quality: fluid layout transitions, physics-based overlay dragging, correct haptic vocabulary, honest quality reporting, and thermal behavior that degrades gracefully instead of crashing the session.

Secondary differentiators, in priority order:

1. **Dual-rear capture** (wide + ultra-wide simultaneously) — rarely offered, valuable for cycling, driving, and action content.
2. **Independent dual-file export** — one composited file plus two clean source files, so creators can re-edit later.
3. **Live layout switching during recording** — change from PiP to split mid-take without stopping.

---

## 3. Product Definition

### 3.1 Target Users

| Segment | Need | Primary mode |
|---|---|---|
| Short-form creators | Reaction content for Reels/TikTok/Shorts | Front + Back PiP |
| Travel vloggers | Landmark plus personal narration in one shot | Front + Back PiP, split for establishing shots |
| Action/sports POV | Rider's face plus the road ahead | Front + Back PiP, small overlay |
| Event attendees | The event plus the crowd reaction | Front + Back, layout swap |
| Product reviewers | Product close-up plus presenter | Dual rear (wide + ultra-wide) |

### 3.2 Capture Modes — Canonical Definitions

The prototype's mode names are replaced with an explicit two-axis model. **Axis A** is how many streams are captured; **Axis B** is which physical cameras feed them.

| Mode ID | User-facing name | Streams | Default sources | Notes |
|---|---|---|---|---|
| `dualFrontBack` | **Front + Back** | 2 | Front TrueDepth + Rear Wide | Default mode on launch |
| `dualRear` | **Rear + Rear** | 2 | Rear Wide + Rear Ultra-Wide | Device-dependent; hidden if unsupported |
| `single` | **Single** | 1 | Rear Wide | Full quality, all system features available |

Within any two-stream mode, the user independently controls:

- **Which stream is primary** (fills the screen) — swap action
- **Which physical lens feeds each stream** — source picker per stream
- **How the two streams are arranged** — layout selector

This separation is the key correction to prototype problem P6. "Front/Back" and "Dual" were conflating source selection with layout, which is why users could not predict what a mode button would do.

### 3.3 Layout Types

Five layouts, matching the reference prototype's option row but restructured:

| Layout ID | Description | Overlay behavior |
|---|---|---|
| `pipRounded` | Rounded-rectangle floating overlay, portrait aspect | Draggable, resizable, snaps to 8 zones |
| `pipTall` | Taller rounded overlay for portrait subjects | Draggable, resizable, snaps to 8 zones |
| `pipCircle` | Circular floating overlay | Draggable, resizable, snaps to 8 zones |
| `splitHorizontal` | Screen divided into top and bottom halves | Divider draggable 30%–70% |
| `splitDiagonal` | Diagonal split with an angled seam | Seam angle adjustable |

Vertical split (left/right) is added in a later phase for landscape orientation.

### 3.4 Capture Outputs

Every two-stream recording produces, at minimum:

1. **Composited file** — a single video matching exactly what the user saw on screen.

Optionally (user setting, default on for Pro tier):

2. **Clean primary source** — full-frame, no overlay, no composition.
3. **Clean secondary source** — full-frame, no overlay, no composition.

Photo capture in two-stream modes produces the composited still, and optionally both clean stills.

---

## 4. Feature Inventory

Grouped by domain. Phase assignment is defined in Document 3.

### 4.1 Capture

- Simultaneous two-camera video recording
- Simultaneous two-camera photo capture
- Single-camera mode with full system quality
- Live layout switching during recording
- Primary/secondary stream swap (idle and during recording)
- Per-stream lens selection (ultra-wide / wide / telephoto / front)
- Continuous pinch zoom on the primary stream, discrete zoom on the secondary
- Tap-to-focus and tap-to-expose, per stream
- Exposure compensation via vertical drag after focus lock
- Manual controls: ISO, shutter speed, white balance, manual focus
- Torch control (rear-primary only) and screen-flash (front-primary)
- Resolution selection: 4K / 1080p / 720p, constrained by live hardware capability
- Frame rate selection: 24 / 30 / 60 fps, constrained by resolution
- Grid overlay, level indicator
- Timer (3s / 10s), burst photo
- Recording pause and resume within a single output file
- Audio source selection (front mic / rear mic / auto)

### 4.2 Composition and Overlay

- Free-drag overlay with velocity-based magnetic snapping
- Pinch-to-resize overlay (25%–50% of screen width)
- Double-tap overlay to swap primary and secondary
- Overlay border style options (white stroke / none / shadow only)
- Overlay corner radius follows layout type
- Split divider drag with snap-to-center detent
- Overlay mirroring toggle for the front camera

### 4.3 Review and Export

- In-app gallery of app-captured media
- Playback with scrubbing
- Trim
- Export presets: TikTok/Reels 9:16, YouTube 16:9, Square 1:1, Original
- Save to Photos, share sheet
- Access to clean source files when recorded

### 4.4 System and Quality

- Real-time thermal monitoring with graceful quality reduction
- Hardware-cost validation before every session configuration
- Live capability reporting (what resolution is *actually* available on this device in this mode)
- Interruption handling: phone calls, other apps taking the camera, backgrounding
- Storage-space pre-check and low-space warning
- Battery-level awareness during long recordings

### 4.5 Onboarding and Monetization

- Four-screen onboarding carousel
- Permission requests contextualized with explanation
- Free tier: 1080p, PiP layouts, composited output, watermark on export
- Pro tier: 4K, 60fps, all layouts, clean source files, manual controls, no watermark
- Subscription: monthly, annual, lifetime

---

## 5. Technical Foundation

### 5.1 Platform Requirements

| Requirement | Value |
|---|---|
| Minimum iOS | 17.0 |
| Minimum chipset for multi-cam | A12 Bionic (iPhone XS / XR and later) |
| Language | Swift 5.9+ |
| UI framework | SwiftUI for structure and chrome; UIKit-hosted `CALayer` for camera previews |
| Capture | AVFoundation — `AVCaptureMultiCamSession` |
| Composition | Metal (primary) with Core Image fallback |
| Encoding | `AVAssetWriter` with HEVC, H.264 fallback |
| Persistence | SwiftData |
| Architecture | MVVM with an actor-isolated capture layer |

### 5.2 Core Capture Architecture

```
CaptureCoordinator (actor)
├── SessionManager
│   ├── AVCaptureMultiCamSession
│   ├── Manual connection graph (inputs → ports → outputs)
│   ├── hardwareCost / systemPressureCost validation
│   └── Configuration transactions
├── StreamController (×2: primary, secondary)
│   ├── AVCaptureDeviceInput
│   ├── AVCaptureVideoDataOutput → sample buffer delegate
│   ├── AVCapturePhotoOutput
│   └── Per-stream focus / exposure / zoom control
├── FrameCompositor (Metal)
│   ├── Layout engine (PiP / split / diagonal)
│   ├── Texture cache and pixel buffer pool
│   └── Composited output → preview + writer
├── RecordingController
│   ├── AVAssetWriter (composited)
│   ├── AVAssetWriter ×2 (optional clean sources)
│   └── Audio input routing
└── ThermalGovernor
    ├── ProcessInfo.thermalState observation
    ├── AVCaptureDevice.systemPressureState observation
    └── Automatic degradation ladder
```

### 5.3 Non-Negotiable Technical Constraints

The development agent must treat these as hard rules, because violating them produces either a crash or a silent capability failure.

1. **Multi-cam sessions require manual connections.** `addInput(_:)` and `addOutput(_:)` must be replaced with `addInputWithNoConnections(_:)` and `addOutputWithNoConnections(_:)`, followed by explicitly constructed `AVCaptureConnection` objects. Automatic connection setup does not work.

2. **Preview layers require manual connections too.** Use `AVCaptureVideoPreviewLayer(sessionWithNoConnection:)` and attach via `AVCaptureConnection(inputPort:videoPreviewLayer:)`.

3. **Only formats where `format.isMultiCamSupported == true` may be selected.** The set of such formats is device- and iOS-version-specific and must be enumerated at runtime. Never hard-code a resolution assumption.

4. **`session.hardwareCost` must be ≤ 1.0 after configuration.** If it exceeds 1.0 the configuration is rejected. Recovery order: reduce secondary stream resolution, then reduce primary resolution, then apply `videoMinFrameDurationOverride` to lower effective frame rate.

5. **Virtual devices are generally unavailable in multi-cam.** Use discrete physical devices (`.builtInWideAngleCamera`, `.builtInUltraWideAngleCamera`, `.builtInTelephotoCamera`, `.builtInTrueDepthCamera`). Lens transitions must be handled by the app, not by the system's virtual-device switching.

6. **Only one audio input is permitted per session,** even with two video streams. Directional capture is achieved through `AVAudioSession` data-source selection, not through a second input.

7. **Computational photography is unavailable in multi-cam mode.** Night Mode, Deep Fusion, ProRAW, Photographic Styles, and Cinematic Mode are all disabled. The Single mode path must use a standard `AVCaptureSession` to make these available.

8. **Thermal degradation is mandatory, not optional.** Two live cameras plus real-time Metal composition plus hardware encoding will drive sustained thermal pressure. Without an active governor, iOS will terminate the session mid-recording.

### 5.4 Required Info.plist Keys

```
NSCameraUsageDescription
NSMicrophoneUsageDescription
NSPhotoLibraryAddUsageDescription
NSPhotoLibraryUsageDescription     (gallery import, later phase)
```

### 5.5 Reference Implementation

Apple's **AVMultiCamPiP** sample project covers session setup, dual preview layers, hardware cost management, and asset writing. It is the correct starting point for Phase 1 and should be studied before any capture code is written.

---

## 6. Success Criteria

### 6.1 Technical

| Metric | Target |
|---|---|
| Cold launch to live preview | < 800 ms |
| Layout switch (no recording) | < 200 ms, no preview interruption |
| Layout switch (during recording) | Seamless, no dropped frames |
| Mode switch (Front+Back ↔ Rear+Rear) | < 600 ms |
| Sustained 1080p/30 dual recording before first degradation | ≥ 10 minutes at 22°C ambient |
| Frame drops during composition | < 0.1% |
| Crash-free session rate | > 99.5% |
| Memory ceiling during 4K dual capture | < 400 MB |

### 6.2 Product

| Metric | Target |
|---|---|
| Onboarding completion | > 85% |
| First recording within first session | > 70% |
| Recording saved (not discarded) | > 80% |
| Day-7 retention | > 25% |
| Free-to-Pro conversion | > 4% |

---

## 7. Document Map

| Document | Contents |
|---|---|
| `01_PROJECT_OVERVIEW.md` | This document — product definition, competitive analysis, technical foundation |
| `02_UI_UX_SPECIFICATION.md` | Complete interface specification: layout, components, motion, haptics, gestures, states |
| `03_FEATURE_ROADMAP.md` | Phased implementation plan with acceptance criteria per phase |
