import SwiftData

/// A throwaway in-memory container.
///
/// The gallery is driven by `@Query`, which needs *a* container even when the
/// real one failed to open. Rendering an empty gallery is a better failure than
/// crashing on a missing environment value.
enum PreviewContainers {
    static let empty: ModelContainer = {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        // Force-try is acceptable here and nowhere else: an in-memory container
        // with a valid schema cannot fail, and the alternative is an optional
        // that every call site would have to unwrap for a case that cannot
        // happen.
        return try! ModelContainer(for: CaptureRecord.self, configurations: configuration)
    }()
}
