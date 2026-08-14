import AVKit
import SwiftData
import SwiftUI

/// The app's own captures (Doc 2 §12.1).
///
/// Deliberately not the system photo library: Doc 1 §4.3 scopes this to
/// "app-captured media", and Doc 2 §12.1's dual-source badge only means
/// anything for files this app produced.
struct GalleryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \CaptureRecord.createdAt, order: .reverse) private var captures: [CaptureRecord]

    @State private var selection: CaptureRecord?
    @State private var isSelecting = false
    @State private var selectedIDs: Set<UUID> = []
    @Namespace private var zoom

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        NavigationStack {
            Group {
                if captures.isEmpty {
                    emptyState
                } else {
                    grid
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Captures")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .fullScreenCover(item: $selection) { record in
                CaptureDetailView(record: record, namespace: zoom)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(captures) { record in
                    GalleryCell(
                        record: record,
                        isSelected: selectedIDs.contains(record.id),
                        isSelecting: isSelecting,
                        namespace: zoom
                    )
                    .onTapGesture {
                        if isSelecting {
                            toggle(record)
                        } else {
                            selection = record
                        }
                    }
                    .contextMenu { contextMenu(for: record) }
                }
            }
            .padding(2)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(DC.Color.chromeTertiary)
            Text("Nothing captured yet")
                .font(DC.Font.sheetBody)
                .foregroundStyle(DC.Color.chromeSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Done") { dismiss() }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if captures.isEmpty {
                EmptyView()
            } else if isSelecting {
                Button("Delete (\(selectedIDs.count))", role: .destructive) {
                    deleteSelected()
                }
                .disabled(selectedIDs.isEmpty)
            } else {
                Button("Select") { isSelecting = true }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for record: CaptureRecord) -> some View {
        ShareLink(item: record.compositedURL) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        Button {
            Task { await PhotoLibraryExporter.saveToPhotos(record.compositedURL, isPhoto: record.isPhoto) }
        } label: {
            Label("Save to Photos", systemImage: "photo.badge.arrow.down")
        }
        if record.hasCleanSources {
            Button {
                selection = record
            } label: {
                Label("Show clean sources", systemImage: "rectangle.on.rectangle")
            }
        }
        Button(role: .destructive) {
            delete(record)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func toggle(_ record: CaptureRecord) {
        if selectedIDs.contains(record.id) {
            selectedIDs.remove(record.id)
        } else {
            selectedIDs.insert(record.id)
        }
    }

    private func delete(_ record: CaptureRecord) {
        CaptureLibrary.deleteFiles(for: record)
        context.delete(record)
        try? context.save()
    }

    private func deleteSelected() {
        for record in captures where selectedIDs.contains(record.id) {
            CaptureLibrary.deleteFiles(for: record)
            context.delete(record)
        }
        try? context.save()
        selectedIDs.removeAll()
        isSelecting = false
    }
}

// MARK: - Cell

private struct GalleryCell: View {
    let record: CaptureRecord
    let isSelected: Bool
    let isSelecting: Bool
    let namespace: Namespace.ID

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                ThumbnailImage(url: record.thumbnailURL)
                    .matchedGeometryEffect(id: record.id, in: namespace)
            }
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                if !record.isPhoto {
                    Text(record.formattedDuration)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            LinearGradient(
                                colors: [.clear, .black.opacity(0.6)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .padding(3)
                }
            }
            .overlay(alignment: .topTrailing) {
                // Doc 2 §12.1: dual-source captures carry a badge.
                if record.hasCleanSources {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.black.opacity(0.35), in: Circle())
                        .padding(3)
                }
            }
            .overlay {
                if isSelecting {
                    ZStack(alignment: .topLeading) {
                        Color.black.opacity(isSelected ? 0.35 : 0)
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isSelected ? DC.Color.accent : .white.opacity(0.8))
                            .padding(6)
                    }
                }
            }
    }
}

/// Loads a thumbnail off the main thread and caches it.
///
/// Doc 3 Phase 6's criterion is 500+ items scrolling smoothly with no flicker,
/// which rules out decoding on the main actor and rules out re-decoding on
/// every cell recycle.
struct ThumbnailImage: View {
    let url: URL?

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(DC.Color.chromeTertiary.opacity(0.25))
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else { return }
        if let cached = ThumbnailCache.shared.image(for: url) {
            image = cached
            return
        }
        let loaded = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return UIImage(data: data)
        }.value
        guard let loaded else { return }
        ThumbnailCache.shared.store(loaded, for: url)
        image = loaded
    }
}

/// A bounded in-memory cache. `NSCache` evicts under pressure by itself, which
/// is the behaviour a gallery of hundreds of 600px JPEGs needs.
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSURL, UIImage>()

    private init() {
        cache.countLimit = 300
    }

    func image(for url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }
    func store(_ image: UIImage, for url: URL) { cache.setObject(image, forKey: url as NSURL) }
}
