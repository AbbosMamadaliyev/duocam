import AVFoundation
import os
import Photos
import UIKit

/// Export framings (Doc 3 Phase 6 task 9).
nonisolated enum ExportPreset: String, CaseIterable, Identifiable, Sendable {
    case tiktok
    case youtube
    case square
    case original

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tiktok: "TikTok / Reels — 9:16"
        case .youtube: "YouTube — 16:9"
        case .square: "Square — 1:1"
        case .original: "Original"
        }
    }

    /// `nil` means "leave the frame exactly as recorded".
    var renderSize: CGSize? {
        switch self {
        case .tiktok: CGSize(width: 1080, height: 1920)
        case .youtube: CGSize(width: 1920, height: 1080)
        case .square: CGSize(width: 1080, height: 1080)
        case .original: nil
        }
    }
}

/// Trims, reframes, and watermarks a capture for export.
enum MediaExporter {
    /// Produces a new file; the original is never modified.
    ///
    /// Doc 3 Phase 6 task 10 is explicit that the free-tier watermark is
    /// composited **during export, never during capture** — so the recorded
    /// master stays clean and an upgrade retroactively removes the mark from
    /// everything the user has already shot.
    static func export(
        record: CaptureRecord,
        preset: ExportPreset,
        trim: (start: Double, end: Double)?,
        watermark: Bool = false,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        guard !record.isPhoto else {
            return try exportPhoto(record: record, preset: preset, watermark: watermark)
        }

        let asset = AVURLAsset(url: record.compositedURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrack
        }

        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        // `applying` on a size can yield negative extents for 90°/180°
        // transforms, so the absolute value is what the framing maths needs.
        let transformed = naturalSize.applying(transform)
        let sourceSize = CGSize(width: abs(transformed.width), height: abs(transformed.height))
        let renderSize = preset.renderSize ?? sourceSize

        let composition = AVMutableVideoComposition()
        composition.renderSize = renderSize
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(record.frameRate.rawValue))

        let instruction = AVMutableVideoCompositionInstruction()
        let duration = try await asset.load(.duration)
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)

        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(
            fillTransform(source: sourceSize, target: renderSize, preferred: transform),
            at: .zero
        )
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]

        guard let session = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw ExportError.sessionUnavailable
        }

        if watermark {
            composition.animationTool = watermarkTool(renderSize: renderSize)
        }
        session.videoComposition = composition

        if let trim {
            let timescale: CMTimeScale = 600
            session.timeRange = CMTimeRange(
                start: CMTime(seconds: trim.start, preferredTimescale: timescale),
                end: CMTime(seconds: trim.end, preferredTimescale: timescale)
            )
        }

        let outputURL = RecordingController.mediaDirectory
            .appending(path: "export-\(Int(Date().timeIntervalSince1970))-\(preset.rawValue).mov")
        try? FileManager.default.removeItem(at: outputURL)

        let progressTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                onProgress(Double(session.progress))
            }
        }
        defer { progressTask.cancel() }

        try await session.export(to: outputURL, as: .mov)
        onProgress(1)

        Log.recording.info("Exported \(preset.rawValue, privacy: .public) → \(outputURL.lastPathComponent, privacy: .public)")
        return outputURL
    }

    /// The free-tier mark: a small wordmark inset from the bottom-right.
    ///
    /// Applied as a Core Animation overlay at export time, so the recorded
    /// master is never touched (Doc 3 Phase 6 task 10) and upgrading to Pro
    /// removes the mark from everything already shot rather than only from
    /// future captures.
    private static func watermarkTool(renderSize: CGSize) -> AVVideoCompositionCoreAnimationTool {
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: renderSize)

        let video = CALayer()
        video.frame = parent.frame
        parent.addSublayer(video)

        let scale = renderSize.width / 1080
        let text = CATextLayer()
        text.string = "DuoCam"
        text.font = UIFont.systemFont(ofSize: 1, weight: .semibold)
        text.fontSize = 34 * scale
        text.foregroundColor = UIColor.white.withAlphaComponent(0.85).cgColor
        text.alignmentMode = .right
        text.contentsScale = 2
        text.shadowOpacity = 0.4
        text.shadowRadius = 4 * scale
        text.shadowOffset = .zero
        // Core Animation's layer space has y increasing upward, so "bottom
        // right" is a *low* y here — the opposite of every other coordinate
        // system in this file.
        text.frame = CGRect(
            x: renderSize.width - 320 * scale,
            y: 44 * scale,
            width: 280 * scale,
            height: 44 * scale
        )
        parent.addSublayer(text)

        return AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: video,
            in: parent
        )
    }

    /// Aspect-**fill** into the target frame.
    ///
    /// A 9:16 capture exported to 16:9 has to be cropped, not letterboxed:
    /// Doc 3's criterion is "correctly framed", and black bars down both sides
    /// of a YouTube export are not a framing, they are a failure to choose one.
    private static func fillTransform(
        source: CGSize,
        target: CGSize,
        preferred: CGAffineTransform
    ) -> CGAffineTransform {
        guard source.width > 0, source.height > 0 else { return preferred }

        let scale = max(target.width / source.width, target.height / source.height)
        let scaled = CGSize(width: source.width * scale, height: source.height * scale)
        let translation = CGPoint(
            x: (target.width - scaled.width) / 2,
            y: (target.height - scaled.height) / 2
        )

        return preferred
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: translation.x, y: translation.y))
    }

    // MARK: Photos

    private static func exportPhoto(
        record: CaptureRecord,
        preset: ExportPreset,
        watermark: Bool
    ) throws -> URL {
        guard let data = try? Data(contentsOf: record.compositedURL),
              let image = UIImage(data: data)
        else { throw ExportError.noVideoTrack }

        let target = preset.renderSize ?? image.size
        let renderer = UIGraphicsImageRenderer(size: target)
        let output = renderer.image { _ in
            let scale = max(target.width / image.size.width, target.height / image.size.height)
            let scaled = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(
                x: (target.width - scaled.width) / 2,
                y: (target.height - scaled.height) / 2,
                width: scaled.width,
                height: scaled.height
            ))
        }

        let marked = watermark ? stamped(output) : output
        guard let jpeg = marked.jpegData(compressionQuality: 0.92) else {
            throw ExportError.encodingFailed
        }

        let url = RecordingController.mediaDirectory
            .appending(path: "export-\(Int(Date().timeIntervalSince1970))-\(preset.rawValue).jpg")
        try jpeg.write(to: url)
        return url
    }
}

extension MediaExporter {
    /// The still equivalent of the video watermark.
    fileprivate static func stamped(_ image: UIImage) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { _ in
            image.draw(at: .zero)
            let scale = image.size.width / 1080
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 34 * scale, weight: .semibold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.85),
            ]
            let text = NSAttributedString(string: "DuoCam", attributes: attributes)
            let size = text.size()
            text.draw(at: CGPoint(
                x: image.size.width - size.width - 40 * scale,
                y: image.size.height - size.height - 40 * scale
            ))
        }
    }
}

/// Saves into a dedicated album (Doc 3 Phase 6 task 11).
enum PhotoLibraryExporter {
    private static let albumName = "DuoCam"

    static func saveToPhotos(_ url: URL, isPhoto: Bool) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            Log.recording.error("Photos access denied — export not saved")
            return
        }

        do {
            let album = try await album()
            try await PHPhotoLibrary.shared().performChanges {
                let request = isPhoto
                    ? PHAssetCreationRequest.creationRequestForAssetFromImage(atFileURL: url)
                    : PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
                guard let placeholder = request?.placeholderForCreatedAsset else { return }
                if let album, let addRequest = PHAssetCollectionChangeRequest(for: album) {
                    addRequest.addAssets([placeholder] as NSArray)
                }
            }
            Log.recording.info("Saved to Photos: \(url.lastPathComponent, privacy: .public)")
        } catch {
            Log.recording.error("Photos save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Finds or creates the album. A missing album must not fail the save —
    /// landing in the camera roll beats not landing anywhere.
    private static func album() async throws -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", albumName)
        let existing = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .any, options: options
        )
        if let found = existing.firstObject { return found }

        var identifier: String?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCollectionChangeRequest
                .creationRequestForAssetCollection(withTitle: albumName)
            identifier = request.placeholderForCreatedAssetCollection.localIdentifier
        }
        guard let identifier else { return nil }
        return PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [identifier], options: nil
        ).firstObject
    }
}

nonisolated enum ExportError: LocalizedError {
    case noVideoTrack
    case sessionUnavailable
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: "This capture has no video to export."
        case .sessionUnavailable: "Export isn't available for this file."
        case .encodingFailed: "The export couldn't be encoded."
        }
    }
}
