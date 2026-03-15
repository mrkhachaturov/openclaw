import Foundation

/// Streaming TTS client for the OpenAI audio/speech API.
public final class OpenAITTSClient: Sendable {
    public let apiKey: String
    public let baseUrl: String

    private static let defaultBaseUrl = "https://api.openai.com/v1"
    private static let defaultTimeoutSeconds: TimeInterval = 30

    public init(apiKey: String, baseUrl: String? = nil) {
        self.apiKey = apiKey
        self.baseUrl = (baseUrl ?? Self.defaultBaseUrl)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Build the JSON body for the TTS request.
    public static func buildRequestBody(
        model: String,
        voice: String,
        text: String,
        speed: Double?,
        instructions: String?,
        responseFormat: String
    ) -> Data {
        var dict: [String: Any] = [
            "model": model,
            "voice": voice,
            "input": text,
            "response_format": responseFormat,
        ]
        if let speed { dict["speed"] = speed }
        if let instructions, !instructions.isEmpty { dict["instructions"] = instructions }
        return try! JSONSerialization.data(withJSONObject: dict)
    }

    /// Build a URLRequest targeting the audio/speech endpoint.
    public static func buildURLRequest(
        baseUrl: String,
        apiKey: String,
        body: Data
    ) -> URLRequest {
        let trimmed = baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let url = URL(string: "\(trimmed)/audio/speech")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    /// Stream synthesized audio from the OpenAI TTS API.
    ///
    /// Returns an `AsyncThrowingStream<Data, Error>` of audio chunks (MP3 by default).
    /// The caller feeds these chunks to `StreamingAudioPlayer.play(stream:)`.
    public func streamSynthesize(
        model: String,
        voice: String,
        text: String,
        speed: Double? = nil,
        instructions: String? = nil,
        responseFormat: String = "mp3"
    ) -> AsyncThrowingStream<Data, Error> {
        let body = Self.buildRequestBody(
            model: model,
            voice: voice,
            text: text,
            speed: speed,
            instructions: instructions,
            responseFormat: responseFormat
        )
        let request = Self.buildURLRequest(
            baseUrl: self.baseUrl,
            apiKey: self.apiKey,
            body: body
        )

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let config = URLSessionConfiguration.default
                    config.timeoutIntervalForRequest = Self.defaultTimeoutSeconds
                    let session = URLSession(configuration: config)
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw NSError(
                            domain: "OpenAITTS",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "Non-HTTP response"])
                    }
                    guard (200..<300).contains(httpResponse.statusCode) else {
                        var errorBody = Data()
                        for try await byte in bytes { errorBody.append(byte) }
                        let message = String(data: errorBody, encoding: .utf8) ?? "Unknown error"
                        throw NSError(
                            domain: "OpenAITTS",
                            code: httpResponse.statusCode,
                            userInfo: [NSLocalizedDescriptionKey: "OpenAI TTS failed: \(httpResponse.statusCode) \(message)"])
                    }
                    let chunkSize = 8192
                    var buffer = Data()
                    buffer.reserveCapacity(chunkSize)
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        buffer.append(byte)
                        if buffer.count >= chunkSize {
                            continuation.yield(buffer)
                            buffer = Data()
                            buffer.reserveCapacity(chunkSize)
                        }
                    }
                    if !buffer.isEmpty {
                        continuation.yield(buffer)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
