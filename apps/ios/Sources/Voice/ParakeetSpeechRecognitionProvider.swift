import AVFoundation
import OpenClawKit
import FluidAudio
import CoreML
import OSLog

/// Speech recognition provider backed by FluidAudio's Parakeet V3 TDT model.
///
/// Uses the multilingual V3 model (25+ languages, 461 MB) with `AsrManager`
/// for batch transcription. Audio is accumulated continuously; the full buffer
/// is periodically re-transcribed (without resetting) to keep TalkModeManager's
/// `lastTranscript` and `lastHeard` current. FluidAudio's `AsrManager` handles
/// any length: for audio >240K samples (~15s), its internal `ChunkProcessor`
/// splits with 2s overlap and merges via LCS token matching.
///
/// Model and manager are cached across utterances — only loaded once per session.
/// For long utterances (>20s), VAD strips silence before transcription to reduce
/// processing time.
///
/// End-of-utterance is handled by TalkModeManager's silence monitor
/// (this provider sets `providesEndOfUtterance: false`).
@MainActor
final class ParakeetSpeechRecognitionProvider: SpeechRecognitionProviding {

    // MARK: - SpeechRecognitionProviding

    let capabilities = SpeechRecognitionCapabilities(
        providesEndOfUtterance: false,   // TalkModeManager handles silence detection
        providesPartialResults: false,    // batch model — one result at end of utterance
        requiresModelDownload: true,
        requiresSpeechPermission: false
    )

    private(set) var micLevel: Double = 0
    private(set) var lastAudioActivity: Date = .distantPast

    // MARK: - Private

    private let logger = Logger(subsystem: "ai.openclaw", category: "ParakeetSTT")

    /// Cached across utterances — only cleaned up when provider is deallocated
    /// or model changes. Avoids ~150ms+ reload on every utterance.
    private var cachedModels: AsrModels?
    private var asrManager: AsrManager?
    private var vadManager: VadManager?

    private var tapInstalled = false
    private var processTask: Task<Void, Never>?
    private var audioEngine: AVAudioEngine?
    private let modelManager: ParakeetModelManager

    // Noise floor calibration — same approach as AppleSpeechRecognitionProvider.
    // Collects first ~22 RMS samples, takes the lower half average as the floor,
    // then sets threshold = floor + 0.10 (clamped 0.12–0.35). Only RMS above
    // this threshold updates lastAudioActivity, preventing background noise from
    // keeping the silence detector at bay.
    private var noiseFloorSamples: [Double] = []
    private var noiseFloor: Double?
    private var noiseFloorReady = false

    /// Thread-safe queue for passing audio buffers from the real-time tap.
    private let bufferQueue = BufferQueue()

    /// Accumulates audio samples for the entire utterance.
    private var audioAccumulator = AudioAccumulator()

    init(modelManager: ParakeetModelManager) {
        self.modelManager = modelManager
    }

    // MARK: - Model & Manager Caching

    /// Returns a ready AsrManager, reusing cached models and manager across utterances.
    /// Only reloads if not yet initialized.
    private func ensureManagerReady() async throws -> AsrManager {
        if let manager = asrManager {
            return manager
        }

        guard let modelDir = modelManager.modelURL(for: "parakeet-v3") else {
            throw SpeechRecognitionError.modelNotReady
        }

        // Reuse cached models if available
        let models: AsrModels
        if let cached = cachedModels {
            models = cached
            GatewayDiagnostics.log("parakeet-stt: reusing cached V3 models")
        } else {
            GatewayDiagnostics.log("parakeet-stt: loading V3 TDT model from \(modelDir.lastPathComponent)")
            models = try await AsrModels.load(from: modelDir, version: .v3)
            cachedModels = models
        }

        let manager = AsrManager()
        try await manager.initialize(models: models)
        self.asrManager = manager

        GatewayDiagnostics.log("parakeet-stt: AsrManager ready")
        return manager
    }

    // MARK: - Start Recognition

    func startRecognition(
        audioEngine: AVAudioEngine,
        options: SpeechRecognitionOptions
    ) async throws -> AsyncStream<SpeechRecognitionSegment> {
        stopRecognition()

        self.audioEngine = audioEngine

        // 1. Get or reuse AsrManager (cached across utterances)
        let manager = try await ensureManagerReady()

        // 2. Build the AsyncStream
        let (stream, continuation) = AsyncStream<SpeechRecognitionSegment>.makeStream()

        // 3. Install audio tap
        let inputNode = audioEngine.inputNode
        let hwFormat = inputNode.inputFormat(forBus: 0)

        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            throw SpeechRecognitionError.audioFormatInvalid
        }

        inputNode.removeTap(onBus: 0)
        Self.installTap(on: inputNode, format: hwFormat, bufferQueue: self.bufferQueue)
        tapInstalled = true

        // 4. Start audio engine if not running
        if !audioEngine.isRunning {
            audioEngine.prepare()
            try audioEngine.start()
        }

        // 5. Audio converter for 48kHz → 16kHz mono
        let converter = AudioConverter()

        // 6. Processing task — accumulates audio and periodically re-transcribes
        // the FULL buffer (without resetting). This keeps TalkModeManager's
        // lastTranscript/lastHeard current so silence detection works.
        //
        // Key difference from naive chunking: we never reset the accumulator.
        // Each transcription covers ALL audio from the start. FluidAudio's
        // ChunkProcessor handles >240K samples with 2s overlap + LCS merging.
        // For long utterances (>20s), VAD strips silence to reduce processing.
        //
        // The await transcribe() also serves as the suspension point that lets
        // stopRecognition() execute on the main actor.
        processTask = Task { [weak self] in
            guard let self else { return }

            var lastTranscribeTime = Date()
            var lastYieldedText = ""

            while !Task.isCancelled {
                if let (buffer, rms) = self.bufferQueue.dequeue() {
                    self.updateMicLevel(rms: rms)

                    if let samples = try? converter.resampleBuffer(buffer) {
                        self.audioAccumulator.append(samples)
                    }

                    // Periodically transcribe the full accumulated audio.
                    // Wait at least 2s between transcriptions and require >1s of audio.
                    let elapsed = Date().timeIntervalSince(lastTranscribeTime)
                    let sampleCount = self.audioAccumulator.sampleCount

                    if elapsed >= 2.0, sampleCount > 16000 {
                        lastTranscribeTime = Date()

                        var speechAudio = self.audioAccumulator.allSamples()
                        let durationSeconds = Double(speechAudio.count) / 16000.0

                        // VAD for long audio — strip silence to reduce processing
                        if durationSeconds >= 20.0 {
                            speechAudio = await self.stripSilence(from: speechAudio, durationSeconds: durationSeconds)
                        }

                        // Trailing silence for final punctuation
                        speechAudio += [Float](repeating: 0, count: 16_000)

                        do {
                            let result = try await manager.transcribe(speechAudio)
                            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                            // Only yield when text changes — unchanged yields would
                            // keep lastHeard fresh and prevent silence detection.
                            if !text.isEmpty, text != lastYieldedText {
                                lastYieldedText = text
                                GatewayDiagnostics.log("parakeet-stt: partial chars=\(text.count) duration=\(String(format: "%.1f", durationSeconds))s")
                                continuation.yield(SpeechRecognitionSegment(
                                    text: text,
                                    isFinal: false,
                                    endOfUtterance: false
                                ))
                            }
                        } catch {
                            if !Task.isCancelled {
                                GatewayDiagnostics.log("parakeet-stt: transcribe error=\(error.localizedDescription)")
                            }
                        }
                    }
                } else {
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
        }

        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                self?.stopRecognition()
            }
        }

        GatewayDiagnostics.log(
            "parakeet-stt: recognition started engineRunning=\(audioEngine.isRunning)"
        )

        return stream
    }

    // MARK: - VAD Silence Stripping

    /// Uses VadManager to remove silence segments from long audio.
    /// Falls back to the original audio if VAD fails.
    private func stripSilence(from samples: [Float], durationSeconds: Double) async -> [Float] {
        // Only use VAD if the silero-vad model is already downloaded.
        // Never trigger a download during speech — that would block the
        // main actor and cause false silence detection cutoffs.
        guard modelManager.isVadModelReady else {
            GatewayDiagnostics.log("parakeet-stt: VAD model not downloaded, skipping silence stripping")
            return samples
        }

        do {
            if vadManager == nil {
                let vadConfig = VadConfig(defaultThreshold: 0.7)
                vadManager = try await VadManager(config: vadConfig)
            }
            guard let vad = vadManager else { return samples }

            let segments = try await vad.segmentSpeechAudio(samples)
            guard !segments.isEmpty else { return samples }

            let speechAudio = segments.flatMap { $0 }
            let trimmedDuration = Double(speechAudio.count) / 16000.0
            GatewayDiagnostics.log("parakeet-stt: VAD trimmed \(String(format: "%.1f", durationSeconds))s → \(String(format: "%.1f", trimmedDuration))s")
            return speechAudio
        } catch {
            GatewayDiagnostics.log("parakeet-stt: VAD failed, using full audio: \(error.localizedDescription)")
            return samples
        }
    }

    // MARK: - Stop Recognition

    func stopRecognition() {
        processTask?.cancel()
        processTask = nil

        // Don't cleanup asrManager or cachedModels — reuse across utterances.

        if tapInstalled, let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        audioEngine = nil

        audioAccumulator.reset()
        noiseFloorSamples.removeAll(keepingCapacity: true)
        noiseFloor = nil
        noiseFloorReady = false
        micLevel = 0
        lastAudioActivity = .distantPast
    }

    // MARK: - Audio Level (with noise floor calibration)

    private func updateMicLevel(rms: Float) {
        let raw = max(0, min(Double(rms) * 10.0, 1.0))
        micLevel = (micLevel * 0.80) + (raw * 0.20)

        // Calibrate noise floor from first ~22 samples
        if !noiseFloorReady {
            noiseFloorSamples.append(raw)
            if noiseFloorSamples.count >= 22 {
                let sorted = noiseFloorSamples.sorted()
                let take = max(6, sorted.count / 2)
                let slice = sorted.prefix(take)
                let avg = slice.reduce(0.0, +) / Double(slice.count)
                noiseFloor = avg
                noiseFloorReady = true
                noiseFloorSamples.removeAll(keepingCapacity: true)
                let threshold = min(0.35, max(0.12, avg + 0.10))
                GatewayDiagnostics.log(
                    "parakeet-stt: noiseFloor=\(String(format: "%.3f", avg)) "
                        + "threshold=\(String(format: "%.3f", threshold))"
                )
            }
        }

        let threshold: Double = if let floor = noiseFloor, noiseFloorReady {
            min(0.35, max(0.12, floor + 0.10))
        } else {
            0.18
        }
        if raw >= threshold {
            lastAudioActivity = Date()
        }
    }

    // MARK: - Tap installation (nonisolated to avoid actor isolation in closure)

    nonisolated private static func installTap(
        on input: AVAudioInputNode,
        format: AVAudioFormat,
        bufferQueue: BufferQueue
    ) {
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            let rms = calculateRMS(buffer: buffer)
            bufferQueue.enqueue(buffer: buffer, rms: rms)
        }
    }

    // MARK: - RMS Calculation (nonisolated, safe for audio thread)

    nonisolated private static func calculateRMS(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }

        var sum: Float = 0
        let samples = channelData[0]
        for i in 0..<frameLength {
            sum += samples[i] * samples[i]
        }
        return sqrtf(sum / Float(frameLength))
    }
}

// MARK: - Thread-safe buffer queue

private final class BufferQueue: @unchecked Sendable {
    private var buffers: [(AVAudioPCMBuffer, Float)] = []
    private let lock = NSLock()

    func enqueue(buffer: AVAudioPCMBuffer, rms: Float) {
        lock.lock()
        buffers.append((buffer, rms))
        lock.unlock()
    }

    func dequeue() -> (AVAudioPCMBuffer, Float)? {
        lock.lock()
        defer { lock.unlock() }
        guard !buffers.isEmpty else { return nil }
        return buffers.removeFirst()
    }
}

// MARK: - Audio sample accumulator

/// Accumulates Float32 audio samples for batch transcription.
/// Not thread-safe — only accessed from the processing task on @MainActor.
private struct AudioAccumulator {
    private var samples: [Float] = []

    var sampleCount: Int { samples.count }

    mutating func append(_ newSamples: [Float]) {
        samples.append(contentsOf: newSamples)
    }

    func allSamples() -> [Float] {
        samples
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
    }
}
