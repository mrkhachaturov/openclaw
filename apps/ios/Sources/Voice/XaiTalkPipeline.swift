import AVFAudio
import Foundation
import OpenClawKit
import OSLog
import xAISTTKit
import xAITTSKit

/// Bridges xAITTSKit + xAISTTKit into TalkModeManager.
///
/// One pipeline instance owns the live STT + TTS WebSocket sessions for the
/// xAI Talk Mode provider. The host (`TalkModeManager`) owns the
/// `AVAudioEngine` and audio session — the pipeline installs taps and
/// player nodes on top.
///
/// Auth: the gateway publishes the xAI OAuth bearer through `talk.config`
/// (resolved server-side from `auth-profiles.json`). The pipeline never
/// touches the OAuth profile directly.
@MainActor
final class XaiTalkPipeline {

    private let logger = Logger(subsystem: "ai.openclaw", category: "TalkMode.xAI")

    // STT
    private var sttTap: xAISTTAudioInputTap?
    private var sttSession: xAISTTWebSocketSession?
    private var sttPumpTask: Task<Void, Never>?
    private var sttEventsTask: Task<Void, Never>?
    private var sttRMSTask: Task<Void, Never>?

    // TTS
    private var ttsSession: xAITTSWebSocketSession?
    private var ttsPlayer: xAITTSAudioOutputPlayer?
    private var ttsConsumeTask: Task<Void, Never>?

    /// Live mic level (0…1), updated from the STT tap RMS stream.
    var micLevel: Float = 0

    /// True while a TTS turn is actively producing audio.
    private(set) var isSpeaking: Bool = false

    // MARK: - STT

    /// Open an STT WS session, install the mic tap, and stream transcripts
    /// to `onTranscript`. Continuous listening — call `stopSTT()` to tear
    /// down.
    ///
    /// `onTranscript(text, isFinal)` mirrors the shape of TalkModeManager's
    /// existing `handleTranscript` callback so the host barge-in /
    /// finalization logic doesn't need a separate code path.
    func startSTT(
        audioEngine: AVAudioEngine,
        bearer: String,
        language: xAISTTLanguage?,
        onTranscript: @escaping @MainActor (String, Bool) -> Void
    ) async throws {
        await self.stopSTT()

        let config = xAISTTWebSocketSession.Configuration(
            bearer: bearer,
            encoding: .pcm,
            sampleRate: 16_000,
            language: language,
            interimResults: true,
            endpointingMs: 700)
        self.logger.info("xai-stt: opening WS language=\(language?.rawValue ?? "auto", privacy: .public)")
        let session = try await xAISTTWebSocketSession.open(configuration: config)
        self.sttSession = session

        // Build the tap; it owns the AVAudioConverter so the input format
        // matches what the WS session expects (16 kHz PCM16 mono).
        let tap = xAISTTAudioInputTap(targetSampleRate: 16_000)
        try tap.install(on: audioEngine)
        self.sttTap = tap

        if !audioEngine.isRunning {
            audioEngine.prepare()
            try audioEngine.start()
        }

        // Pump PCM16 chunks into the WS session.
        self.sttPumpTask = Task { [weak self] in
            guard let chunks = self?.sttTap?.pcm16Chunks else { return }
            for await chunk in chunks {
                if Task.isCancelled { return }
                do {
                    try await session.send(audio: chunk)
                } catch {
                    self?.logger.error("xai-stt pump: \(error.localizedDescription, privacy: .public)")
                    return
                }
            }
        }

        // Update micLevel from RMS stream.
        self.sttRMSTask = Task { [weak self] in
            guard let rms = self?.sttTap?.rmsLevels else { return }
            for await level in rms {
                if Task.isCancelled { return }
                self?.micLevel = level
            }
        }

        // Consume transcripts and forward via callback.
        self.sttEventsTask = Task { [weak self] in
            do {
                for try await event in session.events {
                    if Task.isCancelled { return }
                    switch event {
                    case .ready:
                        self?.logger.debug("xai-stt: server ready")
                    case let .partial(t):
                        let trimmed = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { continue }
                        onTranscript(t.text, t.isFinal)
                    case let .done(t):
                        let trimmed = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { continue }
                        onTranscript(t.text, true)
                    case let .error(message):
                        self?.logger.error("xai-stt server error: \(message, privacy: .public)")
                    }
                }
            } catch {
                self?.logger.error("xai-stt events: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func stopSTT() async {
        self.sttPumpTask?.cancel()
        self.sttPumpTask = nil
        self.sttRMSTask?.cancel()
        self.sttRMSTask = nil
        self.sttEventsTask?.cancel()
        self.sttEventsTask = nil
        self.sttTap?.finish()
        self.sttTap = nil
        if let session = self.sttSession {
            await session.close()
        }
        self.sttSession = nil
        self.micLevel = 0
    }

    // MARK: - TTS

    /// Synthesize and play a full assistant turn through the xAI WS TTS
    /// session. Returns once the server signals `audio.done` and every
    /// queued PCM buffer has played through the output hardware.
    func speak(
        audioEngine: AVAudioEngine,
        text: String,
        bearer: String,
        language: xAITTSLanguage,
        voice: xAITTSVoice?
    ) async throws {
        await self.stopTTS()
        self.isSpeaking = true
        defer { self.isSpeaking = false }

        let config = xAITTSWebSocketSession.Configuration(
            bearer: bearer,
            language: language,
            voice: voice,
            codec: .pcm,
            sampleRate: 24_000,
            optimizeStreamingLatency: 1)
        self.logger.info(
            "xai-tts: opening WS voice=\(voice?.rawValue ?? "default", privacy: .public) lang=\(language.rawValue, privacy: .public)")
        let session = try await xAITTSWebSocketSession.open(configuration: config)
        self.ttsSession = session

        // Player: attach to the engine, then start engine if needed.
        let player = xAITTSAudioOutputPlayer(pcmSampleRate: 24_000)
        player.attach(to: audioEngine)
        if !audioEngine.isRunning {
            audioEngine.prepare()
            try audioEngine.start()
        }
        player.start()
        self.ttsPlayer = player

        // Send the full text then signal end-of-turn.
        try await session.send(text)
        try await session.endTurn()

        // Consume audio chunks; finish on audio.done or error.
        for try await event in session.events {
            if Task.isCancelled { break }
            switch event {
            case let .audio(bytes):
                player.play(pcm16Bytes: bytes)
            case .audioDone:
                await player.waitForPlaybackToDrain()
                await session.close()
                self.ttsSession = nil
                self.ttsPlayer = nil
                return
            case let .error(message):
                self.logger.error("xai-tts server error: \(message, privacy: .public)")
                await session.close()
                self.ttsSession = nil
                self.ttsPlayer = nil
                throw xAITTSError.http(status: 0, body: message)
            }
        }
    }

    /// Interrupt any in-flight TTS playback and close the WS session.
    func stopTTS() async {
        self.ttsConsumeTask?.cancel()
        self.ttsConsumeTask = nil
        if let player = self.ttsPlayer {
            player.interrupt()
        }
        self.ttsPlayer = nil
        if let session = self.ttsSession {
            await session.close()
        }
        self.ttsSession = nil
    }
}

// MARK: - Language mapping helpers

extension XaiTalkPipeline {
    /// Map a BCP-47 locale identifier (e.g. "ru-RU", "en") to the
    /// corresponding `xAISTTLanguage`. Returns `nil` for "auto" or
    /// unrecognized codes so the server picks the language.
    static func sttLanguage(from locale: String?) -> xAISTTLanguage? {
        guard let locale, !locale.isEmpty else { return nil }
        let normalized = locale.lowercased()
        if normalized == "auto" { return nil }
        let base = normalized.split(separator: "-").first.map(String.init) ?? normalized
        return xAISTTLanguage.allCases.first { $0.rawValue.lowercased() == base }
    }

    /// Map a BCP-47 locale identifier to the corresponding
    /// `xAITTSLanguage`. Returns `.auto` when no concrete match.
    static func ttsLanguage(from locale: String?) -> xAITTSLanguage {
        guard let locale, !locale.isEmpty, locale.lowercased() != "auto" else { return .auto }
        let normalized = locale.lowercased()
        if let match = xAITTSLanguage.allCases.first(where: { $0.rawValue.lowercased() == normalized }) {
            return match
        }
        let base = normalized.split(separator: "-").first.map(String.init) ?? normalized
        if let match = xAITTSLanguage.allCases.first(where: { $0.rawValue.lowercased() == base }) {
            return match
        }
        return .auto
    }

    /// Resolve a voice name like "rex" / "REX" to the typed `xAITTSVoice`.
    /// Returns `nil` for unknown names so the server uses its default.
    static func ttsVoice(from name: String?) -> xAITTSVoice? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return nil
        }
        return xAITTSVoice(rawValue: name.lowercased())
    }
}
