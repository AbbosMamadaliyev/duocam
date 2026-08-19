import SwiftUI

/// The draggable secondary stream — the app's signature element (Doc 2 §5).
///
/// It goes exactly where the finger puts it and stays there. The only rule is a
/// 16pt gutter on every screen edge so it can never be pushed off-screen or
/// under the display's corner radius.
///
/// This replaces the original eight-zone magnetic snapping. Snapping cost the
/// user the one thing this element is for — deciding what the shot looks like —
/// and it was the source of every complaint about the drag: the overlay jumped
/// on release, buzzed at each zone boundary it crossed, and refused a large band
/// of the screen because the snap positions were computed inside the safe area.
struct FloatingOverlayView: View {
    let source: PreviewSource?
    let geometry: LayoutGeometry
    @Bindable var model: CameraViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The live centre during a drag, and the centre the drag started from.
    ///
    /// Both are view-local `@State` rather than view-model properties, and that
    /// is load-bearing: a drag delivers events at up to 120 Hz, and writing
    /// `@Observable` state on each one re-runs `CameraScreen.body` — recomputing
    /// geometry and pushing both `CameraPreviewView`s through `updateUIView` —
    /// at the same rate. That was the judder. Only this view redraws now.
    @State private var dragCentre: CGPoint?
    @State private var dragOrigin: CGPoint?
    /// Width and height fractions at the moment the pinch began, so the whole
    /// gesture is measured against one baseline rather than compounding.
    @State private var pinchStartSize: CGSize?

    /// Resets itself the moment the gesture ends *or is cancelled*, which
    /// `onEnded` does not promise. Without it, a drag interrupted by a system
    /// gesture — Control Centre, an incoming call — leaves the overlay lifted
    /// and scaled forever, with its position held in state that nothing will
    /// ever commit.
    @GestureState private var isGestureActive = false

    private var size: CGSize { geometry.overlaySize }

    private var restingCentre: CGPoint {
        geometry.overlayCentre(for: model.overlayCentreUnit)
    }

    private var centre: CGPoint { dragCentre ?? restingCentre }

    private var isDragging: Bool { dragCentre != nil }

    var body: some View {
        overlayContent
            .frame(width: size.width, height: size.height)
            .position(centre)
            // Keyed animations only. An unkeyed `.animation` here would put a
            // spring between the finger and the overlay, which reads as lag on
            // every drag — the position must be applied on the frame it arrives.
            .dcAnimation(DC.Motion.layout, value: model.configuration.layout)
            .dcAnimation(DC.Motion.overlaySnap, value: model.overlayCentreUnit)
            .onChange(of: isGestureActive) { _, active in
                // Recovery path only: after a normal `onEnded` there is nothing
                // left to clear. After a cancellation there is, and the overlay
                // keeps the position the finger last put it at rather than
                // springing back to where the drag began.
                guard !active, let stranded = dragCentre else { return }
                dragOrigin = nil
                dragCentre = nil
                model.placeOverlay(atUnit: geometry.unitCentre(for: stranded))
            }
    }

    // MARK: Content

    private var overlayContent: some View {
        CameraPreviewView(source: source)
            .clipShape(borderShape)
            .overlay {
                // `strokeBorder`, not `stroke`: the band has to sit inside the
                // clip, because that is where the compositor draws it. See
                // `OverlayShape`.
                borderShape.strokeBorder(
                    model.overlayBorder.swiftUIColor,
                    lineWidth: model.overlayBorder.width
                )
            }
            // The ambient shadow is what tells the eye this element floats
            // *above* the scene rather than being punched into it — the
            // difference between this and prototype problem P7.
            .shadow(
                color: .black.opacity(DC.Shadow.overlayOpacity),
                radius: isDragging ? DC.Shadow.overlayLiftedRadius : DC.Shadow.overlayRadius,
                y: DC.Shadow.overlayY
            )
            .scaleEffect(isDragging && !reduceMotion ? 1.04 : 1)
            // The lift is animated, not snapped: scaling instantly on touch-down
            // shifts the pixels under the finger by two points before the drag
            // has moved anything, which is felt as a twitch.
            .dcAnimation(DC.Motion.press, value: isDragging)
            .contentShape(hitShape)
            .gesture(dragGesture)
            .simultaneousGesture(pinchGesture)
            .simultaneousGesture(doubleTapGesture)
            .accessibilityElement()
            .accessibilityLabel("Secondary camera")
            .accessibilityValue(positionDescription)
            .accessibilityAction(named: "Swap cameras") { model.swapStreams() }
            .accessibilityAction(named: "Move to next corner") { moveToNextCorner() }
    }

    /// The overlay's outline, at the radius the user chose. `pipCircle` ignores
    /// the radius entirely — a circle has no corners to round.
    private var borderShape: OverlayShape {
        OverlayShape(
            cornerRadius: model.overlayBorder.cornerRadius,
            isCircular: model.configuration.layout.overlayIsCircular
        )
    }

    /// The overlay's *touch* shape: its drawn shape with every control cluster
    /// punched out of it.
    ///
    /// `LayoutGeometry` deliberately lets the overlay be parked anywhere,
    /// including on top of the chrome, on the grounds that "the controls stay
    /// reachable because the chrome sits above the overlay in the layer stack".
    /// Z-order alone does not deliver that. It settles who is *drawn* on top,
    /// but the overlay's drag recognizer still claims touches that land in the
    /// region it shares with a control, and the control — correctly drawn on
    /// top, plainly visible, apparently tappable — never sees them. An overlay
    /// parked on the left edge did it to the recording stack's pause and torch
    /// controls; parked bottom-right it does it to Layout and Swap.
    ///
    /// Punching the obstacle rects out of the hit shape is what actually makes
    /// design principle 4 — nothing important is ever covered — true, and it
    /// costs the drag nothing: no cluster is as tall as the overlay, so there is
    /// always a band of it left to grab.
    private var hitShape: OverlayHitShape {
        let origin = CGPoint(x: centre.x - size.width / 2, y: centre.y - size.height / 2)
        return OverlayHitShape(
            base: AnyShape(borderShape),
            // The obstacles are in screen coordinates; the hit shape is asked
            // for a path in the overlay's own. During a drag `centre` is the
            // live position, so the cut-outs track the overlay as it moves.
            exclusions: geometry.obstacles.map {
                $0.offsetBy(dx: -origin.x, dy: -origin.y)
            }
        )
    }

    // MARK: Gestures

    /// One finger, no press-and-hold, no snapping.
    ///
    /// Two details make it track cleanly:
    ///
    /// 1. `minimumDistance: 1` — the overlay starts moving on the first point of
    ///    travel. There is no long-press to satisfy first.
    /// 2. `coordinateSpace: .global` — the gesture is attached to a view that
    ///    *this gesture moves*. In the default local space, every event is
    ///    measured against the view's current frame, so each update changes the
    ///    frame that the next update is measured from, and the overlay
    ///    oscillates around the finger. Global space is fixed, and the
    ///    translation it reports is a pure delta, so adding it to the centre
    ///    captured at touch-down is exact.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .updating($isGestureActive) { _, state, _ in state = true }
            .onChanged { value in
                let origin: CGPoint
                if let dragOrigin {
                    origin = dragOrigin
                } else {
                    origin = restingCentre
                    dragOrigin = origin
                    HapticEngine.shared.overlayLifted()
                }

                let moved = geometry.clampOverlayCentre(origin.offset(by: value.translation))
                dragCentre = moved
                // The recording has to show the overlay where the preview shows
                // it, mid-drag included (Doc 3 Phase 2, acceptance criterion 1).
                model.trackOverlayDrag(centre: moved, in: geometry)
            }
            .onEnded { value in
                guard let origin = dragOrigin else { return }
                let final = geometry.clampOverlayCentre(origin.offset(by: value.translation))

                // Dropped where released — no velocity projection, no snap.
                // Both writes land in one SwiftUI transaction, so `dragCentre`
                // clearing and `overlayCentreUnit` taking over cannot produce an
                // intermediate frame at the old resting position.
                dragOrigin = nil
                dragCentre = nil
                model.placeOverlay(atUnit: geometry.unitCentre(for: final))
            }
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = pinchStartSize ?? CGSize(
                    width: model.overlayWidthFraction,
                    height: model.overlayHeightFraction
                )
                if pinchStartSize == nil { pinchStartSize = base }
                // Both axes by the same factor: a pinch is a resize, and an
                // overlay that changed shape under two fingers would be
                // undoing the height the user set on purpose.
                model.scaleOverlay(from: base, by: value.magnification)
            }
            .onEnded { _ in
                pinchStartSize = nil
                // A resize can push the overlay's edge past the gutter, so the
                // stored placement is re-clamped against the new size.
                model.overlayCentreUnit = geometry.unitCentre(
                    for: geometry.clampOverlayCentre(restingCentre)
                )
            }
    }

    private var doubleTapGesture: some Gesture {
        TapGesture(count: 2).onEnded { model.swapStreams() }
    }

    // MARK: Accessibility

    /// The VoiceOver equivalent of dragging — the overlay is one accessibility
    /// element with custom actions (Doc 2 §14), because a drag target with no
    /// discrete alternative is unusable without sight.
    private func moveToNextCorner() {
        let zones = SnapZone.allCases
        let current = geometry.overlayCentre(for: model.overlayCentreUnit)
        let index = zones.firstIndex { geometry.resolvedPosition(for: $0).isClose(to: current) } ?? -1
        let next = zones[(index + 1) % zones.count]

        withAnimation(DC.Motion.resolve(DC.Motion.overlaySnap, reduceMotion: reduceMotion)) {
            model.overlayCentreUnit = geometry.unitCentre(for: geometry.resolvedPosition(for: next))
        }
    }

    /// Spoken position, in ninths — "top right", "centre", "bottom left".
    private var positionDescription: String {
        let unit = geometry.unitCentre(for: centre)
        let vertical = ["top", "middle", "bottom"][band(unit.y)]
        let horizontal = ["left", "centre", "right"][band(unit.x)]
        return "\(vertical) \(horizontal)"
    }

    private func band(_ fraction: CGFloat) -> Int {
        fraction < 1.0 / 3 ? 0 : (fraction < 2.0 / 3 ? 1 : 2)
    }
}

/// A shape with rectangles subtracted from it, used for hit testing only.
private struct OverlayHitShape: Shape {
    let base: AnyShape
    /// In the shape's own coordinate space.
    let exclusions: [CGRect]

    func path(in rect: CGRect) -> Path {
        var path = base.path(in: rect)
        for exclusion in exclusions where exclusion.intersects(rect) {
            path = path.subtracting(Path(exclusion))
        }
        return path
    }
}

private extension CGPoint {
    func offset(by translation: CGSize) -> CGPoint {
        CGPoint(x: x + translation.width, y: y + translation.height)
    }

    func isClose(to other: CGPoint, within tolerance: CGFloat = 1) -> Bool {
        abs(x - other.x) < tolerance && abs(y - other.y) < tolerance
    }
}
