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

        // The audio tap runs on a real-time thread. In Swift 6, ANY closure
        // formed inside a @MainActor function that captures local variables
        // gets a runtime isolation check — crashing on the audio thread.
        // Solution: install the tap from a nonisolated static function so the
        // closure is formed outside any actor context.
        let tapHandler = AudioTapHandler(request: request, provider: self)
        input.removeTap(onBus: 0)
        Self.installTap(on: input, format: format, handler: tapHandler)
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
        self.speechRecognizer = nil
        self.audioEngine = nil
    }

    // MARK: - Tap installation (nonisolated to avoid actor isolation in closure)

    /// Must be nonisolated so the closure is formed outside @MainActor context.
    /// Otherwise Swift 6 inserts runtime isolation checks that crash on the audio thread.
    nonisolated private static func installTap(
        on input: AVAudioInputNode,
        format: AVAudioFormat,
        handler: AudioTapHandler
    ) {
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            handler.handle(buffer: buffer)
        }
    }

    // MARK: - Audio level + noise floor

    /// Update mic level and noise floor state on the main actor.
    fileprivate func updateLevels(rms: Float) {
        let raw = max(0, min(Double(rms) * 10.0, 1.0))
        let next = (self.micLevel * 0.80) + (raw * 0.20)
        self.micLevel = next

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

// MARK: - Audio tap handler (@unchecked Sendable)

/// Wraps everything the audio tap closure needs into a single @unchecked Sendable
/// type so nothing from the @MainActor context is captured directly by the tap.
/// This is the standard pattern for bridging real-time audio threads to Swift actors.
private final class AudioTapHandler: @unchecked Sendable {
    private let request: SFSpeechAudioBufferRecognitionRequest
    private weak var provider: AppleSpeechRecognitionProvider?

    init(request: SFSpeechAudioBufferRecognitionRequest, provider: AppleSpeechRecognitionProvider) {
        self.request = request
        self.provider = provider
    }

    func handle(buffer: AVAudioPCMBuffer) {
        request.append(buffer)

        guard let data = buffer.floatChannelData?.pointee else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        var sum: Float = 0
        for i in 0..<n {
            sum += data[i] * data[i]
        }
        let rms = sqrt(sum / Float(n))

        Task { @MainActor [weak provider] in
            provider?.updateLevels(rms: rms)
        }
    }
}
