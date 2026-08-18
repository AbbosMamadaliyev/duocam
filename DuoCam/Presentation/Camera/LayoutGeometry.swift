import CoreGraphics
import Foundation

/// One of the eight canonical parking spots for the floating overlay.
///
/// No longer a magnetic target — the overlay is dragged freely and stays where
/// it is dropped. These survive as the *discrete* alternative to a drag: the
/// launch position, and the positions VoiceOver's "Move to next corner" action
/// steps through, because a drag target with no keyboard/VoiceOver equivalent is
/// unusable without sight (Doc 2 §14).
nonisolated enum SnapZone: String, CaseIterable, Identifiable, Codable, Sendable {
    case topLeading, topCenter, topTrailing
    case leadingCenter, trailingCenter
    case bottomLeading, bottomCenter, bottomTrailing

    var id: String { rawValue }

    var horizontal: HorizontalPlacement {
        switch self {
        case .topLeading, .leadingCenter, .bottomLeading: .leading
        case .topCenter, .bottomCenter: .center
        case .topTrailing, .trailingCenter, .bottomTrailing: .trailing
        }
    }

    var vertical: VerticalPlacement {
        switch self {
        case .topLeading, .topCenter, .topTrailing: .top
        case .leadingCenter, .trailingCenter: .middle
        case .bottomLeading, .bottomCenter, .bottomTrailing: .bottom
        }
    }

    enum HorizontalPlacement { case leading, center, trailing }
    enum VerticalPlacement { case top, middle, bottom }
}

/// The single source of truth for every frame on the camera screen.
///
/// Doc 3 reminder 8: *"Snap zones, control frames, and overlay bounds all derive
/// from `LayoutGeometry`. Duplicating this math is how prototype problem P1 —
/// the overlay covering controls — reappears."*
///
/// A pure value type with no SwiftUI dependency, so the collision logic is
/// directly testable without standing up a view hierarchy.
nonisolated struct LayoutGeometry: Equatable, Sendable {
    var screenSize: CGSize
    var safeTop: CGFloat
    var safeBottom: CGFloat

    /// Recomputed on every state that can move a control cluster: mode change,
    /// recording state, sheet presentation, rotation.
    var isRecording: Bool = false
    var isDualMode: Bool = true
    var layout: LayoutType = .pipRounded
    /// Overlay width as a fraction of screen width, 0.25…0.5 (Doc 2 §5.5).
    var overlayWidthFraction: CGFloat = 0.32
    /// Whether the zoom pill row is on screen.
    ///
    /// It is a control cluster like any other — an overlay parked on it takes
    /// its taps — but it is the only one the camera screen hides on its own
    /// schedule, so the geometry cannot infer it from the recording state.
    var showsZoomPills: Bool = true

    /// Minimum gap left between the overlay and any control it would otherwise
    /// cover (Doc 2 §5.4).
    static let minimumClearance: CGFloat = 12

    /// The only limit on where the user may park the floating overlay: a 16pt
    /// gutter on every screen edge, so it can never be dragged off-screen or
    /// clipped by the display's corner radius.
    ///
    /// Deliberately *not* the safe-area inset. Doc 2 §5.2 originally confined
    /// the overlay to eight snap zones inside the safe area, which is what made
    /// it feel like the app was choosing the position rather than the user. The
    /// controls stay reachable because the chrome sits above the overlay in the
    /// layer stack, not because the overlay is fenced away from it.
    static let overlayEdgeInset: CGFloat = 16

    // MARK: Overlay

    var overlaySize: CGSize {
        let width = screenSize.width * overlayWidthFraction
        // `pipCircle` needs a square frame — a `Circle` in a 3:4 box inscribes
        // rather than fills, leaving stroke and content disagreeing about the
        // edge.
        let height = layout.overlayIsCircular ? width : width / layout.overlayAspectRatio
        return CGSize(width: width, height: height)
    }

    // MARK: Control cluster frames

    /// Quality pill + control trio, and the elapsed timer that shares that row
    /// while recording. Begins 8pt below the safe-area top inset (Doc 2 §3.3).
    ///
    /// One row in both states. It used to grow by a second row during recording,
    /// back when the timer was drawn beneath the controls; the timer is centred
    /// in the control row itself now, so reserving that extra band would push
    /// the overlay's top-centre resting place further down the frame for nothing.
    var topClusterFrame: CGRect {
        CGRect(
            x: 0,
            y: safeTop + DC.Spacing.grid,
            width: screenSize.width,
            height: DC.Size.control
        )
        .insetBy(dx: DC.Spacing.edgeMargin - Self.minimumClearance, dy: 0)
    }

    /// Gallery · shutter · swap · layout. Ends 12pt above the safe-area bottom
    /// inset, with the mode selector below it when it is present.
    var bottomClusterFrame: CGRect {
        let bottom = screenSize.height - safeBottom - 12
        let modeHeight = isModeSelectorVisible ? DC.Size.modeSelector + DC.Spacing.grid : 0
        let top = bottom - modeHeight - DC.Size.shutterOuter
        return CGRect(
            x: 0,
            y: top,
            width: screenSize.width,
            height: DC.Size.shutterOuter
        )
    }

    /// Doc 2 §7.1 step 2: the mode selector slides away during recording — it
    /// is not changeable mid-take, so leaving it on screen would be a lie.
    var isModeSelectorVisible: Bool { !isRecording }

    var modeSelectorFrame: CGRect {
        guard isModeSelectorVisible else { return .null }
        let bottom = screenSize.height - safeBottom - 12
        return CGRect(
            x: DC.Spacing.edgeMargin,
            y: bottom - DC.Size.modeSelector,
            width: screenSize.width - DC.Spacing.edgeMargin * 2,
            height: DC.Size.modeSelector
        )
    }

    /// The zoom pill row, which floats directly above the primary control row
    /// (Doc 2 §4.3).
    ///
    /// Full width like `bottomClusterFrame`, though the group itself is centred
    /// and narrow: what this rect is *for* is telling the overlay which band it
    /// must not take touches in, and the band is what matters, not the pills.
    var zoomPillFrame: CGRect {
        guard showsZoomPills else { return .null }
        let bottom = bottomClusterFrame.minY - DC.Spacing.grid - DC.Spacing.zoomPillGap
        return CGRect(
            x: 0,
            y: bottom - DC.Size.zoomPillRow,
            width: screenSize.width,
            height: DC.Size.zoomPillRow
        )
    }


    /// The vertical control column that slides in from the left edge during
    /// recording (Doc 2 §7.2).
    var recordingStackFrame: CGRect {
        guard isRecording else { return .null }
        // Two controls — pause and torch. It claimed four for as long as
        // Adjustments and audio metering were also in the stack, and kept
        // reserving 112pt of screen that nothing occupies after they were
        // removed.
        let height = DC.Size.control * 2 + DC.Spacing.controlGap
        return CGRect(
            x: DC.Spacing.edgeMargin,
            y: (screenSize.height - height) / 2,
            width: DC.Size.control,
            height: height
        )
    }

    /// Every rect the overlay must stay clear of — and, just as importantly,
    /// every rect it must not take a touch in.
    ///
    /// `FloatingOverlayView` subtracts these from the overlay's hit shape, so a
    /// control cluster missing from this list is a control the overlay silently
    /// kills whenever it is parked on top of it. That is what happened to the
    /// zoom pills, which were the one cluster never listed here.
    var obstacles: [CGRect] {
        [
            topClusterFrame,
            zoomPillFrame,
            bottomClusterFrame,
            modeSelectorFrame,
            recordingStackFrame,
        ]
        .filter { !$0.isNull && !$0.isEmpty }
    }

    // MARK: Snap zones

    /// The naive position for a zone, before control avoidance.
    func basePosition(for zone: SnapZone) -> CGPoint {
        let size = overlaySize
        let margin = DC.Spacing.edgeMargin

        let x: CGFloat = switch zone.horizontal {
        case .leading: margin + size.width / 2
        case .center: screenSize.width / 2
        case .trailing: screenSize.width - margin - size.width / 2
        }

        let y: CGFloat = switch zone.vertical {
        case .top: safeTop + margin + size.height / 2
        case .middle: screenSize.height / 2
        case .bottom: screenSize.height - safeBottom - margin - size.height / 2
        }

        return CGPoint(x: x, y: y)
    }

    /// The position the overlay actually settles at — **this is the fix for
    /// prototype problem P1**, where the floating preview covered the
    /// adjustment and flash icons and made them untappable.
    ///
    /// Each zone subtracts the bounding rect of any active control cluster,
    /// pushing perpendicular to the shorter overlap axis. The result is that
    /// the top-trailing zone lands *below* the settings/flash/adjustments trio
    /// rather than on top of it. The overlay can never make a control
    /// unreachable, in any zone, in any state.
    func resolvedPosition(for zone: SnapZone) -> CGPoint {
        var point = basePosition(for: zone)
        let size = overlaySize

        // Two passes: displacing away from one obstacle can push the overlay
        // into another (top cluster → mode selector on a short screen).
        for _ in 0..<2 {
            for obstacle in obstacles {
                let rect = overlayRect(at: point, size: size)
                guard rect.intersects(obstacle) else { continue }
                point = displace(point, size: size, awayFrom: obstacle)
            }
        }

        return clampIntoScreen(point, size: size)
    }

    func overlayRect(at center: CGPoint, size: CGSize) -> CGRect {
        CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    /// Pushes perpendicular to whichever overlap axis is shorter, so the
    /// overlay takes the cheapest route out of the obstacle rather than
    /// travelling across the screen.
    private func displace(_ center: CGPoint, size: CGSize, awayFrom obstacle: CGRect) -> CGPoint {
        let rect = overlayRect(at: center, size: size)
        let intersection = rect.intersection(obstacle)
        guard !intersection.isNull else { return center }

        var point = center

        if intersection.height <= intersection.width {
            // Vertical escape is cheaper.
            let pushDown = obstacle.maxY + Self.minimumClearance + size.height / 2
            let pushUp = obstacle.minY - Self.minimumClearance - size.height / 2
            point.y = abs(pushDown - center.y) < abs(pushUp - center.y) ? pushDown : pushUp
        } else {
            let pushRight = obstacle.maxX + Self.minimumClearance + size.width / 2
            let pushLeft = obstacle.minX - Self.minimumClearance - size.width / 2
            point.x = abs(pushRight - center.x) < abs(pushLeft - center.x) ? pushRight : pushLeft
        }

        return point
    }

    private func clampIntoScreen(_ center: CGPoint, size: CGSize) -> CGPoint {
        let margin = DC.Spacing.edgeMargin
        return CGPoint(
            x: center.x.clamped(to: (margin + size.width / 2)...(screenSize.width - margin - size.width / 2)),
            y: center.y.clamped(
                to: (safeTop + margin + size.height / 2)...(screenSize.height - safeBottom - margin - size.height / 2)
            )
        )
    }

    // MARK: Free overlay placement

    /// Where the overlay sits when the user has not moved it yet.
    ///
    /// Still control-aware — the first thing the user sees must not be an
    /// overlay parked on the flash button — but it is only a *starting* point.
    /// The moment they drag, `overlayCentre(for:)` stops consulting the
    /// obstacle list entirely.
    var defaultOverlayCentre: CGPoint {
        resolvedPosition(for: .topTrailing)
    }

    /// The overlay's centre for a stored unit position, clamped into the screen.
    ///
    /// `nil` means "never moved", which resolves to `defaultOverlayCentre`.
    func overlayCentre(for unit: CGPoint?) -> CGPoint {
        guard let unit else { return clampOverlayCentre(defaultOverlayCentre) }
        return clampOverlayCentre(CGPoint(
            x: unit.x * screenSize.width,
            y: unit.y * screenSize.height
        ))
    }

    /// Confines a centre point so the overlay keeps `overlayEdgeInset` of air on
    /// every screen edge — the only constraint on a free drag.
    ///
    /// The ranges are built with `min`/`max` rather than assumed ordered: an
    /// overlay resized to 50% of the width is wider than the gutter allows on a
    /// narrow screen, and a reversed `ClosedRange` traps.
    func clampOverlayCentre(_ centre: CGPoint) -> CGPoint {
        let size = overlaySize
        let inset = Self.overlayEdgeInset

        let minX = inset + size.width / 2
        let maxX = screenSize.width - inset - size.width / 2
        let minY = inset + size.height / 2
        let maxY = screenSize.height - inset - size.height / 2

        return CGPoint(
            x: centre.x.clamped(to: min(minX, maxX)...max(minX, maxX)),
            y: centre.y.clamped(to: min(minY, maxY)...max(minY, maxY))
        )
    }

    /// Screen point → unit position, so a stored placement survives rotation,
    /// a resize, and a different device class.
    func unitCentre(for point: CGPoint) -> CGPoint {
        CGPoint(
            x: point.x / max(screenSize.width, 1),
            y: point.y / max(screenSize.height, 1)
        )
    }
}
