import CoreGraphics
import Foundation

/// One of the eight positions the floating overlay can settle into.
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

    /// Minimum gap left between the overlay and any control it would otherwise
    /// cover (Doc 2 §5.4).
    static let minimumClearance: CGFloat = 12

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

    /// Quality pill + control trio, plus the elapsed-timer row while recording.
    /// Begins 8pt below the safe-area top inset (Doc 2 §3.3).
    ///
    /// The recording height matters: if this reported only the control row, the
    /// top-centre snap zone would resolve to a position that clears the
    /// controls but lands squarely on the timer — a control cluster the overlay
    /// covers is still a covered control, whichever row it is on.
    var topClusterFrame: CGRect {
        let timerRow = isRecording ? DC.Size.timerHeight + DC.Spacing.grid : 0
        return CGRect(
            x: 0,
            y: safeTop + DC.Spacing.grid,
            width: screenSize.width,
            height: DC.Size.control + timerRow
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

    /// Zoom pills float 84pt above the shutter (Doc 2 §4.3).
    var zoomPillCenterY: CGFloat {
        bottomClusterFrame.midY - 84
    }

    /// The vertical control column that slides in from the left edge during
    /// recording (Doc 2 §7.2).
    var recordingStackFrame: CGRect {
        guard isRecording else { return .null }
        let height = DC.Size.control * 4 + DC.Spacing.controlGap * 3
        return CGRect(
            x: DC.Spacing.edgeMargin,
            y: (screenSize.height - height) / 2,
            width: DC.Size.control,
            height: height
        )
    }

    /// Every rect the overlay must stay clear of.
    var obstacles: [CGRect] {
        [topClusterFrame, bottomClusterFrame, modeSelectorFrame, recordingStackFrame]
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

    /// The zone nearest an arbitrary point, measured against *resolved*
    /// positions — snapping to a base position the overlay can never occupy
    /// would make the highlight during drag disagree with where it lands.
    func nearestZone(to point: CGPoint) -> SnapZone {
        SnapZone.allCases.min { lhs, rhs in
            distanceSquared(point, resolvedPosition(for: lhs))
                < distanceSquared(point, resolvedPosition(for: rhs))
        } ?? .topTrailing
    }

    /// Velocity-projected landing point (Doc 2 §5.3). The 0.15 multiplier is
    /// what makes a quick flick carry across the screen while a slow drag
    /// settles where it was released — the same feel as iOS's own PiP window.
    func projectedPoint(from position: CGPoint, velocity: CGSize) -> CGPoint {
        CGPoint(
            x: position.x + velocity.width * 0.15,
            y: position.y + velocity.height * 0.15
        )
    }

    private func distanceSquared(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return dx * dx + dy * dy
    }
}
