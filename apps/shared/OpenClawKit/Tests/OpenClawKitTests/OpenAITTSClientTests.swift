import Foundation
import Testing
@testable import OpenClawKit

@Suite struct OpenAITTSClientTests {
    @Test func buildRequestBodyContainsRequiredFields() throws {
        let body = OpenAITTSClient.buildRequestBody(
            model: "gpt-4o-mini-tts",
            voice: "ash",
            text: "Hello world",
            speed: nil,
            instructions: nil,
            responseFormat: "mp3"
        )
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        #expect(json["model"] as? String == "gpt-4o-mini-tts")
        #expect(json["voice"] as? String == "ash")
        #expect(json["input"] as? String == "Hello world")
        #expect(json["response_format"] as? String == "mp3")
        #expect(json["speed"] == nil)
        #expect(json["instructions"] == nil)
    }

    @Test func buildRequestBodyIncludesOptionalFields() throws {
        let body = OpenAITTSClient.buildRequestBody(
            model: "gpt-4o-mini-tts",
            voice: "alloy",
            text: "Test",
            speed: 1.5,
            instructions: "Speak calmly",
            responseFormat: "mp3"
        )
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        #expect(json["speed"] as? Double == 1.5)
        #expect(json["instructions"] as? String == "Speak calmly")
    }

    @Test func buildURLRequestSetsCorrectHeaders() {
        let request = OpenAITTSClient.buildURLRequest(
            baseUrl: "https://api.openai.com/v1",
            apiKey: "sk-test-key",
            body: Data()
        )
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/audio/speech")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-key")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test func buildURLRequestHandlesCustomBaseUrl() {
        let request = OpenAITTSClient.buildURLRequest(
            baseUrl: "https://my-proxy.example.com/v1",
            apiKey: "sk-test",
            body: Data()
        )
        #expect(request.url?.absoluteString == "https://my-proxy.example.com/v1/audio/speech")
    }

    @Test func buildURLRequestStripsTrailingSlash() {
        let request = OpenAITTSClient.buildURLRequest(
            baseUrl: "https://api.openai.com/v1/",
            apiKey: "sk-test",
            body: Data()
        )
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/audio/speech")
    }

    @Test func defaultBaseUrl() {
        let client = OpenAITTSClient(apiKey: "sk-test")
        #expect(client.baseUrl == "https://api.openai.com/v1")
    }

    @Test func customBaseUrl() {
        let client = OpenAITTSClient(apiKey: "sk-test", baseUrl: "https://proxy.local/v1")
        #expect(client.baseUrl == "https://proxy.local/v1")
    }
}
