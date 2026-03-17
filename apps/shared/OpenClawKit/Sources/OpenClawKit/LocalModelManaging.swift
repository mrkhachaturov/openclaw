import Foundation

/// State of a downloadable local model.
public enum LocalModelState: Sendable {
    case notDownloaded
    case downloading(progress: Double)  // 0.0…1.0
    case ready
    case error(String)
}

/// Metadata for a downloadable model.
public struct LocalModelInfo: Sendable, Identifiable {
    public let id: String             // e.g. "parakeet-v3"
    public let displayName: String    // e.g. "Parakeet V3"
    public let description: String    // e.g. "Multilingual, 25+ languages"
    public let sizeBytes: Int64       // for display (e.g. 461 MB)

    public init(id: String, displayName: String, description: String, sizeBytes: Int64) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.sizeBytes = sizeBytes
    }
}

/// Manages download and lifecycle of on-device ML models.
/// Conforming types should be annotated with `@Observable` for SwiftUI integration.
@MainActor
public protocol LocalModelManaging: AnyObject {
    /// All models this manager knows about.
    var availableModels: [LocalModelInfo] { get }

    /// Current state per model ID.
    var modelStates: [String: LocalModelState] { get }

    /// Download a model. Progress updates flow through `modelStates`.
    func download(modelId: String) async throws

    /// Delete a downloaded model to reclaim disk space.
    func delete(modelId: String) async throws

    /// Local file URL for a ready model. Returns nil if not downloaded.
    func modelURL(for modelId: String) -> URL?
}
