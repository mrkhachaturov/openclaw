import SwiftUI
import OpenClawKit
import OpenClawProtocol

/// Settings view for per-agent TTS voice overrides.
/// Shows all connected agents with voice and instructions pickers.
struct AgentVoiceSettingsView: View {
    @Environment(NodeAppModel.self) private var appModel

    private var isOpenAI: Bool {
        appModel.talkMode.activeProvider == "openai"
    }

    var body: some View {
        let agents = appModel.gatewayAgents
        if agents.isEmpty {
            Text("Connect to gateway to see agents")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            if !isOpenAI {
                Text("Voice override available for OpenAI provider only")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(agents, id: \.id) { agent in
                AgentVoiceRow(
                    agent: agent,
                    isActive: agent.id == appModel.selectedAgentId
                )
                .disabled(!isOpenAI)
            }
        }
    }
}

private struct AgentVoiceRow: View {
    let agent: AgentSummary
    let isActive: Bool

    @State private var selectedVoice: String
    @State private var instructions: String

    init(agent: AgentSummary, isActive: Bool) {
        self.agent = agent
        self.isActive = isActive
        _selectedVoice = State(
            initialValue: TalkVoicePreferences.voiceId(for: agent.id) ?? ""
        )
        _instructions = State(
            initialValue: TalkVoicePreferences.instructions(for: agent.id) ?? ""
        )
    }

    var body: some View {
        DisclosureGroup {
            Picker("Voice", selection: $selectedVoice) {
                Text("Default").tag("")
                ForEach(TalkVoicePreferences.availableVoices, id: \.self) { voice in
                    Text(voice.capitalized).tag(voice)
                }
            }
            .onChange(of: selectedVoice) { _, newValue in
                TalkVoicePreferences.setVoiceId(
                    newValue.isEmpty ? nil : newValue,
                    for: agent.id
                )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Instructions")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                TextField("e.g. Speak warmly, with pauses", text: $instructions, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
                    .font(.footnote)
                    .onChange(of: instructions) { _, newValue in
                        TalkVoicePreferences.setInstructions(
                            newValue.isEmpty ? nil : newValue,
                            for: agent.id
                        )
                    }
            }

            if !selectedVoice.isEmpty || !instructions.isEmpty {
                Button("Reset to Default", role: .destructive) {
                    TalkVoicePreferences.reset(for: agent.id)
                    selectedVoice = ""
                    instructions = ""
                }
                .font(.footnote)
            }
        } label: {
            HStack {
                Text(agent.name ?? agent.id)
                    .font(.body)
                if isActive {
                    Text("Active")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.blue.opacity(0.15))
                        .foregroundStyle(.blue)
                        .clipShape(Capsule())
                }
                Spacer()
                if TalkVoicePreferences.voiceId(for: agent.id) != nil {
                    Text(TalkVoicePreferences.voiceId(for: agent.id)!)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
