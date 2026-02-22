#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import AsyncHTTPClient
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import Testing

@testable import App

// MARK: - Mock Types

struct MockSigner: RequestSigning {
    let runtimeHost: String
    let controlPlaneHost: String

    init(region: String = "us-east-1") {
        self.runtimeHost = "bedrock-runtime.\(region).amazonaws.com"
        self.controlPlaneHost = "bedrock.\(region).amazonaws.com"
    }

    func signRequest(
        url: URL,
        method: HTTPMethod,
        headers: HTTPHeaders,
        body: ByteBuffer?
    ) async throws -> HTTPHeaders {
        headers
    }
}

final class MockHTTPClient: HTTPRequestSending, Sendable {
    private let _handler: NIOLockedValueBox<@Sendable (HTTPClientRequest) async throws -> HTTPClientResponse>

    init(handler: @escaping @Sendable (HTTPClientRequest) async throws -> HTTPClientResponse) {
        self._handler = NIOLockedValueBox(handler)
    }

    func setHandler(_ handler: @escaping @Sendable (HTTPClientRequest) async throws -> HTTPClientResponse) {
        _handler.withLockedValue { $0 = handler }
    }

    func execute(
        _ request: HTTPClientRequest,
        timeout: TimeAmount
    ) async throws -> HTTPClientResponse {
        let handler = _handler.withLockedValue { $0 }
        return try await handler(request)
    }
}

// MARK: - Helpers

private func makeBedrockResponseBody(
    id: String = "msg_test123",
    text: String = "Hello from Claude!",
    inputTokens: Int = 10,
    outputTokens: Int = 25
) -> Data {
    let json = """
    {
        "id": "\(id)",
        "type": "message",
        "role": "assistant",
        "content": [{"type": "text", "text": "\(text)"}],
        "model": "anthropic.claude-sonnet-4-5-20250514-v1:0",
        "stop_reason": "end_turn",
        "usage": {
            "input_tokens": \(inputTokens),
            "output_tokens": \(outputTokens)
        }
    }
    """
    return Data(json.utf8)
}

private func makeOpenAIRequestBody(
    model: String = "anthropic.claude-sonnet-4-5-20250514-v1:0",
    messagesJSON: String? = nil,
    stream: Bool = false
) throws -> ByteBuffer {
    let messages = messagesJSON ?? #"[{"role": "user", "content": "Say hello."}]"#
    let json = """
    {"model": "\(model)", "messages": \(messages), "stream": \(stream)}
    """
    return ByteBuffer(data: Data(json.utf8))
}

private let testAPIKey = "test-api-key"

private func buildTestApp(
    mockClient: MockHTTPClient
) -> some ApplicationProtocol {
    let config = Config(proxyAPIKey: testAPIKey)
    let signer = MockSigner()
    let logger = Logger(label: "test")
    return buildApplication(
        config: config,
        signingClient: signer,
        httpClient: mockClient,
        logger: logger
    )
}

// MARK: - Tests

@Suite("End-to-End Non-Streaming Tests")
struct EndToEndTests {

    @Test("Non-streaming chat completion returns correct OpenAI-format response")
    func testNonStreamingChatCompletion() async throws {
        let bedrockBody = makeBedrockResponseBody(
            id: "msg_abc123",
            text: "Hello! How can I help you?",
            inputTokens: 12,
            outputTokens: 18
        )
        let mockClient = MockHTTPClient { _ in
            HTTPClientResponse(
                status: .ok,
                headers: HTTPHeaders([("content-type", "application/json")]),
                body: .bytes(ByteBuffer(data: bedrockBody))
            )
        }

        let app = buildTestApp(mockClient: mockClient)

        try await app.test(.router) { client in
            let requestBody = try makeOpenAIRequestBody(
                model: "anthropic.claude-sonnet-4-5-20250514-v1:0"
            )

            let response = try await client.executeRequest(
                uri: "/v1/chat/completions",
                method: .post,
                headers: [.contentType: "application/json", HTTPField.Name("x-api-key")!: testAPIKey],
                body: requestBody
            )

            #expect(response.status == .ok)

            let responseData = Data(buffer: response.body)
            let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: responseData)

            #expect(decoded.id.hasPrefix("chatcmpl-"))
            #expect(decoded.object == "chat.completion")
            #expect(decoded.model == "anthropic.claude-sonnet-4-5-20250514-v1:0")
            #expect(decoded.choices.count == 1)
            #expect(decoded.choices[0].index == 0)
            #expect(decoded.choices[0].message?.role == "assistant")
            #expect(decoded.choices[0].message?.content == .string("Hello! How can I help you?"))
            #expect(decoded.choices[0].finishReason == "stop")

            let usage = try #require(decoded.usage)
            #expect(usage.promptTokens == 12)
            #expect(usage.completionTokens == 18)
            #expect(usage.totalTokens == 30)
        }
    }

    @Test("Empty messages array returns 400 error")
    func testEmptyMessagesReturns400() async throws {
        let mockClient = MockHTTPClient { _ in
            fatalError("Should not reach Bedrock for invalid request")
        }

        let app = buildTestApp(mockClient: mockClient)

        try await app.test(.router) { client in
            let requestBody = try makeOpenAIRequestBody(
                model: "anthropic.claude-sonnet-4-5-20250514-v1:0",
                messagesJSON: "[]"
            )

            let response = try await client.executeRequest(
                uri: "/v1/chat/completions",
                method: .post,
                headers: [.contentType: "application/json", HTTPField.Name("x-api-key")!: testAPIKey],
                body: requestBody
            )

            #expect(response.status == .badRequest)

            let responseData = Data(buffer: response.body)
            let decoded = try JSONDecoder().decode(OpenAIErrorResponse.self, from: responseData)
            #expect(decoded.error.type == "invalid_request_error")
            #expect(decoded.error.message.contains("messages"))
        }
    }

    @Test("Empty model string returns 400 error")
    func testEmptyModelReturns400() async throws {
        let mockClient = MockHTTPClient { _ in
            fatalError("Should not reach Bedrock for invalid request")
        }

        let app = buildTestApp(mockClient: mockClient)

        try await app.test(.router) { client in
            let requestBody = try makeOpenAIRequestBody(
                model: "",
                messagesJSON: #"[{"role": "user", "content": "Hello"}]"#
            )

            let response = try await client.executeRequest(
                uri: "/v1/chat/completions",
                method: .post,
                headers: [.contentType: "application/json", HTTPField.Name("x-api-key")!: testAPIKey],
                body: requestBody
            )

            #expect(response.status == .badRequest)

            let responseData = Data(buffer: response.body)
            let decoded = try JSONDecoder().decode(OpenAIErrorResponse.self, from: responseData)
            #expect(decoded.error.type == "invalid_request_error")
            #expect(decoded.error.message.contains("model"))
        }
    }

    @Test("Invalid JSON body returns 400 error")
    func testInvalidJSONBodyReturns400() async throws {
        let mockClient = MockHTTPClient { _ in
            fatalError("Should not reach Bedrock for invalid JSON body")
        }

        let app = buildTestApp(mockClient: mockClient)

        try await app.test(.router) { client in
            let requestBody = ByteBuffer(string: "this is not json")

            let response = try await client.executeRequest(
                uri: "/v1/chat/completions",
                method: .post,
                headers: [.contentType: "application/json", HTTPField.Name("x-api-key")!: testAPIKey],
                body: requestBody
            )

            #expect(response.status == .badRequest)

            let responseData = Data(buffer: response.body)
            let decoded = try JSONDecoder().decode(OpenAIErrorResponse.self, from: responseData)
            #expect(decoded.error.type == "invalid_request_error")
        }
    }

    @Test("Bedrock 429 mapped to rate limit error")
    func testBedrock429MappedToRateLimit() async throws {
        let mockClient = MockHTTPClient { _ in
            let errorBody = ByteBuffer(string: #"{"message": "Too many requests"}"#)
            return HTTPClientResponse(
                status: .tooManyRequests,
                headers: HTTPHeaders([("content-type", "application/json")]),
                body: .bytes(errorBody)
            )
        }

        let app = buildTestApp(mockClient: mockClient)

        try await app.test(.router) { client in
            let requestBody = try makeOpenAIRequestBody(
                model: "anthropic.claude-sonnet-4-5-20250514-v1:0"
            )

            let response = try await client.executeRequest(
                uri: "/v1/chat/completions",
                method: .post,
                headers: [.contentType: "application/json", HTTPField.Name("x-api-key")!: testAPIKey],
                body: requestBody
            )

            #expect(response.status == .tooManyRequests)

            let responseData = Data(buffer: response.body)
            let decoded = try JSONDecoder().decode(OpenAIErrorResponse.self, from: responseData)
            #expect(decoded.error.type == "rate_limit_error")
            #expect(decoded.error.code == "rate_limit_exceeded")
            #expect(decoded.error.message.contains("Too many requests"))
        }
    }

    @Test("Bedrock 400 mapped to invalid request error")
    func testBedrock400MappedToInvalidRequest() async throws {
        let mockClient = MockHTTPClient { _ in
            let errorBody = ByteBuffer(string: #"{"message": "Malformed input request"}"#)
            return HTTPClientResponse(
                status: .badRequest,
                headers: HTTPHeaders([("content-type", "application/json")]),
                body: .bytes(errorBody)
            )
        }

        let app = buildTestApp(mockClient: mockClient)

        try await app.test(.router) { client in
            let requestBody = try makeOpenAIRequestBody(
                model: "anthropic.claude-sonnet-4-5-20250514-v1:0"
            )

            let response = try await client.executeRequest(
                uri: "/v1/chat/completions",
                method: .post,
                headers: [.contentType: "application/json", HTTPField.Name("x-api-key")!: testAPIKey],
                body: requestBody
            )

            #expect(response.status == .badRequest)

            let responseData = Data(buffer: response.body)
            let decoded = try JSONDecoder().decode(OpenAIErrorResponse.self, from: responseData)
            #expect(decoded.error.type == "invalid_request_error")
            #expect(decoded.error.message.contains("Malformed input request"))
        }
    }

    @Test("Bedrock 403 mapped to server error (access denied)")
    func testBedrock403MappedToServerError() async throws {
        let mockClient = MockHTTPClient { _ in
            let errorBody = ByteBuffer(string: #"{"Message": "Access denied"}"#)
            return HTTPClientResponse(
                status: .forbidden,
                headers: HTTPHeaders([("content-type", "application/json")]),
                body: .bytes(errorBody)
            )
        }

        let app = buildTestApp(mockClient: mockClient)

        try await app.test(.router) { client in
            let requestBody = try makeOpenAIRequestBody(
                model: "anthropic.claude-sonnet-4-5-20250514-v1:0"
            )

            let response = try await client.executeRequest(
                uri: "/v1/chat/completions",
                method: .post,
                headers: [.contentType: "application/json", HTTPField.Name("x-api-key")!: testAPIKey],
                body: requestBody
            )

            #expect(response.status == .internalServerError)

            let responseData = Data(buffer: response.body)
            let decoded = try JSONDecoder().decode(OpenAIErrorResponse.self, from: responseData)
            #expect(decoded.error.type == "server_error")
            #expect(decoded.error.message.contains("Access denied"))
        }
    }

    @Test("Bedrock 404 mapped to model not found")
    func testBedrock404MappedToModelNotFound() async throws {
        let mockClient = MockHTTPClient { _ in
            let errorBody = ByteBuffer(string: #"{"message": "Could not resolve the foundation model"}"#)
            return HTTPClientResponse(
                status: .notFound,
                headers: HTTPHeaders([("content-type", "application/json")]),
                body: .bytes(errorBody)
            )
        }

        let app = buildTestApp(mockClient: mockClient)

        try await app.test(.router) { client in
            let requestBody = try makeOpenAIRequestBody(
                model: "anthropic.claude-sonnet-4-5-20250514-v1:0"
            )

            let response = try await client.executeRequest(
                uri: "/v1/chat/completions",
                method: .post,
                headers: [.contentType: "application/json", HTTPField.Name("x-api-key")!: testAPIKey],
                body: requestBody
            )

            #expect(response.status == .notFound)

            let responseData = Data(buffer: response.body)
            let decoded = try JSONDecoder().decode(OpenAIErrorResponse.self, from: responseData)
            #expect(decoded.error.type == "invalid_request_error")
            #expect(decoded.error.code == "model_not_found")
        }
    }

    @Test("Bedrock 408 mapped to timeout error")
    func testBedrock408MappedToTimeout() async throws {
        let mockClient = MockHTTPClient { _ in
            let errorBody = ByteBuffer(string: #"{"message": "Request timed out"}"#)
            return HTTPClientResponse(
                status: .requestTimeout,
                headers: HTTPHeaders([("content-type", "application/json")]),
                body: .bytes(errorBody)
            )
        }

        let app = buildTestApp(mockClient: mockClient)

        try await app.test(.router) { client in
            let requestBody = try makeOpenAIRequestBody(
                model: "anthropic.claude-sonnet-4-5-20250514-v1:0"
            )

            let response = try await client.executeRequest(
                uri: "/v1/chat/completions",
                method: .post,
                headers: [.contentType: "application/json", HTTPField.Name("x-api-key")!: testAPIKey],
                body: requestBody
            )

            #expect(response.status == .requestTimeout)

            let responseData = Data(buffer: response.body)
            let decoded = try JSONDecoder().decode(OpenAIErrorResponse.self, from: responseData)
            #expect(decoded.error.type == "server_error")
            #expect(decoded.error.code == "timeout")
        }
    }

    @Test("Bedrock 500 mapped to server error")
    func testBedrock500MappedToServerError() async throws {
        let mockClient = MockHTTPClient { _ in
            let errorBody = ByteBuffer(string: #"{"message": "Internal failure"}"#)
            return HTTPClientResponse(
                status: .internalServerError,
                headers: HTTPHeaders([("content-type", "application/json")]),
                body: .bytes(errorBody)
            )
        }

        let app = buildTestApp(mockClient: mockClient)

        try await app.test(.router) { client in
            let requestBody = try makeOpenAIRequestBody(
                model: "anthropic.claude-sonnet-4-5-20250514-v1:0"
            )

            let response = try await client.executeRequest(
                uri: "/v1/chat/completions",
                method: .post,
                headers: [.contentType: "application/json", HTTPField.Name("x-api-key")!: testAPIKey],
                body: requestBody
            )

            #expect(response.status == .internalServerError)

            let responseData = Data(buffer: response.body)
            let decoded = try JSONDecoder().decode(OpenAIErrorResponse.self, from: responseData)
            #expect(decoded.error.type == "server_error")
        }
    }
}
