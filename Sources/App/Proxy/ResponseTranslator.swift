#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

struct ResponseTranslator: Sendable {

    func translate(
        _ response: [String: JSONValue],
        originalModel: String
    ) -> ChatCompletionResponse {
        let id = response["id"]?.stringValue.map { "chatcmpl-\($0)" }
            ?? "chatcmpl-\(UUID().uuidString)"

        let contentBlocks = response["content"]?.arrayValue
        let textContent = extractTextContent(from: contentBlocks)
        let toolCalls = extractToolCalls(from: contentBlocks)

        let message = ChatMessage(
            role: "assistant",
            content: textContent.map { .string($0) },
            toolCalls: toolCalls
        )

        let choice = Choice(
            index: 0,
            message: message,
            delta: nil,
            finishReason: mapFinishReason(response["stop_reason"]?.stringValue)
        )

        let usage = response["usage"].flatMap { usageValue -> Usage? in
            guard let inputTokens = usageValue["input_tokens"]?.intValue,
                  let outputTokens = usageValue["output_tokens"]?.intValue else {
                return nil
            }
            return Usage(
                promptTokens: inputTokens,
                completionTokens: outputTokens,
                totalTokens: inputTokens + outputTokens
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

    private func extractTextContent(from blocks: [JSONValue]?) -> String? {
        guard let blocks else { return nil }

        let texts = blocks.compactMap { block -> String? in
            guard block["type"]?.stringValue == "text" else { return nil }
            return block["text"]?.stringValue
        }

        guard !texts.isEmpty else { return nil }
        return texts.joined()
    }

    private func extractToolCalls(from blocks: [JSONValue]?) -> [ToolCall]? {
        guard let blocks else { return nil }

        let calls = blocks.compactMap { block -> ToolCall? in
            guard block["type"]?.stringValue == "tool_use" else { return nil }
            let id = block["id"]?.stringValue ?? ""
            let name = block["name"]?.stringValue ?? ""
            let input = block["input"] ?? .object([:])
            return ToolCall(
                id: id,
                type: "function",
                function: FunctionCall(
                    name: name,
                    arguments: serializeJSONValue(input)
                )
            )
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
