import AVFAudio
import OpenClawKit
import OSLog
import Speech

/// Speech recognition provider backed by Apple's `SFSpeechRecognizer`.
///
/// Installs an audio tap on the provided engine's input node, feeds buffers
/// to a `SFSpeechAudioBufferRecognitionRequest`, and emits partial/final
/// transcription segments via an `AsyncStream`.
@MainActor
final class AppleSpeechRecognitionProvider: SpeechRecognitionProviding {

    let capabilities = SpeechRecognitionCapabilities(
        providesEndOfUtterance: false,
        providesPartialResults: true,
        requiresModelDownload: false,
        requiresSpeechPermission: true
    )

    private(set) var micLevel: Double = 0
    private(set) var lastAudioActivity: Date = .distantPast

    // MARK: - Private state

    private let logger = Logger(subsystem: "ai.openclaw", category: "AppleSTT")

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var inputTapInstalled = false
    private var audioEngine: AVAudioEngine?

    // Noise floor calibration
    private var noiseFloorSamples: [Double] = []
    private var noiseFloor: Double?
    private var noiseFloorReady: Bool = false

    // MARK: - SpeechRecognitionProviding

    func startRecognition(
        audioEngine: AVAudioEngine,
        options: SpeechRecognitionOptions
    ) async throws -> AsyncStream<SpeechRecognitionSegment> {
        stopRecognition()

        self.audioEngine = audioEngine

        let recognizer = SFSpeechRecognizer(locale: options.locale)
        guard let recognizer else {
            throw SpeechRecognitionError.unavailable(reason: "SFSpeechRecognizer unavailable for locale \(options.locale.identifier)")
        }
        self.speechRecognizer = recognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = options.reportPartialResults
        request.taskHint = .dictation
        self.recognitionRequest = request

        GatewayDiagnostics.log("apple-stt: starting recognition locale=\(options.locale.identifier)")

        let input = audioEngine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw SpeechRecognitionError.audioFormatInvalid
        }

        // Remove any stale tap and install ours.
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            self?.processAudioBuffer(buffer)
        }
        self.inputTapInstalled = true

        audioEngine.prepare()
        try audioEngine.start()

        // Build the async stream driven by the recognition task callback.
        let (stream, continuation) = AsyncStream<SpeechRecognitionSegment>.makeStream()

        self.recognitionTask = recognizer.recognitionTask(with: request) { result, error in
            if let error {
                let msg = error.localizedDescription
                let lowered = msg.lowercased()
                let isCancellation = lowered.contains("cancelled") || lowered.contains("canceled")
                if isCancellation {
                    GatewayDiagnostics.log("apple-stt: cancelled")
                    continuation.finish()
                    return
                }
                GatewayDiagnostics.log("apple-stt: error=\(msg)")
                // On non-cancellation errors, finish the stream so the consumer
                // can decide whether to restart (transient) or surface the error.
                continuation.finish()
                return
            }
            guard let result else { return }
            let text = result.bestTranscription.formattedString
            let segment = SpeechRecognitionSegment(
                text: text,
                isFinal: result.isFinal,
                endOfUtterance: false
            )
            continuation.yield(segment)
        }

        continuation.onTermination = { [weak self] _ in
            // Safety net: if the stream consumer drops, stop the task.
            Task { @MainActor in
                self?.recognitionTask?.cancel()
            }
        }

        GatewayDiagnostics.log(
            "apple-stt: recognition started engineRunning=\(audioEngine.isRunning)"
        )

        return stream
    }

    func stopRecognition() {
        self.recognitionTask?.cancel()
        self.recognitionTask = nil
        self.recognitionRequest?.endAudio()
        self.recognitionRequest = nil
        self.micLevel = 0
        self.lastAudioActivity = .distantPast
        self.noiseFloorSamples.removeAll(keepingCapacity: true)
        self.noiseFloor = nil
        self.noiseFloorReady = false
        if self.inputTapInstalled, let engine = self.audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            self.inputTapInstalled = false
        }
        // Note: we do NOT stop the audioEngine here. The host (TalkModeManager)
        // owns the engine and is responsible for starting/stopping it.
        self.speechRecognizer = nil
        self.audioEngine = nil
    }

    // MARK: - Audio buffer processing (RMS + noise floor)

    /// Called from the audio tap (real-time thread). Computes RMS and dispatches
    /// mic-level / noise-floor updates back to the main actor.
    private nonisolated func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        let frames = buffer.frameLength
        guard frames > 0, let data = buffer.floatChannelData?.pointee else { return }

        // RMS calculation (inlined to keep the provider self-contained).
        let n = Int(frames)
        var sum: Float = 0
        for i in 0..<n {
            let v = data[i]
            sum += v * v
        }
        let rms = sqrt(sum / Float(n))

        Task { @MainActor [weak self] in
            self?.updateLevels(rms: rms)
        }
    }

    /// Update mic level and noise floor state on the main actor.
    private func updateLevels(rms: Float) {
        // Smooth + clamp for UI (mirrors TalkModeManager's existing logic).
        let raw = max(0, min(Double(rms) * 10.0, 1.0))
        let next = (self.micLevel * 0.80) + (raw * 0.20)
        self.micLevel = next

        // Dynamic noise-floor calibration: collect 22 initial samples, take
        // sorted median of lower half, then threshold = clamp(avg + 0.10, 0.12, 0.35).
        if !self.noiseFloorReady {
            self.noiseFloorSamples.append(raw)
            if self.noiseFloorSamples.count >= 22 {
                let sorted = self.noiseFloorSamples.sorted()
                let take = max(6, sorted.count / 2)
                let slice = sorted.prefix(take)
                let avg = slice.reduce(0.0, +) / Double(slice.count)
                self.noiseFloor = avg
                self.noiseFloorReady = true
                self.noiseFloorSamples.removeAll(keepingCapacity: true)
                let threshold = min(0.35, max(0.12, avg + 0.10))
                GatewayDiagnostics.log(
                    "apple-stt: noiseFloor=\(String(format: "%.3f", avg)) "
                        + "threshold=\(String(format: "%.3f", threshold))"
                )
            }
        }

        let threshold: Double = if let floor = self.noiseFloor, self.noiseFloorReady {
            min(0.35, max(0.12, floor + 0.10))
        } else {
            0.18
        }
        if raw >= threshold {
            self.lastAudioActivity = Date()
        }
    }
}
