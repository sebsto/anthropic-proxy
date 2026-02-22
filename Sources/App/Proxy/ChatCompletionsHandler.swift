#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import AsyncHTTPClient
import Hummingbird
import Logging
import NIOCore
import NIOHTTP1

private let heartbeatInterval: Duration = .seconds(5)
private let heartbeatComment = ByteBuffer(string: ": processing\n\n")

struct ChatCompletionsHandler<Signer: RequestSigning, Client: HTTPRequestSending>: Sendable {
    let signingClient: Signer
    let httpClient: Client
    let modelsHandler: ModelsHandler<Signer, Client>
    let requestTimeout: TimeAmount
    let logger: Logger

    func handle(request: Request, context: some RequestContext) async throws -> Response {
        // 1. Decode request body as loose JSON
        let bodyBuffer = try await request.body.collect(upTo: 10 * 1024 * 1024) // 10 MB max
        let chatRequest: [String: JSONValue]
        do {
            chatRequest = try JSONDecoder().decode(
                [String: JSONValue].self,
                from: bodyBuffer
            )
        } catch {
            return makeOpenAIErrorResponse(
                status: .badRequest,
                message: "Invalid request body: \(error.localizedDescription)",
                type: "invalid_request_error",
                code: "invalid_request"
            )
        }

        // 2. Early validation
        let modelString = chatRequest["model"]?.stringValue ?? ""
        guard !modelString.isEmpty else {
            return makeOpenAIErrorResponse(
                status: .badRequest,
                message: "The 'model' field is required.",
                type: "invalid_request_error",
                code: "invalid_request"
            )
        }

        guard let messages = chatRequest["messages"]?.arrayValue, !messages.isEmpty else {
            return makeOpenAIErrorResponse(
                status: .badRequest,
                message: "The 'messages' field must be a non-empty array.",
                type: "invalid_request_error",
                code: "invalid_request"
            )
        }

        // 3. Resolve model
        let resolvedModelID: String
        do {
            resolvedModelID = try await modelsHandler.resolveModelID(modelString)
        } catch is ModelError {
            return makeOpenAIErrorResponse(
                status: .notFound,
                message: "The model '\(modelString)' does not exist or is not available.",
                type: "invalid_request_error",
                code: "model_not_found"
            )
        } catch {
            return makeOpenAIErrorResponse(
                status: .internalServerError,
                message: "Failed to resolve model: \(error.localizedDescription)",
                type: "server_error",
                code: "server_error"
            )
        }

        // 3. Translate request
        let translation: RequestTranslation
        do {
            translation = try RequestTranslator().translate(chatRequest, bedrockModelId: resolvedModelID)
        } catch let error as TranslationError {
            let message: String
            switch error {
            case .missingFunctionDefinition(let index):
                message = "Tool at index \(index) is missing a function definition."
            }
            return makeOpenAIErrorResponse(
                status: .badRequest,
                message: message,
                type: "invalid_request_error",
                code: "invalid_request"
            )
        } catch {
            return makeOpenAIErrorResponse(
                status: .badRequest,
                message: "Failed to translate request: \(error.localizedDescription)",
                type: "invalid_request_error",
                code: "invalid_request"
            )
        }

        // 4. Encode Bedrock request body
        let encoder = JSONEncoder()
        let bodyData: Data
        do {
            bodyData = try encoder.encode(translation.bedrockBody)
            if logger.logLevel <= .trace, let bodyStr = String(data: bodyData, encoding: .utf8) {
                logger.trace("Bedrock request body:\n\(bodyStr)")
            }
        } catch {
            return makeOpenAIErrorResponse(
                status: .internalServerError,
                message: "Failed to encode request for Bedrock.",
                type: "server_error",
                code: "server_error"
            )
        }

        // 5. Build the Bedrock URL
        let bedrockURLString = "https://\(signingClient.runtimeHost)\(translation.bedrockPath)"
        guard let bedrockURL = URL(string: bedrockURLString) else {
            return makeOpenAIErrorResponse(
                status: .internalServerError,
                message: "Failed to construct Bedrock URL.",
                type: "server_error",
                code: "server_error"
            )
        }

        // 6. Sign the request
        let bodyBuffer2 = ByteBuffer(data: bodyData)
        let acceptHeader = translation.isStreaming
            ? "application/vnd.amazon.eventstream"
            : "application/json"

        var outboundHeaders = HTTPHeaders()
        outboundHeaders.add(name: "Content-Type", value: "application/json")
        outboundHeaders.add(name: "Accept", value: acceptHeader)

        let signedHeaders: HTTPHeaders
        do {
            signedHeaders = try await signingClient.signRequest(
                url: bedrockURL,
                method: .POST,
                headers: outboundHeaders,
                body: bodyBuffer2
            )
        } catch {
            return makeOpenAIErrorResponse(
                status: .internalServerError,
                message: "Failed to sign request: \(error.localizedDescription)",
                type: "server_error",
                code: "server_error"
            )
        }

        // 7. Branch: streaming vs non-streaming
        logger.trace(
            "Request translated",
            metadata: [
                "bedrockPath": "\(translation.bedrockPath)",
                "isStreaming": "\(translation.isStreaming)",
                "originalModel": "\(translation.originalModel)",
            ]
        )

        if translation.isStreaming {
            return await handleStreaming(
                bedrockURLString: bedrockURLString,
                signedHeaders: signedHeaders,
                acceptHeader: acceptHeader,
                body: bodyBuffer2,
                translation: translation
            )
        }

        // 8. Send the request to Bedrock (non-streaming)
        var httpRequest = HTTPClientRequest(url: bedrockURLString)
        httpRequest.method = .POST
        httpRequest.headers = signedHeaders
        httpRequest.body = .bytes(bodyBuffer2)

        let bedrockResponse: HTTPClientResponse
        do {
            bedrockResponse = try await httpClient.execute(httpRequest, timeout: requestTimeout)
        } catch {
            return makeOpenAIErrorResponse(
                status: .internalServerError,
                message: "Failed to reach Bedrock: \(error.localizedDescription)",
                type: "server_error",
                code: "server_error"
            )
        }

        // 9. Check Bedrock response status
        let responseBody = try await bedrockResponse.body.collect(upTo: 10 * 1024 * 1024)
        guard (200..<300).contains(bedrockResponse.status.code) else {
            return mapBedrockError(
                status: bedrockResponse.status,
                body: responseBody
            )
        }

        // 10. Decode Bedrock response
        let bedrockResult: [String: JSONValue]
        do {
            bedrockResult = try JSONDecoder().decode(
                [String: JSONValue].self,
                from: responseBody
            )
        } catch {
            return makeOpenAIErrorResponse(
                status: .internalServerError,
                message: "Failed to decode Bedrock response: \(error.localizedDescription)",
                type: "server_error",
                code: "server_error"
            )
        }

        // 11. Translate response
        let openAIResponse = ResponseTranslator().translate(
            bedrockResult,
            originalModel: translation.originalModel
        )

        // 12. Encode and return
        let responseEncoder = JSONEncoder()
        responseEncoder.outputFormatting = .sortedKeys
        let responseData: Data
        do {
            responseData = try responseEncoder.encode(openAIResponse)
        } catch {
            return makeOpenAIErrorResponse(
                status: .internalServerError,
                message: "Failed to encode response.",
                type: "server_error",
                code: "server_error"
            )
        }

        return Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(data: responseData))
        )
    }

    // MARK: - Streaming

    private func handleStreaming(
        bedrockURLString: String,
        signedHeaders: HTTPHeaders,
        acceptHeader: String,
        body: ByteBuffer,
        translation: RequestTranslation
    ) async -> Response {
        // 1. Send the request to Bedrock
        var httpRequest = HTTPClientRequest(url: bedrockURLString)
        httpRequest.method = .POST
        httpRequest.headers = signedHeaders
        httpRequest.body = .bytes(body)

        let bedrockResponse: HTTPClientResponse
        do {
            logger.trace("Sending streaming request to Bedrock...")
            bedrockResponse = try await httpClient.execute(httpRequest, timeout: requestTimeout)
        } catch {
            logger.trace("Failed to reach Bedrock: \(error)")
            return makeOpenAIErrorResponse(
                status: .internalServerError,
                message: "Failed to reach Bedrock: \(error.localizedDescription)",
                type: "server_error",
                code: "server_error"
            )
        }

        logger.trace("Bedrock streaming response", metadata: ["status": "\(bedrockResponse.status.code)"])

        // 2. Check Bedrock response status; if not 2xx, collect body and return error
        guard (200..<300).contains(bedrockResponse.status.code) else {
            let errorBody = try? await bedrockResponse.body.collect(upTo: 10 * 1024 * 1024)
            if let errorBody, let bodyStr = errorBody.getString(at: errorBody.readerIndex, length: errorBody.readableBytes) {
                logger.trace("Bedrock error body: \(bodyStr)")
            }
            return mapBedrockError(
                status: bedrockResponse.status,
                body: errorBody
            )
        }

        logger.trace("Bedrock streaming response OK, starting SSE pipeline")

        // 3. Build the streaming response.
        let sseEncoder = OpenAISSEEncoder(
            originalModel: translation.originalModel,
            includeUsage: translation.includeUsage
        )
        let bedrockBody = bedrockResponse.body
        let logger = self.logger

        let (byteStream, continuation) = AsyncStream<ByteBuffer>.makeStream()

        let producerTask = Task {
            var state = StreamState()

            let heartbeatTask = Task {
                do {
                    while !Task.isCancelled {
                        try await Task.sleep(for: heartbeatInterval)
                        continuation.yield(heartbeatComment)
                    }
                } catch {
                    // CancellationError is expected
                }
            }

            do {
                let parser = EventStreamParser()
                let eventStream = parser.parse(bedrockBody)
                var receivedFirstChunk = false

                for try await jsonData in eventStream {
                    if !receivedFirstChunk {
                        heartbeatTask.cancel()
                        receivedFirstChunk = true
                    }

                    let event = try JSONDecoder().decode(
                        [String: JSONValue].self,
                        from: jsonData
                    )
                    let sseLines = sseEncoder.encode(event, state: &state)
                    for line in sseLines {
                        continuation.yield(ByteBuffer(string: line))
                    }
                }
            } catch {
                logger.error("Streaming error: \(error)")
            }

            heartbeatTask.cancel()
            continuation.finish()
        }

        let responseBody = ResponseBody { writer in
            for await buffer in byteStream {
                try await writer.write(buffer)
            }
            _ = producerTask
            try await writer.finish(nil)
        }

        return Response(
            status: .ok,
            headers: [
                .contentType: "text/event-stream",
                .cacheControl: "no-cache",
                .connection: "keep-alive",
            ],
            body: responseBody
        )
    }

    // MARK: - Bedrock Error Mapping

    func mapBedrockError(
        status: HTTPResponseStatus,
        body: ByteBuffer?
    ) -> Response {
        let message = extractBedrockErrorMessage(from: body)

        switch status.code {
        case 400:
            return makeOpenAIErrorResponse(
                status: .badRequest,
                message: message ?? "Bad request to Bedrock.",
                type: "invalid_request_error",
                code: "invalid_request"
            )
        case 403:
            return makeOpenAIErrorResponse(
                status: .internalServerError,
                message: message ?? "Access denied by Bedrock.",
                type: "server_error",
                code: "server_error"
            )
        case 404:
            return makeOpenAIErrorResponse(
                status: .notFound,
                message: message ?? "Model not found in Bedrock.",
                type: "invalid_request_error",
                code: "model_not_found"
            )
        case 408:
            return makeOpenAIErrorResponse(
                status: .requestTimeout,
                message: message ?? "Request to Bedrock timed out.",
                type: "server_error",
                code: "timeout"
            )
        case 429:
            return makeOpenAIErrorResponse(
                status: .tooManyRequests,
                message: message ?? "Rate limit exceeded on Bedrock.",
                type: "rate_limit_error",
                code: "rate_limit_exceeded"
            )
        default:
            if (500..<600).contains(status.code) {
                return makeOpenAIErrorResponse(
                    status: .internalServerError,
                    message: message ?? "Bedrock returned a server error (\(status.code)).",
                    type: "server_error",
                    code: "server_error"
                )
            }
            return makeOpenAIErrorResponse(
                status: .internalServerError,
                message: message ?? "Unexpected Bedrock error (\(status.code)).",
                type: "server_error",
                code: "server_error"
            )
        }
    }

    // MARK: - Helpers

    func makeOpenAIErrorResponse(
        status: HTTPResponse.Status,
        message: String,
        type: String,
        code: String
    ) -> Response {
        let error = OpenAIErrorResponse(
            error: OpenAIError(
                message: message,
                type: type,
                code: code
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(error) else {
            return Response(
                status: status,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(
                    string: #"{"error":{"message":"Internal error","type":"server_error","code":"server_error"}}"#
                ))
            )
        }
        return Response(
            status: status,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(data: data))
        )
    }

    private func extractBedrockErrorMessage(from body: ByteBuffer?) -> String? {
        guard let body, body.readableBytes > 0 else { return nil }

        guard let decoded = try? JSONDecoder().decode(BedrockErrorBody.self, from: body) else {
            return nil
        }
        return decoded.message
    }
}

private struct BedrockErrorBody: Decodable {
    var message: String?

    private enum CodingKeys: String, CodingKey {
        case message
        case uppercaseMessage = "Message"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = try container.decodeIfPresent(String.self, forKey: .message)
            ?? container.decodeIfPresent(String.self, forKey: .uppercaseMessage)
    }
}
