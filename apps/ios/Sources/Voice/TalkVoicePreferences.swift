import Foundation

/// Per-agent TTS voice overrides stored in UserDefaults.
///
/// Each agent can have a custom voiceId and instructions for OpenAI TTS.
/// When no override is set, the gateway default is used.
enum TalkVoicePreferences {

    private nonisolated(unsafe) static let defaults = UserDefaults.standard
    private static let voicePrefix = "talkVoice."
    private static let instructionsPrefix = "talkInstructions."

    /// Available OpenAI TTS voices.
    /// Full list: https://platform.openai.com/docs/guides/text-to-speech
    /// Preview: https://openai.fm
    static let availableVoices = [
        "alloy", "ash", "ballad", "cedar", "coral", "echo",
        "fable", "marin", "nova", "onyx", "sage", "shimmer", "verse"
    ]

    // MARK: - Voice ID

    static func voiceId(for agentId: String) -> String? {
        defaults.string(forKey: voicePrefix + agentId)
    }

    static func setVoiceId(_ voiceId: String?, for agentId: String) {
        if let voiceId, !voiceId.isEmpty {
            defaults.set(voiceId, forKey: voicePrefix + agentId)
        } else {
            defaults.removeObject(forKey: voicePrefix + agentId)
        }
    }

    // MARK: - Instructions

    static func instructions(for agentId: String) -> String? {
        defaults.string(forKey: instructionsPrefix + agentId)
    }

    static func setInstructions(_ instructions: String?, for agentId: String) {
        if let instructions, !instructions.isEmpty {
            defaults.set(instructions, forKey: instructionsPrefix + agentId)
        } else {
            defaults.removeObject(forKey: instructionsPrefix + agentId)
        }
    }

    // MARK: - Reset

    static func reset(for agentId: String) {
        defaults.removeObject(forKey: voicePrefix + agentId)
        defaults.removeObject(forKey: instructionsPrefix + agentId)
    }
}
