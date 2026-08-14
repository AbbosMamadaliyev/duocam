import AVFoundation
import Foundation
import os
import SwiftData
import UIKit

/// One saved capture (Doc 3 Phase 2 task 16).
///
/// File URLs are stored as **relative names**, not absolute paths: the app's
/// container path changes on every reinstall and across device restores, so an
/// absolute URL persisted today is a broken reference tomorrow.
@Model
final class CaptureRecord {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var duration: TimeInterval = 0

    /// `CaptureMode.rawValue` — stored raw so a future mode does not fail to
    /// decode an existing library.
    var modeRaw: String = CaptureMode.dualFrontBack.rawValue
    var layoutRaw: String = LayoutType.pipRounded.rawValue

    var compositedFileName: String = ""
    var primarySourceFileName: String?
    var secondarySourceFileName: String?
    var thumbnailFileName: String?

    var isPhoto: Bool = false
    var resolutionRaw: String = Resolution.hd1080p.rawValue
    var frameRateRaw: Int = FrameRate.fps30.rawValue

    init(
        duration: TimeInterval,
        mode: CaptureMode,
        layout: LayoutType,
        compositedFileName: String,
        isPhoto: Bool = false,
        resolution: Resolution = .hd1080p,
        frameRate: FrameRate = .fps30
    ) {
        self.duration = duration
        self.modeRaw = mode.rawValue
        self.layoutRaw = layout.rawValue
        self.compositedFileName = compositedFileName
        self.isPhoto = isPhoto
        self.resolutionRaw = resolution.rawValue
        self.frameRateRaw = frameRate.rawValue
    }

    var mode: CaptureMode { CaptureMode(rawValue: modeRaw) ?? .single }
    var layout: LayoutType { LayoutType(rawValue: layoutRaw) ?? .pipRounded }
    var resolution: Resolution { Resolution(rawValue: resolutionRaw) ?? .hd1080p }
    var frameRate: FrameRate { FrameRate(rawValue: frameRateRaw) ?? .fps30 }

    var compositedURL: URL {
        RecordingController.mediaDirectory.appending(path: compositedFileName)
    }

    var thumbnailURL: URL? {
        thumbnailFileName.map { RecordingController.mediaDirectory.appending(path: $0) }
    }

    /// Doc 2 §12.1: dual-source captures carry a badge in the gallery.
    var hasCleanSources: Bool {
        primarySourceFileName != nil || secondarySourceFileName != nil
    }

    var formattedDuration: String {
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Owns the SwiftData stack and the on-disk media beside it.
///
/// The two are deliberately managed together: a record without its file, or a
/// file without its record, is the failure mode that turns a gallery into a
/// grid of grey rectangles.
@MainActor
final class CaptureLibrary {
    let container: ModelContainer

    init() throws {
        // On a fresh install `Library/Application Support` does not exist yet,
        // and SwiftData's default store lives there. Without this the first
        // launch spends its startup budget inside CoreData's recovery path.
        try? FileManager.default.createDirectory(
            at: URL.applicationSupportDirectory,
            withIntermediateDirectories: true
        )
        let schema = Schema([CaptureRecord.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        container = try ModelContainer(for: schema, configurations: [configuration])
    }

    /// In-memory variant for previews and the simulated engine.
    static func inMemory() throws -> CaptureLibrary {
        try CaptureLibrary(inMemory: true)
    }

    private init(inMemory: Bool) throws {
        let schema = Schema([CaptureRecord.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        container = try ModelContainer(for: schema, configurations: [configuration])
    }

    /// Records a finished recording and generates its thumbnail.
    @discardableResult
    func save(
        _ result: RecordingResult,
        mode: CaptureMode,
        layout: LayoutType,
        quality: NegotiatedQuality
    ) async -> CaptureRecord {
        let record = CaptureRecord(
            duration: result.duration,
            mode: mode,
            layout: layout,
            compositedFileName: result.url.lastPathComponent,
            resolution: quality.resolution,
            frameRate: quality.frameRate
        )

        if let thumbnailName = await Self.generateThumbnail(for: result.url) {
            record.thumbnailFileName = thumbnailName
        }
        record.primarySourceFileName = result.cleanSourceFileNames[.primary]
        record.secondarySourceFileName = result.cleanSourceFileNames[.secondary]

        container.mainContext.insert(record)
        try? container.mainContext.save()
        Log.recording.info("Saved capture \(record.compositedFileName, privacy: .public)")
        return record
    }

    /// Saves a still. Photos are their own record type only in the sense that
    /// `isPhoto` is set — sharing the model keeps the gallery a single query.
    @discardableResult
    func savePhoto(
        _ photo: PhotoResult,
        mode: CaptureMode,
        layout: LayoutType,
        quality: NegotiatedQuality
    ) async -> CaptureRecord? {
        let name = "DuoCam-\(Int(Date().timeIntervalSince1970)).jpg"
        let url = RecordingController.mediaDirectory.appending(path: name)
        do {
            try photo.jpegData.write(to: url)
        } catch {
            Log.recording.error("Photo write failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        let record = CaptureRecord(
            duration: 0,
            mode: mode,
            layout: layout,
            compositedFileName: name,
            isPhoto: true,
            resolution: quality.resolution,
            frameRate: quality.frameRate
        )
        // A still is its own thumbnail; generating a second copy would double
        // the disk cost of every photo for no benefit.
        record.thumbnailFileName = name

        container.mainContext.insert(record)
        try? container.mainContext.save()
        return record
    }

    /// Doc 3 Phase 2 task 17.
    private static func generateThumbnail(for url: URL) async -> String? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 600, height: 600)

        // One second in, not zero: the first frame of a hand-held recording is
        // usually the moment the finger was still on the shutter.
        let time = CMTime(seconds: 1, preferredTimescale: 600)

        guard let cgImage = try? await generator.image(at: time).image,
              let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.8)
        else { return nil }

        let name = url.deletingPathExtension().lastPathComponent + "-thumb.jpg"
        let destination = RecordingController.mediaDirectory.appending(path: name)
        try? data.write(to: destination)
        return name
    }

    /// Deletes a record and every file it owns.
    func delete(_ record: CaptureRecord) {
        Self.deleteFiles(for: record)
        container.mainContext.delete(record)
        try? container.mainContext.save()
    }

    /// Removes a record's files without touching the store.
    ///
    /// Split out because the gallery deletes through `@Environment(\.modelContext)`
    /// rather than through this type, and a record removed from the store while
    /// its files stay on disk is a silent leak the user can never clear.
    static func deleteFiles(for record: CaptureRecord) {
        let manager = FileManager.default
        try? manager.removeItem(at: record.compositedURL)
        if let thumbnail = record.thumbnailURL, thumbnail != record.compositedURL {
            try? manager.removeItem(at: thumbnail)
        }
        for name in [record.primarySourceFileName, record.secondarySourceFileName].compactMap({ $0 }) {
            try? manager.removeItem(at: RecordingController.mediaDirectory.appending(path: name))
        }
    }
}
