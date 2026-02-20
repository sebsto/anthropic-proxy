#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

struct ResponseTranslator: Sendable {

    func translate(
        _ response: BedrockInvokeResponse,
        originalModel: String
    ) -> ChatCompletionResponse {
        let id = response.id.map { "chatcmpl-\($0)" }
            ?? "chatcmpl-\(UUID().uuidString)"

        let textContent = extractTextContent(from: response.content)
        let toolCalls = extractToolCalls(from: response.content)

        let message = ChatMessage(
            role: "assistant",
            content: textContent.map { .string($0) },
            toolCalls: toolCalls
        )

        let choice = Choice(
            index: 0,
            message: message,
            delta: nil,
            finishReason: mapFinishReason(response.stopReason)
        )

        let usage = response.usage.map { anthropicUsage in
            Usage(
                promptTokens: anthropicUsage.inputTokens,
                completionTokens: anthropicUsage.outputTokens,
                totalTokens: anthropicUsage.inputTokens + anthropicUsage.outputTokens
            )
        }

        return ChatCompletionResponse(
            id: id,
            object: "chat.completion",
            created: Int(Date().timeIntervalSince1970),
            model: originalModel,
            choices: [choice],
            usage: usage
        )
    }

    func mapFinishReason(_ stopReason: String?) -> String? {
        guard let stopReason else { return nil }

        switch stopReason {
        case "end_turn":
            return "stop"
        case "max_tokens":
            return "length"
        case "tool_use":
            return "tool_calls"
        case "stop_sequence":
            return "stop"
        default:
            return stopReason
        }
    }

    // MARK: - Private

    private func extractTextContent(
        from blocks: [AnthropicContentBlock]?
    ) -> String? {
        guard let blocks else { return nil }

        let texts = blocks.compactMap { block -> String? in
            if case .text(let textBlock) = block {
                return textBlock.text
            }
            return nil
        }

        guard !texts.isEmpty else { return nil }
        return texts.joined()
    }

    private func extractToolCalls(
        from blocks: [AnthropicContentBlock]?
    ) -> [ToolCall]? {
        guard let blocks else { return nil }

        let calls = blocks.compactMap { block -> ToolCall? in
            if case .toolUse(let toolUseBlock) = block {
                return ToolCall(
                    id: toolUseBlock.id,
                    type: "function",
                    function: FunctionCall(
                        name: toolUseBlock.name,
                        arguments: serializeJSONValue(toolUseBlock.input)
                    )
                )
            }
            return nil
        }

        guard !calls.isEmpty else { return nil }
        return calls
    }

    private func serializeJSONValue(_ value: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}
