import SwiftUI
import OpenClawKit

struct SpeechRecognitionSettingsView: View {
    @Environment(NodeAppModel.self) private var appModel
    @State private var activeProvider = SpeechRecognitionPreferences.activeProvider

    private var parakeetReady: Bool {
        if case .ready = appModel.talkMode.parakeetModelManager.modelStates["parakeet-v3"] {
            return true
        }
        return false
    }

    var body: some View {
        Section("Speech Recognition") {
            Picker("Provider", selection: $activeProvider) {
                Text("Apple (Built-in)").tag(SpeechRecognitionProviderKind.apple)
                Text("Parakeet V3").tag(SpeechRecognitionProviderKind.parakeet)
            }
            .disabled(!parakeetReady && activeProvider == .apple)
            .onChange(of: activeProvider) { _, newValue in
                // Prevent selecting Parakeet if model not downloaded
                if newValue == .parakeet, !parakeetReady {
                    activeProvider = .apple
                    return
                }
                SpeechRecognitionPreferences.activeProvider = newValue
            }

            ForEach(appModel.talkMode.parakeetModelManager.availableModels) { model in
                LocalModelRow(
                    model: model,
                    state: appModel.talkMode.parakeetModelManager.modelStates[model.id] ?? .notDownloaded
                ) {
                    Task {
                        try? await appModel.talkMode.parakeetModelManager.download(modelId: model.id)
                    }
                } onDelete: {
                    Task {
                        try? await appModel.talkMode.parakeetModelManager.delete(modelId: model.id)
                        // Reset to Apple if active model was deleted
                        if activeProvider == .parakeet {
                            activeProvider = .apple
                            SpeechRecognitionPreferences.activeProvider = .apple
                        }
                    }
                }
            }
        }
    }
}

private struct LocalModelRow: View {
    let model: LocalModelInfo
    let state: LocalModelState
    let onDownload: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                    .font(.body)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            switch state {
            case .notDownloaded:
                Button(action: onDownload) {
                    Image(systemName: "icloud.and.arrow.down")
                        .font(.title3)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)

            case .downloading(let progress):
                ProgressView(value: progress)
                    .frame(width: 40)

            case .ready:
                Button(action: onDelete) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)

            case .error(let message):
                Button(action: onDownload) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title3)
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help(message)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        let size = ByteCountFormatter.string(fromByteCount: model.sizeBytes, countStyle: .file)
        switch state {
        case .notDownloaded:
            return "\(model.description) (\(size)) — Tap to download"
        case .ready:
            return "\(model.description) (\(size)) — Tap to remove"
        default:
            return "\(model.description) (\(size))"
        }
    }
}
