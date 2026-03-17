import Foundation
import OpenClawKit
import FluidAudio
import CoreML

@Observable
@MainActor
final class ParakeetModelManager: LocalModelManaging {

    // MARK: - LocalModelManaging

    let availableModels: [LocalModelInfo] = [
        LocalModelInfo(
            id: "parakeet-v3",
            displayName: "Parakeet V3",
            description: "Multilingual, 25+ languages",
            sizeBytes: 461_000_000  // ~461 MB
        )
    ]

    private(set) var modelStates: [String: LocalModelState] = [:]

    // MARK: - Init

    init() {
        for model in availableModels {
            modelStates[model.id] = checkModelState(modelId: model.id)
        }
    }

    // MARK: - Download

    func download(modelId: String) async throws {
        guard availableModels.contains(where: { $0.id == modelId }) else { return }
        modelStates[modelId] = .downloading(progress: 0)

        do {
            // Download Parakeet V3 ASR model
            try await AsrModels.download(
                version: .v3
            ) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.modelStates[modelId] = .downloading(progress: progress.fractionCompleted * 0.9)
                }
            }

            // Download silero-vad model (used for long utterance optimization).
            // VadManager expects models at <base>/Models/silero-vad-coreml/.
            // downloadRepo creates a silero-vad-coreml/ subdirectory inside the
            // given directory, so we pass the Models/ directory.
            modelStates[modelId] = .downloading(progress: 0.95)
            let vadModelsDir = vadBaseDirectory().appendingPathComponent("Models")
            try await DownloadUtils.downloadRepo(.vad, to: vadModelsDir)

            modelStates[modelId] = .ready
        } catch {
            modelStates[modelId] = .error(error.localizedDescription)
            throw error
        }
    }

    // MARK: - Delete

    func delete(modelId: String) async throws {
        let fm = FileManager.default

        // Delete Parakeet V3
        let asrDir = AsrModels.defaultCacheDirectory(for: .v3)
        if fm.fileExists(atPath: asrDir.path) {
            try fm.removeItem(at: asrDir)
        }

        // Delete silero-vad
        let vadDir = vadBaseDirectory().appendingPathComponent("Models/silero-vad-coreml")
        if fm.fileExists(atPath: vadDir.path) {
            try fm.removeItem(at: vadDir)
        }

        modelStates[modelId] = .notDownloaded
    }

    // MARK: - Model URL

    func modelURL(for modelId: String) -> URL? {
        let dir = AsrModels.defaultCacheDirectory(for: .v3)
        guard AsrModels.modelsExist(at: dir, version: .v3) else { return nil }
        return dir
    }

    /// Whether the silero-vad model is available on disk.
    var isVadModelReady: Bool {
        let vadDir = vadBaseDirectory().appendingPathComponent("Models/silero-vad-coreml")
        return FileManager.default.fileExists(atPath: vadDir.path)
    }

    // MARK: - Private

    private func checkModelState(modelId: String) -> LocalModelState {
        let dir = AsrModels.defaultCacheDirectory(for: .v3)
        return AsrModels.modelsExist(at: dir, version: .v3) ? .ready : .notDownloaded
    }

    /// Base directory for FluidAudio models (Application Support/FluidAudio).
    /// VadManager looks for models at <base>/Models/silero-vad-coreml/.
    private func vadBaseDirectory() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("FluidAudio", isDirectory: true)
    }
}
