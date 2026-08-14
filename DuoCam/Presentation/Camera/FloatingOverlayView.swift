import SwiftUI

/// The draggable secondary stream — the app's signature element (Doc 2 §5).
///
/// Its behaviour has to feel *physical*, which is why the drag uses
/// velocity-projected magnetic snapping rather than release-position snapping:
/// a quick flick carries the overlay across the screen while a slow drag
/// settles where it was let go.
struct FloatingOverlayView: View {
    let source: PreviewSource?
    let geometry: LayoutGeometry
    @Bindable var model: CameraViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragStart: CGPoint?
    @State private var pinchStartFraction: CGFloat?

    private var size: CGSize { geometry.overlaySize }

    private var restingPosition: CGPoint {
        geometry.resolvedPosition(for: model.overlayZone)
    }

    private var currentPosition: CGPoint {
        guard let offset = model.overlayDragOffset else { return restingPosition }
        return CGPoint(x: restingPosition.x + offset.width, y: restingPosition.y + offset.height)
    }

    private var isDragging: Bool { model.overlayDragOffset != nil }

    var body: some View {
        ZStack {
            if isDragging {
                snapZoneGuides
            }

            overlayContent
                .frame(width: size.width, height: size.height)
                .position(currentPosition)
        }
        .dcAnimation(DC.Motion.overlaySnap, value: model.overlayZone)
        .dcAnimation(DC.Motion.layout, value: model.configuration.layout)
    }

    // MARK: Content

    private var overlayContent: some View {
        CameraPreviewView(source: source)
            .clipShape(clipShape)
            .overlay {
                clipShape.stroke(
                    DC.Color.chromePrimary.opacity(DC.Stroke.overlayOpacity),
                    lineWidth: DC.Stroke.overlay
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
            .scaleEffect(isDragging && !reduceMotion ? 1.06 : 1)
            .gesture(dragGesture)
            .simultaneousGesture(pinchGesture)
            .simultaneousGesture(doubleTapGesture)
            .accessibilityElement()
            .accessibilityLabel("Secondary camera")
            .accessibilityValue(model.overlayZone.rawValue)
            .accessibilityAction(named: "Swap cameras") { model.swapStreams() }
            .accessibilityAction(named: "Move to next corner") { moveToNextZone() }
    }

    private var clipShape: AnyShape {
        model.configuration.layout.overlayIsCircular
            ? AnyShape(Circle())
            : AnyShape(RoundedRectangle.dc(DC.Radius.overlay))
    }

    // MARK: Snap zone guides

    /// All eight zones render as faint dashed outlines during a drag; the
    /// nearest brightens to a solid accent outline. Showing where the overlay
    /// *can* go is what makes the magnetism feel intentional rather than like
    /// the app fighting the finger.
    private var snapZoneGuides: some View {
        ForEach(SnapZone.allCases) { zone in
            let isNearest = zone == model.highlightedZone
            RoundedRectangle.dc(DC.Radius.overlay)
                .strokeBorder(
                    isNearest ? DC.Color.accent : DC.Color.chromePrimary.opacity(0.2),
                    style: StrokeStyle(
                        lineWidth: isNearest ? 2 : 1,
                        dash: isNearest ? [] : [4, 4]
                    )
                )
                .frame(width: size.width, height: size.height)
                .position(geometry.resolvedPosition(for: zone))
        }
        .transition(.opacity)
        .allowsHitTesting(false)
    }

    // MARK: Gestures

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if dragStart == nil {
                    dragStart = restingPosition
                    HapticEngine.shared.prepare()
                }
                model.overlayDragOffset = value.translation

                let candidate = geometry.nearestZone(to: CGPoint(
                    x: restingPosition.x + value.translation.width,
                    y: restingPosition.y + value.translation.height
                ))
                if candidate != model.highlightedZone {
                    model.highlightedZone = candidate
                    HapticEngine.shared.snapZoneChanged()
                }
            }
            .onEnded { value in
                let released = CGPoint(
                    x: restingPosition.x + value.translation.width,
                    y: restingPosition.y + value.translation.height
                )
                let projected = geometry.projectedPoint(
                    from: released,
                    velocity: CGSize(
                        width: value.predictedEndTranslation.width - value.translation.width,
                        height: value.predictedEndTranslation.height - value.translation.height
                    )
                )
                let target = geometry.nearestZone(to: projected)

                dragStart = nil
                withAnimation(DC.Motion.resolve(DC.Motion.overlaySnap, reduceMotion: reduceMotion)) {
                    model.settleOverlay(at: target)
                }
            }
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = pinchStartFraction ?? model.overlayWidthFraction
                if pinchStartFraction == nil { pinchStartFraction = base }
                model.resizeOverlay(to: base * value.magnification)
            }
            .onEnded { _ in
                pinchStartFraction = nil
            }
    }

    private var doubleTapGesture: some Gesture {
        TapGesture(count: 2).onEnded { model.swapStreams() }
    }

    /// The VoiceOver equivalent of dragging — the overlay is one accessibility
    /// element with custom actions (Doc 2 §14), because a drag target with no
    /// discrete alternative is unusable without sight.
    private func moveToNextZone() {
        let all = SnapZone.allCases
        guard let index = all.firstIndex(of: model.overlayZone) else { return }
        let next = all[(index + 1) % all.count]
        withAnimation(DC.Motion.overlaySnap) {
            model.overlayZone = next
        }
    }
}
