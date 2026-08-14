import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import UIKit

/// Renders synthetic camera frames into real `CVPixelBuffer`s.
///
/// This is what makes Phase E verifiable at all before hardware: the Metal
/// compositor, the frame pairer and `AVAssetWriter` are all real code paths
/// that only need *pixel buffers* to run — they do not care whether a camera
/// produced them. Feeding them synthetic frames in the simulator exercises the
/// entire recording pipeline end to end, so the hardware run confirms rather
/// than discovers.
///
/// Output is BGRA rather than 420f because `CGContext` cannot draw into a
/// biplanar buffer without a manual colour conversion. The shader already
/// accepts both formats for exactly this reason.
final class SyntheticFrameSource: @unchecked Sendable {
    private let size: CGSize
    private var pool: CVPixelBufferPool?
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    init(size: CGSize) {
        self.size = size
        pool = Self.makePool(size: size)
    }

    /// Draws one frame for a stream. `phase` advances the animation so the
    /// output is unmistakably live.
    func render(role: StreamRole, source: CameraSource, phase: Double) -> CVPixelBuffer? {
        guard let pool else { return nil }

        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
                == kCVReturnSuccess,
              let buffer
        else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(
                  data: base,
                  width: Int(size.width),
                  height: Int(size.height),
                  bitsPerComponent: 8,
                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }

        draw(in: context, role: role, source: source, phase: phase)
        return buffer
    }

    private func draw(in context: CGContext, role: StreamRole, source: CameraSource, phase: Double) {
        let rect = CGRect(origin: .zero, size: size)
        let palette = Self.palette(for: source)

        // Background gradient, distinct per lens so a mis-wired stream is
        // obvious in the recorded file, not just on screen.
        if let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: palette.map(\.cgColor) as CFArray,
            locations: [0, 1]
        ) {
            context.drawLinearGradient(
                gradient,
                start: .zero,
                end: CGPoint(x: rect.maxX, y: rect.maxY),
                options: []
            )
        }

        // A grid, so rotation and aspect-fill cropping are readable.
        context.setStrokeColor(UIColor.white.withAlphaComponent(0.12).cgColor)
        context.setLineWidth(2)
        let step = size.width / 12
        for x in stride(from: 0, through: size.width, by: step) {
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: size.height))
        }
        for y in stride(from: 0, through: size.height, by: step) {
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.strokePath()

        // An arrow pointing "up" in sensor space. If the composited output
        // shows it sideways, the rotation transform is wrong — which is the one
        // thing a still gradient could never reveal.
        context.saveGState()
        context.translateBy(x: size.width / 2, y: size.height / 2)
        context.setFillColor(UIColor.white.withAlphaComponent(0.9).cgColor)
        let arrow = size.height * 0.18
        context.move(to: CGPoint(x: 0, y: arrow))
        context.addLine(to: CGPoint(x: arrow * 0.5, y: 0))
        context.addLine(to: CGPoint(x: arrow * 0.18, y: 0))
        context.addLine(to: CGPoint(x: arrow * 0.18, y: -arrow))
        context.addLine(to: CGPoint(x: -arrow * 0.18, y: -arrow))
        context.addLine(to: CGPoint(x: -arrow * 0.18, y: 0))
        context.addLine(to: CGPoint(x: -arrow * 0.5, y: 0))
        context.closePath()
        context.fillPath()
        context.restoreGState()

        // A travelling marker, so a frozen pipeline is distinguishable from a
        // running one in a single screenshot.
        let travel = CGFloat((sin(phase * 1.6) + 1) / 2)
        let marker = size.width * 0.08
        context.setFillColor(UIColor.white.cgColor)
        context.fillEllipse(in: CGRect(
            x: travel * (size.width - marker),
            y: size.height * 0.12,
            width: marker,
            height: marker
        ))

        // Role and lens, drawn large enough to survive the PiP downscale.
        let label = "\(source.displayName.uppercased()) · \(role.displayName.uppercased())"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: size.height * 0.06, weight: .bold),
            .foregroundColor: UIColor.white.withAlphaComponent(0.85),
        ]
        let attributed = NSAttributedString(string: label, attributes: attributes)
        let textSize = attributed.size()

        UIGraphicsPushContext(context)
        context.saveGState()
        // CoreGraphics draws text with y increasing upward; the buffer is
        // top-down, so the context has to be flipped for this one draw.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        attributed.draw(at: CGPoint(
            x: (size.width - textSize.width) / 2,
            y: size.height * 0.7
        ))
        context.restoreGState()
        UIGraphicsPopContext()
    }

    private static func palette(for source: CameraSource) -> [UIColor] {
        switch source {
        case .front:
            [UIColor(red: 0.98, green: 0.55, blue: 0.42, alpha: 1),
             UIColor(red: 0.44, green: 0.16, blue: 0.40, alpha: 1)]
        case .rearWide:
            [UIColor(red: 0.18, green: 0.52, blue: 0.78, alpha: 1),
             UIColor(red: 0.05, green: 0.14, blue: 0.30, alpha: 1)]
        case .rearUltraWide:
            [UIColor(red: 0.22, green: 0.70, blue: 0.60, alpha: 1),
             UIColor(red: 0.04, green: 0.22, blue: 0.26, alpha: 1)]
        case .rearTelephoto:
            [UIColor(red: 0.78, green: 0.66, blue: 0.24, alpha: 1),
             UIColor(red: 0.28, green: 0.16, blue: 0.04, alpha: 1)]
        }
    }

    /// Encodes a composited buffer as JPEG.
    static func jpegData(from buffer: CVPixelBuffer) -> Data? {
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = CIContext().createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.92)
    }

    private static func makePool(size: CGSize) -> CVPixelBufferPool? {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            [kCVPixelBufferPoolMinimumBufferCountKey as String: 4] as CFDictionary,
            attributes as CFDictionary,
            &pool
        ) == kCVReturnSuccess else { return nil }
        return pool
    }
}
