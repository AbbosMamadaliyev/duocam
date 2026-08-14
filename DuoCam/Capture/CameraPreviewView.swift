import SwiftUI
import UIKit

/// Hosts one stream's `CALayer` in the SwiftUI hierarchy.
///
/// Doc 2 §15.1: *"Preview layers are UIKit. Do not attempt to render camera
/// output through SwiftUI's own rendering path."* The layer is added as a
/// sublayer rather than used as the view's `layerClass`, because the engine
/// owns the layer's lifetime and may hand the same layer to a different view
/// across a layout change.
struct CameraPreviewView: UIViewRepresentable {
    let source: PreviewSource?

    func makeUIView(context: Context) -> PreviewHostView {
        let view = PreviewHostView()
        view.attach(source?.layer)
        return view
    }

    func updateUIView(_ view: PreviewHostView, context: Context) {
        view.attach(source?.layer)
    }
}

/// A plain `UIView` whose only job is to keep one sublayer filling its bounds.
final class PreviewHostView: UIView {
    private weak var attached: CALayer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func attach(_ newLayer: CALayer?) {
        guard attached !== newLayer else { return }
        // Only if it is still ours. During a stream swap the two hosts exchange
        // layers, and SwiftUI does not promise an order: whichever host updates
        // second would otherwise tear the layer it just handed over back out of
        // the host that now owns it, leaving one preview blank.
        if attached?.superlayer === layer { attached?.removeFromSuperlayer() }
        attached = newLayer
        if let newLayer {
            newLayer.frame = bounds
            layer.addSublayer(newLayer)
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Implicit animation on a preview layer's frame produces a visible
        // slosh during rotation and layout morphs — the geometry must snap
        // while the *SwiftUI* frame around it is what animates.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        attached?.frame = bounds
        CATransaction.commit()
    }
}

// MARK: - Convenience

extension View {
    /// Applies `videoGravity`-equivalent behaviour on the SwiftUI side: the
    /// preview always fills its frame and clips, never letterboxes.
    func previewClip(_ shape: some Shape) -> some View {
        clipShape(shape).contentShape(shape)
    }
}
