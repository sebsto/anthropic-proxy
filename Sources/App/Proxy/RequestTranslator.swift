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
    case missingFunctionDefinition(toolIndex: Int)
}

// MARK: - Translator

struct RequestTranslator: Sendable {

    /// Translates a loose OpenAI-compatible chat completion request into a Bedrock invoke request.
    ///
    /// Extracts model, messages, tools, streaming options, and sampling parameters from the
    /// incoming dictionary and assembles an Anthropic-formatted ``BedrockInvokeRequest``.
    ///
    /// - Parameters:
    ///   - request: The inbound request decoded as a loose JSON dictionary.
    ///   - bedrockModelId: The resolved Bedrock model identifier to invoke.
    /// - Returns: A ``RequestTranslation`` containing the Bedrock path, body, and metadata.
    /// - Throws: ``TranslationError`` if required fields are missing or malformed.
    func translate(
        _ request: [String: JSONValue],
        bedrockModelId: String
    ) throws -> RequestTranslation {

        // 1. Model & messages (already validated by the handler)
        let originalModel = request["model"]?.stringValue ?? ""
        let messagesArray = request["messages"]?.arrayValue ?? []

        // 2. Streaming
        let isStreaming = request["stream"]?.boolValue ?? false

        // 3. stream_options → includeUsage
        let includeUsage = request["stream_options"]?["include_usage"]?.boolValue ?? false

        // 4. System messages
        let systemMessages = messagesArray.filter { $0["role"]?.stringValue == "system" }
        let systemText = systemMessages.compactMap { msg -> String? in
            extractTextFromContent(msg["content"])
        }.joined(separator: "\n")

        let nonSystemMessages = messagesArray.filter { $0["role"]?.stringValue != "system" }

        // 5. Translate messages (with adjacent tool-result merging)
        let anthropicMessages = translateMessages(nonSystemMessages)

        // 6. Tools
        let anthropicTools: [AnthropicTool]? = try request["tools"]?.arrayValue.flatMap { tools -> [AnthropicTool]? in
            guard !tools.isEmpty else { return nil }
            return try tools.enumerated().map { index, tool in
                guard let function = tool["function"] else {
                    throw TranslationError.missingFunctionDefinition(toolIndex: index)
                }
                return AnthropicTool(
                    name: function["name"]?.stringValue ?? "",
                    description: function["description"]?.stringValue,
                    inputSchema: function["parameters"]
                )
            }
        }

        // 7. tool_choice
        let anthropicToolChoice: AnthropicToolChoice? = request["tool_choice"].flatMap { choice in
            if let str = choice.stringValue {
                switch str {
                case "auto": return AnthropicToolChoice(type: "auto")
                case "none": return nil
                case "required": return AnthropicToolChoice(type: "any")
                default: return nil
                }
            }
            if let name = choice["function"]?["name"]?.stringValue {
                return AnthropicToolChoice(type: "tool", name: name)
            }
            return nil
        }

        // 8. max_tokens
        let maxTokens = request["max_tokens"]?.intValue
            ?? request["max_completion_tokens"]?.intValue
            ?? 8192

        // 9. Temperature / topP
        let temperature = request["temperature"]?.doubleValue
        let topP = request["top_p"]?.doubleValue

        // 10. stop → stop_sequences
        let stopSequences: [String]? = request["stop"].flatMap { stop in
            if let str = stop.stringValue {
                return [str]
            }
            if let arr = stop.arrayValue {
                return arr.compactMap(\.stringValue)
            }
            return nil
        }

        // Build the Bedrock URL path
        let action = isStreaming ? "invoke-with-response-stream" : "invoke"
        let bedrockPath = "/model/\(bedrockModelId)/\(action)"

        // 11. Assemble the Bedrock request body
        let bedrockBody = BedrockInvokeRequest(
            anthropicVersion: "bedrock-2023-05-31",
            maxTokens: maxTokens,
            system: systemText.isEmpty ? nil : systemText,
            messages: anthropicMessages,
            temperature: temperature,
            topP: topP,
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

    /// Converts non-system OpenAI messages into Anthropic messages.
    ///
    /// Handles user, assistant, and tool-result roles. Adjacent tool-result messages
    /// are merged into a single `user` message with multiple `tool_result` blocks,
    /// as required by the Anthropic API.
    private func translateMessages(_ messages: [JSONValue]) -> [AnthropicMessage] {
        var result: [AnthropicMessage] = []

        for message in messages {
            let role = message["role"]?.stringValue ?? "user"

            switch role {
            case "user":
                result.append(translateUserMessage(message))

            case "assistant":
                result.append(translateAssistantMessage(message))

            case "tool":
                let toolUseId = message["tool_call_id"]?.stringValue ?? ""
                let content = extractTextFromContent(message["content"])
                let toolResultBlock = AnthropicContentBlock.toolResult(
                    ToolResultBlock(toolUseId: toolUseId, content: content)
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
                let content = translateContent(message["content"])
                result.append(AnthropicMessage(role: role, content: content))
            }
        }

        return result
    }

    // MARK: - User Message

    /// Translates an OpenAI `user` message into an Anthropic message with text content blocks.
    private func translateUserMessage(_ message: JSONValue) -> AnthropicMessage {
        let content: AnthropicContent
        let rawContent = message["content"]

        if let text = rawContent?.stringValue {
            content = .blocks([.text(TextBlock(text: text))])
        } else if let parts = rawContent?.arrayValue {
            content = .blocks(parts.compactMap { part -> AnthropicContentBlock? in
                guard part["type"]?.stringValue == "text",
                      let text = part["text"]?.stringValue else { return nil }
                return .text(TextBlock(text: text))
            })
        } else {
            content = .blocks([])
        }
        return AnthropicMessage(role: "user", content: content)
    }

    // MARK: - Assistant Message

    /// Translates an OpenAI `assistant` message into an Anthropic message.
    ///
    /// Converts text content and `tool_calls` into Anthropic `text` and `tool_use` blocks.
    private func translateAssistantMessage(_ message: JSONValue) -> AnthropicMessage {
        var blocks: [AnthropicContentBlock] = []

        // Text content first
        let rawContent = message["content"]
        if let text = rawContent?.stringValue, !text.isEmpty {
            blocks.append(.text(TextBlock(text: text)))
        } else if let parts = rawContent?.arrayValue {
            for part in parts {
                if part["type"]?.stringValue == "text",
                   let text = part["text"]?.stringValue {
                    blocks.append(.text(TextBlock(text: text)))
                }
            }
        }

        // Tool calls
        if let toolCalls = message["tool_calls"]?.arrayValue {
            for tc in toolCalls {
                let id = tc["id"]?.stringValue ?? ""
                let name = tc["function"]?["name"]?.stringValue ?? ""
                let args = tc["function"]?["arguments"]?.stringValue ?? "{}"
                blocks.append(.toolUse(ToolUseBlock(
                    id: id,
                    name: name,
                    input: parseJSONArguments(args)
                )))
            }
        }

        if blocks.isEmpty {
            return AnthropicMessage(role: "assistant", content: .string(""))
        }
        return AnthropicMessage(role: "assistant", content: .blocks(blocks))
    }

    // MARK: - Helpers

    /// Converts a generic content value (string or array of parts) into ``AnthropicContent``.
    private func translateContent(_ content: JSONValue?) -> AnthropicContent {
        guard let content else { return .string("") }
        if let text = content.stringValue {
            return .string(text)
        }
        if let parts = content.arrayValue {
            return .blocks(parts.compactMap { part -> AnthropicContentBlock? in
                guard part["type"]?.stringValue == "text",
                      let text = part["text"]?.stringValue else { return nil }
                return .text(TextBlock(text: text))
            })
        }
        return .string("")
    }

    /// Extracts plain text from a content value that may be a string or an array of text parts.
    private func extractTextFromContent(_ content: JSONValue?) -> String? {
        guard let content else { return nil }
        if let text = content.stringValue {
            return text
        }
        if let parts = content.arrayValue {
            let texts = parts.compactMap { $0["text"]?.stringValue }
            return texts.isEmpty ? nil : texts.joined(separator: "\n")
        }
        return nil
    }

    /// Parses a JSON-encoded string into a ``JSONValue``, falling back to a plain string on failure.
    private func parseJSONArguments(_ jsonString: String) -> JSONValue {
        guard let data = jsonString.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .string(jsonString)
        }
        return value
    }
}
