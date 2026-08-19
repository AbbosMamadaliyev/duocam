import CoreGraphics
import simd

/// Which shape the compositor is drawing. Mirrors the `kMode*` constants in
/// `CompositionShaders.metal`.
nonisolated enum CompositionMode: Int32 {
    case pip = 0
    case splitHorizontal = 1
    case splitDiagonal = 2

    init(_ layout: LayoutType) {
        switch layout {
        case .pipRounded, .pipTall, .pipWide, .pipCircle: self = .pip
        case .splitHorizontal: self = .splitHorizontal
        case .splitDiagonal: self = .splitDiagonal
        }
    }
}

/// How a stream's pixel buffer is laid out. Mirrors `kFormat*` in the shader.
nonisolated enum StreamPixelFormat: Int32 {
    /// `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange` — the capture path.
    case biplanar = 0
    /// `kCVPixelFormatType_32BGRA` — the simulated path.
    case bgra = 1
}

/// The uniform block handed to the fragment shader.
///
/// Field order and padding must match `CompositionUniforms` in
/// `CompositionShaders.metal` exactly. `simd_float3x3` is 48 bytes in both
/// languages (three 16-byte-aligned columns), so the layouts agree without a
/// bridging header.
nonisolated struct CompositionUniforms {
    var primaryTransform: simd_float3x3 = matrix_identity_float3x3
    var secondaryTransform: simd_float3x3 = matrix_identity_float3x3
    /// x, y, width, height in output-normalised coordinates.
    var secondaryRect: SIMD4<Float> = .zero
    var strokeColor: SIMD4<Float> = SIMD4(1, 1, 1, 0.9)
    /// In isotropic x-units.
    var cornerRadius: Float = 0
    var strokeWidth: Float = 0
    var splitRatio: Float = 0.5
    var diagonalAngle: Float = 0
    var mode: Int32 = CompositionMode.pip.rawValue
    var isCircular: Int32 = 0
    var hasSecondary: Int32 = 0
    var primaryFormat: Int32 = StreamPixelFormat.biplanar.rawValue
    var secondaryFormat: Int32 = StreamPixelFormat.biplanar.rawValue
    var outputAspect: Float = 9.0 / 16.0
    var _pad0: Int32 = 0
    var _pad1: Int32 = 0
}

// MARK: - Building uniforms from app state

extension CompositionUniforms {
    /// Everything the compositor needs that the app already knows.
    nonisolated struct Inputs {
        var layout: LayoutType
        var outputSize: CGSize
        /// Pixel dimensions of each stream's buffer, before rotation.
        var primaryTextureSize: CGSize
        var secondaryTextureSize: CGSize
        /// Degrees the source must be rotated by to appear upright.
        var primaryRotation: Double
        var secondaryRotation: Double
        var primaryIsMirrored: Bool
        var secondaryIsMirrored: Bool
        var primaryFormat: StreamPixelFormat
        var secondaryFormat: StreamPixelFormat
        var hasSecondary: Bool
        /// Overlay centre and width, in output-normalised coordinates. Taken
        /// straight from `LayoutGeometry` so the recorded file matches what the
        /// user saw — Doc 3 Phase 2's first acceptance criterion.
        var overlayCentre: CGPoint
        var overlayWidthFraction: CGFloat
        var overlayHeightFraction: CGFloat
        var splitRatio: CGFloat
        var diagonalAngle: Double
        /// The overlay's border, from the same value the preview strokes with.
        var border: OverlayBorderStyle = .default
    }

    init(_ inputs: Inputs) {
        self.init()

        let aspect = Float(inputs.outputSize.width / max(inputs.outputSize.height, 1))
        outputAspect = aspect
        mode = CompositionMode(inputs.layout).rawValue
        hasSecondary = inputs.hasSecondary ? 1 : 0
        isCircular = inputs.layout.overlayIsCircular ? 1 : 0
        primaryFormat = inputs.primaryFormat.rawValue
        secondaryFormat = inputs.secondaryFormat.rawValue
        splitRatio = Float(inputs.splitRatio)
        diagonalAngle = Float(inputs.diagonalAngle * .pi / 180)

        // Doc 2 §2.3/§5.2 set a 20pt radius and a 3pt stroke; the border sheet
        // lets the user take either down from there. Both are expressed as a
        // fraction of the output width so they scale with resolution instead of
        // shrinking to nothing at 4K — a border chosen against a 393pt preview
        // has to survive being written into a 2160px-wide frame.
        let border = inputs.border.sanitized
        let referenceWidth = Float(inputs.outputSize.width)
        cornerRadius = inputs.layout.overlayIsCircular
            ? 0
            : Float(border.cornerRadius) / max(referenceWidth / 3, 1)
        strokeWidth = Float(border.width) / max(referenceWidth / 3, 1)
        strokeColor = SIMD4(
            Float(border.red),
            Float(border.green),
            Float(border.blue),
            Float(border.opacity)
        )

        secondaryRect = Self.overlayRect(inputs: inputs, aspect: aspect)

        // Each stream is fitted to the region it actually occupies, then the
        // shader's output UV is remapped into that region.
        //
        // Getting this wrong is subtle and looks almost right: fitting a split
        // stream to the *whole* frame and letting the shader clip it produces a
        // half that is centre-cropped from a full-frame fit rather than filled
        // to the half — the subject drifts out of the visible band.
        let mode = CompositionMode(inputs.layout)
        let outputWidth = inputs.outputSize.width
        let outputHeight = inputs.outputSize.height

        let primaryRegion: SIMD4<Float>
        let secondaryRegion: SIMD4<Float>

        switch mode {
        case .pip:
            primaryRegion = SIMD4(0, 0, 1, 1)
            secondaryRegion = secondaryRect
        case .splitHorizontal:
            primaryRegion = SIMD4(0, 0, 1, Float(inputs.splitRatio))
            secondaryRegion = SIMD4(0, Float(inputs.splitRatio), 1, Float(1 - inputs.splitRatio))
        case .splitDiagonal:
            // Both halves show a full-frame image divided by the seam, so
            // neither is confined to a sub-region.
            primaryRegion = SIMD4(0, 0, 1, 1)
            secondaryRegion = SIMD4(0, 0, 1, 1)
        }

        func regionAspect(_ region: SIMD4<Float>) -> CGFloat {
            let w = CGFloat(region.z) * outputWidth
            let h = CGFloat(region.w) * outputHeight
            return w / max(h, 1)
        }

        primaryTransform = Self.transform(
            textureSize: inputs.primaryTextureSize,
            destinationAspect: regionAspect(primaryRegion),
            rotationDegrees: inputs.primaryRotation,
            mirrored: inputs.primaryIsMirrored
        ) * Self.rectToUnitSquare(primaryRegion)

        secondaryTransform = Self.transform(
            textureSize: inputs.secondaryTextureSize,
            destinationAspect: regionAspect(secondaryRegion),
            rotationDegrees: inputs.secondaryRotation,
            mirrored: inputs.secondaryIsMirrored
        ) * Self.rectToUnitSquare(secondaryRegion)
    }

    /// The overlay's rect in output-normalised coordinates.
    ///
    /// Both axes arrive already decided. The height used to be computed here
    /// from the layout's aspect ratio, with a separate branch keeping a circular
    /// overlay square in *pixels*; that maths now lives in `OverlayMetrics`,
    /// where the sliders and `LayoutGeometry` can read the same answer. Deriving
    /// it a second time in the capture layer is precisely how the recorded
    /// overlay and the previewed one drift apart.
    private static func overlayRect(inputs: Inputs, aspect: Float) -> SIMD4<Float> {
        guard inputs.hasSecondary, CompositionMode(inputs.layout) == .pip else { return .zero }

        let width = inputs.overlayWidthFraction
        let height = inputs.overlayHeightFraction

        return SIMD4(
            Float(inputs.overlayCentre.x - width / 2),
            Float(inputs.overlayCentre.y - height / 2),
            Float(width),
            Float(height)
        )
    }

    /// Maps output UV to texture UV: aspect-fill crop, then rotation, then
    /// mirroring.
    ///
    /// Composed right-to-left as
    /// `translate(+0.5) · mirror · rotate(-θ) · scale(crop) · translate(-0.5)`,
    /// so a point is centred, cropped, un-rotated, mirrored, and re-centred.
    static func transform(
        textureSize: CGSize,
        destinationAspect: CGFloat,
        rotationDegrees: Double,
        mirrored: Bool
    ) -> simd_float3x3 {
        guard textureSize.width > 0, textureSize.height > 0, destinationAspect > 0 else {
            return matrix_identity_float3x3
        }

        let radians = rotationDegrees * .pi / 180
        let quarterTurns = Int(rotationDegrees.rounded() / 90) % 2 != 0

        // After rotation the texture's effective aspect swaps for odd quarter
        // turns — a 1920×1080 frame displayed upright is 1080×1920.
        let textureAspect = quarterTurns
            ? textureSize.height / textureSize.width
            : textureSize.width / textureSize.height

        var cropX: CGFloat = 1
        var cropY: CGFloat = 1
        if textureAspect > destinationAspect {
            // Source is wider than the destination: crop the sides.
            cropX = destinationAspect / textureAspect
        } else {
            cropY = textureAspect / destinationAspect
        }

        let centreOut = translation(-0.5, -0.5)
        let crop = scale(Float(cropX), Float(cropY))
        let unrotate = rotation(-Float(radians))
        let mirror = mirrored ? scale(-1, 1) : matrix_identity_float3x3
        let centreBack = translation(0.5, 0.5)

        // Mirroring sits *before* the un-rotation, so it flips the image
        // horizontally as the viewer sees it. Applying it after would mirror
        // along the sensor's own axis, which for a 90°-rotated front camera is
        // vertical — the image comes out upside down rather than mirrored.
        return centreBack * unrotate * mirror * crop * centreOut
    }

    /// Maps output UV into a sub-region's own unit square, so a stream drawn
    /// into part of the frame is sampled as if it owned the whole thing.
    static func rectToUnitSquare(_ rect: SIMD4<Float>) -> simd_float3x3 {
        guard rect.z > 0, rect.w > 0 else { return matrix_identity_float3x3 }
        return scale(1 / rect.z, 1 / rect.w) * translation(-rect.x, -rect.y)
    }

    // MARK: 2D affine helpers (column-major, matching simd)

    static func translation(_ x: Float, _ y: Float) -> simd_float3x3 {
        simd_float3x3(
            SIMD3(1, 0, 0),
            SIMD3(0, 1, 0),
            SIMD3(x, y, 1)
        )
    }

    static func scale(_ x: Float, _ y: Float) -> simd_float3x3 {
        simd_float3x3(
            SIMD3(x, 0, 0),
            SIMD3(0, y, 0),
            SIMD3(0, 0, 1)
        )
    }

    static func rotation(_ radians: Float) -> simd_float3x3 {
        let c = cos(radians)
        let s = sin(radians)
        return simd_float3x3(
            SIMD3(c, s, 0),
            SIMD3(-s, c, 0),
            SIMD3(0, 0, 1)
        )
    }
}
