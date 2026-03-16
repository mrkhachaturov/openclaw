import Foundation
import Testing
@testable import OpenClaw

@MainActor
@Suite struct TalkModeManagerTests {
    @Test func detectsPCMFormatRejectionFromElevenLabsError() {
        let error = NSError(
            domain: "ElevenLabsTTS",
            code: 403,
            userInfo: [
                NSLocalizedDescriptionKey: "ElevenLabs failed: 403 subscription_required output_format=pcm_44100",
            ])
        #expect(TalkModeManager._test_isPCMFormatRejectedByAPI(error))
    }

    @Test func ignoresGenericPlaybackFailuresForPCMFormatRejection() {
        let error = NSError(
            domain: "StreamingAudio",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "queue enqueue failed"])
        #expect(TalkModeManager._test_isPCMFormatRejectedByAPI(error) == false)
    }
}

@Suite struct TalkModeGatewayConfigParserTests {
    @Test func parsesBaseUrlFromResolvedConfig() {
        let config: [String: Any] = [
            "talk": [
                "resolved": [
                    "provider": "openai",
                    "config": [
                        "apiKey": "sk-test",
                        "voiceId": "ash",
                        "modelId": "gpt-4o-mini-tts",
                        "baseUrl": "https://proxy.example.com/v1",
                    ],
                ] as [String: Any],
            ] as [String: Any],
        ]
        let parsed = TalkModeGatewayConfigParser.parse(
            config: config,
            defaultProvider: "elevenlabs",
            defaultModelIdFallback: "eleven_v3",
            defaultSilenceTimeoutMs: 1200)
        #expect(parsed.activeProvider == "openai")
        #expect(parsed.baseUrl == "https://proxy.example.com/v1")
    }

    @Test func parsesInstructionsFromResolvedConfig() {
        let config: [String: Any] = [
            "talk": [
                "resolved": [
                    "provider": "openai",
                    "config": [
                        "apiKey": "sk-test",
                        "voiceId": "alloy",
                        "modelId": "gpt-4o-mini-tts",
                        "instructions": "Speak calmly",
                    ],
                ] as [String: Any],
            ] as [String: Any],
        ]
        let parsed = TalkModeGatewayConfigParser.parse(
            config: config,
            defaultProvider: "elevenlabs",
            defaultModelIdFallback: "eleven_v3",
            defaultSilenceTimeoutMs: 1200)
        #expect(parsed.instructions == "Speak calmly")
    }

    @Test func baseUrlAndInstructionsAreNilWhenMissing() {
        let config: [String: Any] = [
            "talk": [
                "resolved": [
                    "provider": "elevenlabs",
                    "config": [
                        "voiceId": "abc123",
                        "modelId": "eleven_v3",
                    ],
                ] as [String: Any],
            ] as [String: Any],
        ]
        let parsed = TalkModeGatewayConfigParser.parse(
            config: config,
            defaultProvider: "elevenlabs",
            defaultModelIdFallback: "eleven_v3",
            defaultSilenceTimeoutMs: 1200)
        #expect(parsed.baseUrl == nil)
        #expect(parsed.instructions == nil)
    }
}
