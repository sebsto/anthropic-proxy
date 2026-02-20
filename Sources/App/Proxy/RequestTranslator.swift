#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// MARK: - Translation Output

struct RequestTranslation: Sendable {
    var bedrockPath: String
    var bedrockBody: BedrockInvokeRequest
    var isStreaming: Bool
    var includeUsage: Bool
    var originalModel: String
}

// MARK: - Errors

enum TranslationError: Error {
    case emptyMessages
    case missingFunctionDefinition(toolType: String)
}

// MARK: - Translator

struct RequestTranslator: Sendable {

    func translate(
        _ request: ChatCompletionRequest,
        resolveModel: (String) throws -> String
    ) throws -> RequestTranslation {

        // 1. Model resolution
        let originalModel = request.model
        let strippedModel = originalModel.hasPrefix("anthropic/")
            ? String(originalModel.dropFirst("anthropic/".count))
            : originalModel
        let bedrockModelId = try resolveModel(strippedModel)

        // 2. Streaming
        let isStreaming = request.stream ?? false

        // 3. stream_options → includeUsage
        let includeUsage = request.streamOptions?.includeUsage ?? false

        // 4. System messages
        let systemMessages = request.messages.filter { $0.role == "system" }
        let systemText = systemMessages.compactMap { msg -> String? in
            guard let content = msg.content else { return nil }
            switch content {
            case .string(let text):
                return text
            case .parts(let parts):
                return parts.compactMap(\.text).joined(separator: "\n")
            }
        }.joined(separator: "\n")

        let nonSystemMessages = request.messages.filter { $0.role != "system" }

        // 5-7. Translate messages (with adjacent tool-result merging)
        let anthropicMessages = translateMessages(nonSystemMessages)

        // 8. Tools
        let anthropicTools: [AnthropicTool]? = try request.tools.flatMap { tools -> [AnthropicTool]? in
            guard !tools.isEmpty else { return nil }
            return try tools.map { tool in
                guard let function = tool.function else {
                    throw TranslationError.missingFunctionDefinition(toolType: tool.type)
                }
                return AnthropicTool(
                    name: function.name,
                    description: function.description,
                    inputSchema: function.parameters
                )
            }
        }

        // 9. tool_choice
        let anthropicToolChoice: AnthropicToolChoice? = request.toolChoice.flatMap { choice in
            switch choice {
            case .auto:
                return AnthropicToolChoice(type: "auto")
            case .none:
                return nil
            case .required:
                return AnthropicToolChoice(type: "any")
            case .function(let name):
                return AnthropicToolChoice(type: "tool", name: name)
            }
        }

        // 10. max_tokens
        let maxTokens = request.maxTokens ?? request.maxCompletionTokens ?? 8192

        // 12. stop → stop_sequences
        let stopSequences: [String]? = request.stop.map { stop in
            switch stop {
            case .string(let value):
                return [value]
            case .array(let values):
                return values
            }
        }

        // Build the Bedrock URL path
        let action = isStreaming ? "invoke-with-response-stream" : "invoke"
        let bedrockPath = "/model/\(bedrockModelId)/\(action)"

        // 13. Assemble the Bedrock request body
        let bedrockBody = BedrockInvokeRequest(
            anthropicVersion: "bedrock-2023-05-31",
            maxTokens: maxTokens,
            system: systemText.isEmpty ? nil : systemText,
            messages: anthropicMessages,
            temperature: request.temperature,
            topP: request.topP,
            stopSequences: stopSequences,
            tools: anthropicTools,
            toolChoice: anthropicToolChoice
        )

        return RequestTranslation(
            bedrockPath: bedrockPath,
            bedrockBody: bedrockBody,
            isStreaming: isStreaming,
            includeUsage: includeUsage,
            originalModel: originalModel
        )
    }

    // MARK: - Message Translation

    private func translateMessages(_ messages: [ChatMessage]) -> [AnthropicMessage] {
        var result: [AnthropicMessage] = []

        for message in messages {
            switch message.role {
            case "user":
                result.append(translateUserMessage(message))

            case "assistant":
                result.append(translateAssistantMessage(message))

            case "tool":
                let toolResultBlock = AnthropicContentBlock.toolResult(
                    ToolResultBlock(
                        toolUseId: message.toolCallId ?? "",
                        content: extractTextContent(message.content)
                    )
                )
                // Merge adjacent tool results into a single user message
                if let last = result.last, last.role == "user", case .blocks(let existing) = last.content {
                    let allToolResults = existing.allSatisfy { block in
                        if case .toolResult = block { return true }
                        return false
                    }
                    if allToolResults {
                        result[result.count - 1] = AnthropicMessage(
                            role: "user",
                            content: .blocks(existing + [toolResultBlock])
                        )
                        continue
                    }
                }
                result.append(AnthropicMessage(
                    role: "user",
                    content: .blocks([toolResultBlock])
                ))

            default:
                result.append(AnthropicMessage(
                    role: message.role,
                    content: translateContent(message.content)
                ))
            }
        }

        return result
    }

    // MARK: - User Message

    private func translateUserMessage(_ message: ChatMessage) -> AnthropicMessage {
        let content: AnthropicContent
        switch message.content {
        case .string(let text):
            content = .blocks([.text(TextBlock(text: text))])
        case .parts(let parts):
            content = .blocks(parts.compactMap { part -> AnthropicContentBlock? in
                guard part.type == "text", let text = part.text else { return nil }
                return .text(TextBlock(text: text))
            })
        case .none:
            content = .blocks([])
        }
        return AnthropicMessage(role: "user", content: content)
    }

    // MARK: - Assistant Message

    private func translateAssistantMessage(_ message: ChatMessage) -> AnthropicMessage {
        var blocks: [AnthropicContentBlock] = []

        // Text content first
        if let msgContent = message.content {
            switch msgContent {
            case .string(let text) where !text.isEmpty:
                blocks.append(.text(TextBlock(text: text)))
            case .parts(let parts):
                for part in parts {
                    if part.type == "text", let text = part.text {
                        blocks.append(.text(TextBlock(text: text)))
                    }
                }
            default:
                break
            }
        }

        // Tool calls
        if let toolCalls = message.toolCalls {
            for tc in toolCalls {
                blocks.append(.toolUse(ToolUseBlock(
                    id: tc.id,
                    name: tc.function.name,
                    input: parseJSONArguments(tc.function.arguments)
                )))
            }
        }

        if blocks.isEmpty {
            return AnthropicMessage(role: "assistant", content: .string(""))
        }
        return AnthropicMessage(role: "assistant", content: .blocks(blocks))
    }

    // MARK: - Helpers

    private func translateContent(_ content: MessageContent?) -> AnthropicContent {
        guard let content else { return .string("") }
        switch content {
        case .string(let text):
            return .string(text)
        case .parts(let parts):
            return .blocks(parts.compactMap { part -> AnthropicContentBlock? in
                guard part.type == "text", let text = part.text else { return nil }
                return .text(TextBlock(text: text))
            })
        }
    }

    private func extractTextContent(_ content: MessageContent?) -> String? {
        guard let content else { return nil }
        switch content {
        case .string(let text):
            return text
        case .parts(let parts):
            let texts = parts.compactMap(\.text)
            return texts.isEmpty ? nil : texts.joined(separator: "\n")
        }
    }

    private func parseJSONArguments(_ jsonString: String) -> JSONValue {
        guard let data = jsonString.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .string(jsonString)
        }
        return value
    }
}
