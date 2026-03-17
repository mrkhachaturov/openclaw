import AVFoundation

/// A segment of recognized speech.
public struct SpeechRecognitionSegment: Sendable {
    /// The recognized text (partial or final).
    public let text: String
    /// Whether this is a finalized result (won't change further).
    public let isFinal: Bool
    /// Whether the provider detected end of utterance (silence after speech).
    /// When true, `text` contains the complete utterance and `isFinal` is also true.
    public let endOfUtterance: Bool

    public init(text: String, isFinal: Bool, endOfUtterance: Bool) {
        self.text = text
        self.isFinal = isFinal
        self.endOfUtterance = endOfUtterance
    }
}

/// Typed errors for speech recognition providers.
public enum SpeechRecognitionError: Error, LocalizedError {
    case permissionDenied
    case unavailable(reason: String)
    case modelNotReady
    case audioFormatInvalid
    case recognitionFailed(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied: "Speech recognition permission denied"
        case .unavailable(let reason): "Speech recognizer unavailable: \(reason)"
        case .modelNotReady: "Speech recognition model not downloaded"
        case .audioFormatInvalid: "Invalid audio input format"
        case .recognitionFailed(let err): "Recognition failed: \(err.localizedDescription)"
        }
    }
}

/// Capabilities a provider declares so the host can adapt behavior.
public struct SpeechRecognitionCapabilities: Sendable {
    /// Provider has built-in end-of-utterance / silence detection.
    public let providesEndOfUtterance: Bool
    /// Provider emits partial (interim) results as speech is recognized.
    public let providesPartialResults: Bool
    /// Provider requires a downloaded model before use.
    public let requiresModelDownload: Bool
    /// Provider requires Apple Speech framework authorization.
    /// False for local-only providers (Parakeet) that bypass SFSpeechRecognizer.
    public let requiresSpeechPermission: Bool

    public init(
        providesEndOfUtterance: Bool,
        providesPartialResults: Bool,
        requiresModelDownload: Bool,
        requiresSpeechPermission: Bool
    ) {
        self.providesEndOfUtterance = providesEndOfUtterance
        self.providesPartialResults = providesPartialResults
        self.requiresModelDownload = requiresModelDownload
        self.requiresSpeechPermission = requiresSpeechPermission
    }
}

/// Options passed to a provider when starting recognition.
public struct SpeechRecognitionOptions: Sendable {
    /// Preferred locale for recognition (e.g. device locale).
    public let locale: Locale
    /// Whether partial results are desired.
    public let reportPartialResults: Bool

    public init(locale: Locale, reportPartialResults: Bool) {
        self.locale = locale
        self.reportPartialResults = reportPartialResults
    }
}

/// Abstraction over speech-to-text engines.
///
/// Implementations install their own audio tap on the provided engine's input
/// node, handle format conversion internally, and deliver recognized text
/// through an async stream. The host (TalkModeManager) owns the AVAudioEngine
/// and audio session — providers must not reconfigure either.
@MainActor
public protocol SpeechRecognitionProviding: AnyObject {
    /// Capabilities this provider supports.
    var capabilities: SpeechRecognitionCapabilities { get }

    /// Begin recognition.
    ///
    /// The provider installs a tap on `audioEngine.inputNode`, converts audio
    /// to its required format internally, and returns a stream of segments.
    /// The caller must call `stopRecognition()` to tear down the tap.
    func startRecognition(
        audioEngine: AVAudioEngine,
        options: SpeechRecognitionOptions
    ) async throws -> AsyncStream<SpeechRecognitionSegment>

    /// Stop recognition and remove the audio tap.
    func stopRecognition()

    /// Current microphone input level (0…1) for UI feedback.
    /// Updated during active recognition.
    var micLevel: Double { get }

    /// Date of last detected audio activity above the noise floor.
    /// Used by the host's silence monitor for providers that don't provide EOU.
    /// Providers that set `providesEndOfUtterance: true` may leave this as `.distantPast`.
    var lastAudioActivity: Date { get }
}
