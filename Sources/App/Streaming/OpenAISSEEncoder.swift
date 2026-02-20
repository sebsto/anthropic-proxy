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

    func encode(_ event: AnthropicStreamEvent, state: inout StreamState) -> [String] {
        switch event {
        case .messageStart(let event):
            return encodeMessageStart(event, state: &state)
        case .contentBlockStart(let event):
            return encodeContentBlockStart(event, state: &state)
        case .contentBlockDelta(let event):
            return encodeContentBlockDelta(event, state: &state)
        case .contentBlockStop:
            return encodeContentBlockStop(state: &state)
        case .messageDelta(let event):
            return encodeMessageDelta(event, state: &state)
        case .messageStop:
            return encodeMessageStop(state: &state)
        }
    }

    // MARK: - Event Handlers

    private func encodeMessageStart(
        _ event: MessageStartEvent,
        state: inout StreamState
    ) -> [String] {
        let message = event.message

        state.id = "chatcmpl-\(message.id ?? UUID().uuidString)"
        state.model = originalModel
        state.created = Int(Date().timeIntervalSince1970)
        state.inputTokens = message.usage?.inputTokens ?? 0

        let choice = Choice(
            index: 0,
            delta: ChatMessage(role: "assistant", content: .string("")),
            finishReason: nil
        )

        return [makeChunk(state: state, choices: [choice])]
    }

    private func encodeContentBlockStart(
        _ event: ContentBlockStartEvent,
        state: inout StreamState
    ) -> [String] {
        switch event.contentBlock {
        case .text:
            state.currentBlockIsToolUse = false
            return []

        case .toolUse(let block):
            state.currentBlockIsToolUse = true

            let streamingToolCall = StreamingToolCall(
                index: state.toolCallIndex,
                id: block.id,
                type: "function",
                function: StreamingFunctionCall(name: block.name, arguments: "")
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

        case .toolResult:
            state.currentBlockIsToolUse = false
            return []
        }
    }

    private func encodeContentBlockDelta(
        _ event: ContentBlockDeltaEvent,
        state: inout StreamState
    ) -> [String] {
        switch event.delta.type {
        case "text_delta":
            let text = event.delta.text ?? ""
            let choice = Choice(
                index: 0,
                delta: ChatMessage(role: "assistant", content: .string(text)),
                finishReason: nil
            )
            return [makeChunk(state: state, choices: [choice])]

        case "input_json_delta":
            let json = event.delta.partialJson ?? ""
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
        _ event: MessageDeltaEvent,
        state: inout StreamState
    ) -> [String] {
        if let usage = event.usage {
            state.outputTokens = usage.outputTokens
        }

        let finishReason = ResponseTranslator().mapFinishReason(event.delta.stopReason)

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
