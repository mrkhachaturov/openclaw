import SwiftUI

struct SpeechRecognitionSettingsView: View {
    @State private var activeProvider = SpeechRecognitionPreferences.activeProvider

    var body: some View {
        Section("Speech Recognition") {
            Picker("Provider", selection: $activeProvider) {
                Text("Apple (Built-in)").tag(SpeechRecognitionProviderKind.apple)
                Text("Parakeet V3").tag(SpeechRecognitionProviderKind.parakeet)
            }
            .onChange(of: activeProvider) { _, newValue in
                SpeechRecognitionPreferences.activeProvider = newValue
            }

            if activeProvider == .parakeet {
                Text("Local model support requires the Parakeet patch.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
