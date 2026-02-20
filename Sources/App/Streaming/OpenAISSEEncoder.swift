#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

struct StreamState: Sendable {
    var id: String = ""
    var model: String = ""
    var created: Int = 0
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var toolCallIndex: Int = 0
    var currentBlockIsToolUse: Bool = false
}

struct OpenAISSEEncoder: Sendable {
    let originalModel: String
    let includeUsage: Bool

    var doneSignal: String { "data: [DONE]\n\n" }

    func encode(_ event: [String: JSONValue], state: inout StreamState) -> [String] {
        switch event["type"]?.stringValue {
        case "message_start":
            return encodeMessageStart(event, state: &state)
        case "content_block_start":
            return encodeContentBlockStart(event, state: &state)
        case "content_block_delta":
            return encodeContentBlockDelta(event, state: &state)
        case "content_block_stop":
            return encodeContentBlockStop(state: &state)
        case "message_delta":
            return encodeMessageDelta(event, state: &state)
        case "message_stop":
            return encodeMessageStop(state: &state)
        default:
            return []
        }
    }

    // MARK: - Event Handlers

    private func encodeMessageStart(
        _ event: [String: JSONValue],
        state: inout StreamState
    ) -> [String] {
        let message = event["message"]

        state.id = "chatcmpl-\(message?["id"]?.stringValue ?? UUID().uuidString)"
        state.model = originalModel
        state.created = Int(Date().timeIntervalSince1970)
        state.inputTokens = message?["usage"]?["input_tokens"]?.intValue ?? 0

        let choice = Choice(
            index: 0,
            delta: ChatMessage(role: "assistant", content: .string("")),
            finishReason: nil
        )

        return [makeChunk(state: state, choices: [choice])]
    }

    private func encodeContentBlockStart(
        _ event: [String: JSONValue],
        state: inout StreamState
    ) -> [String] {
        let contentBlock = event["content_block"]
        let blockType = contentBlock?["type"]?.stringValue

        switch blockType {
        case "tool_use":
            state.currentBlockIsToolUse = true

            let id = contentBlock?["id"]?.stringValue ?? ""
            let name = contentBlock?["name"]?.stringValue ?? ""

            let streamingToolCall = StreamingToolCall(
                index: state.toolCallIndex,
                id: id,
                type: "function",
                function: StreamingFunctionCall(name: name, arguments: "")
            )

            let choice = Choice(
                index: 0,
                delta: ChatMessage(
                    role: "assistant",
                    streamingToolCalls: [streamingToolCall]
                ),
                finishReason: nil
            )

            return [makeChunk(state: state, choices: [choice])]

        default:
            state.currentBlockIsToolUse = false
            return []
        }
    }

    private func encodeContentBlockDelta(
        _ event: [String: JSONValue],
        state: inout StreamState
    ) -> [String] {
        let delta = event["delta"]
        let deltaType = delta?["type"]?.stringValue

        switch deltaType {
        case "text_delta":
            let text = delta?["text"]?.stringValue ?? ""
            let choice = Choice(
                index: 0,
                delta: ChatMessage(role: "assistant", content: .string(text)),
                finishReason: nil
            )
            return [makeChunk(state: state, choices: [choice])]

        case "input_json_delta":
            let json = delta?["partial_json"]?.stringValue ?? ""
            let streamingToolCall = StreamingToolCall(
                index: state.toolCallIndex,
                function: StreamingFunctionCall(arguments: json)
            )
            let choice = Choice(
                index: 0,
                delta: ChatMessage(
                    role: "assistant",
                    streamingToolCalls: [streamingToolCall]
                ),
                finishReason: nil
            )
            return [makeChunk(state: state, choices: [choice])]

        default:
            return []
        }
    }

    private func encodeContentBlockStop(state: inout StreamState) -> [String] {
        if state.currentBlockIsToolUse {
            state.toolCallIndex += 1
            state.currentBlockIsToolUse = false
        }
        return []
    }

    private func encodeMessageDelta(
        _ event: [String: JSONValue],
        state: inout StreamState
    ) -> [String] {
        let delta = event["delta"]
        let usage = event["usage"]

        if let outputTokens = usage?["output_tokens"]?.intValue {
            state.outputTokens = outputTokens
        }

        let finishReason = ResponseTranslator().mapFinishReason(delta?["stop_reason"]?.stringValue)

        let choice = Choice(
            index: 0,
            delta: ChatMessage(role: "assistant"),
            finishReason: finishReason
        )

        return [makeChunk(state: state, choices: [choice])]
    }

    private func encodeMessageStop(state: inout StreamState) -> [String] {
        var lines: [String] = []

        if includeUsage {
            let totalTokens = state.inputTokens + state.outputTokens
            let usage = Usage(
                promptTokens: state.inputTokens,
                completionTokens: state.outputTokens,
                totalTokens: totalTokens
            )
            lines.append(makeChunk(state: state, choices: [], usage: usage))
        }

        lines.append(doneSignal)
        return lines
    }

    // MARK: - Chunk Builder

    private func makeChunk(
        state: StreamState,
        choices: [Choice],
        usage: Usage? = nil
    ) -> String {
        let chunk = ChatCompletionResponse(
            id: state.id,
            object: "chat.completion.chunk",
            created: state.created,
            model: state.model,
            choices: choices,
            usage: usage
        )
        guard let data = try? JSONEncoder().encode(chunk),
              let json = String(data: data, encoding: .utf8) else {
            return ""
        }
        return "data: \(json)\n\n"
    }
}
