#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Testing
@testable import App

// MARK: - Helpers

/// Decode an SSE data line ("data: {...}\n\n") into a ChatCompletionResponse.
private func decodeSSELine(_ line: String) throws -> ChatCompletionResponse {
    let prefix = "data: "
    guard line.hasPrefix(prefix) else {
        throw TestHelperError(message: "Line does not start with 'data: ': \(line)")
    }
    let jsonString = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    let data = Data(jsonString.utf8)
    return try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
}

private struct TestHelperError: Error {
    let message: String
}

// MARK: - Tests

@Suite("OpenAISSEEncoder Tests")
struct OpenAISSEEncoderTests {

    private let testModel = "claude-sonnet-4-5-20250514"

    private func makeMessageStartEvent(
        id: String = "msg_123",
        inputTokens: Int = 100,
        outputTokens: Int = 1
    ) -> AnthropicStreamEvent {
        .messageStart(MessageStartEvent(
            type: "message_start",
            message: BedrockInvokeResponse(
                id: id,
                type: "message",
                role: "assistant",
                content: [],
                model: "claude-test",
                stopReason: nil,
                usage: AnthropicUsage(inputTokens: inputTokens, outputTokens: outputTokens)
            )
        ))
    }

    private func makeContentBlockDelta(text: String, index: Int = 0) -> AnthropicStreamEvent {
        .contentBlockDelta(ContentBlockDeltaEvent(
            type: "content_block_delta",
            index: index,
            delta: DeltaPayload(type: "text_delta", text: text)
        ))
    }

    private func makeMessageDelta(stopReason: String, outputTokens: Int = 10) -> AnthropicStreamEvent {
        .messageDelta(MessageDeltaEvent(
            type: "message_delta",
            delta: MessageDeltaPayload(stopReason: stopReason),
            usage: AnthropicUsage(inputTokens: 0, outputTokens: outputTokens)
        ))
    }

    // MARK: - testMessageStartChunk

    @Test("messageStart produces SSE chunk with role=assistant, empty content, chatcmpl- prefix")
    func testMessageStartChunk() throws {
        let encoder = OpenAISSEEncoder(originalModel: testModel, includeUsage: false)
        var state = StreamState()

        let lines = encoder.encode(makeMessageStartEvent(), state: &state)
        #expect(lines.count == 1)

        let response = try decodeSSELine(lines[0])
        #expect(response.object == "chat.completion.chunk")
        #expect(response.id.hasPrefix("chatcmpl-"))
        #expect(response.model == testModel)
        #expect(response.choices.count == 1)
        #expect(response.choices[0].delta?.role == "assistant")
        #expect(response.choices[0].delta?.content == .string(""))
        #expect(response.choices[0].finishReason == nil)
    }

    // MARK: - testTextDeltaChunk

    @Test("contentBlockDelta with text produces SSE chunk containing the text")
    func testTextDeltaChunk() throws {
        let encoder = OpenAISSEEncoder(originalModel: testModel, includeUsage: false)
        var state = StreamState()

        // Initialize state with messageStart first
        _ = encoder.encode(makeMessageStartEvent(), state: &state)

        let lines = encoder.encode(makeContentBlockDelta(text: "Hello world"), state: &state)
        #expect(lines.count == 1)

        let response = try decodeSSELine(lines[0])
        #expect(response.choices[0].delta?.role == "assistant")
        #expect(response.choices[0].delta?.content == .string("Hello world"))
    }

    // MARK: - testFinishReasonChunk

    @Test("messageDelta with end_turn produces SSE chunk with finish_reason=stop")
    func testFinishReasonChunk() throws {
        let encoder = OpenAISSEEncoder(originalModel: testModel, includeUsage: false)
        var state = StreamState()

        _ = encoder.encode(makeMessageStartEvent(), state: &state)

        let lines = encoder.encode(makeMessageDelta(stopReason: "end_turn"), state: &state)
        #expect(lines.count == 1)

        let response = try decodeSSELine(lines[0])
        #expect(response.choices[0].finishReason == "stop")
    }

    // MARK: - testUsageChunk

    @Test("messageStop with includeUsage emits usage chunk then data: [DONE]")
    func testUsageChunk() throws {
        let encoder = OpenAISSEEncoder(originalModel: testModel, includeUsage: true)
        var state = StreamState()

        // Set up state with known token counts
        _ = encoder.encode(makeMessageStartEvent(inputTokens: 50, outputTokens: 1), state: &state)
        _ = encoder.encode(makeMessageDelta(stopReason: "end_turn", outputTokens: 25), state: &state)

        let lines = encoder.encode(.messageStop, state: &state)
        #expect(lines.count == 2)

        // First line: usage chunk
        let usageResponse = try decodeSSELine(lines[0])
        let usage = try #require(usageResponse.usage)
        #expect(usage.promptTokens == 50)
        #expect(usage.completionTokens == 25)
        #expect(usage.totalTokens == 75)
        #expect(usageResponse.choices.isEmpty)

        // Second line: done signal
        #expect(lines[1] == "data: [DONE]\n\n")
    }

    // MARK: - testDoneSignalWithoutUsage

    @Test("messageStop with includeUsage=false emits only data: [DONE]")
    func testDoneSignalWithoutUsage() throws {
        let encoder = OpenAISSEEncoder(originalModel: testModel, includeUsage: false)
        var state = StreamState()

        _ = encoder.encode(makeMessageStartEvent(), state: &state)

        let lines = encoder.encode(.messageStop, state: &state)
        #expect(lines.count == 1)
        #expect(lines[0] == "data: [DONE]\n\n")
    }

    // MARK: - testFullStreamSequence

    @Test("Full stream sequence produces correct SSE output end-to-end")
    func testFullStreamSequence() throws {
        let encoder = OpenAISSEEncoder(originalModel: testModel, includeUsage: true)
        var state = StreamState()
        var allLines: [String] = []

        // 1. message_start
        allLines += encoder.encode(makeMessageStartEvent(inputTokens: 100, outputTokens: 1), state: &state)

        // 2. content_block_start (text)
        allLines += encoder.encode(
            .contentBlockStart(ContentBlockStartEvent(
                type: "content_block_start",
                index: 0,
                contentBlock: .text(TextBlock(text: ""))
            )),
            state: &state
        )

        // 3. content_block_delta: "Hey"
        allLines += encoder.encode(makeContentBlockDelta(text: "Hey"), state: &state)

        // 4. content_block_delta: "! I'm doing great"
        allLines += encoder.encode(makeContentBlockDelta(text: "! I'm doing great"), state: &state)

        // 5. content_block_delta: ", thanks for asking."
        allLines += encoder.encode(makeContentBlockDelta(text: ", thanks for asking."), state: &state)

        // 6. content_block_stop
        allLines += encoder.encode(
            .contentBlockStop(ContentBlockStopEvent(type: "content_block_stop", index: 0)),
            state: &state
        )

        // 7. message_delta
        allLines += encoder.encode(makeMessageDelta(stopReason: "end_turn", outputTokens: 15), state: &state)

        // 8. message_stop
        allLines += encoder.encode(.messageStop, state: &state)

        // Filter out empty entries (contentBlockStart for text returns [])
        let nonEmpty = allLines.filter { !$0.isEmpty }

        // Verify: first line has role + empty content
        let firstChunk = try decodeSSELine(nonEmpty[0])
        #expect(firstChunk.choices[0].delta?.role == "assistant")
        #expect(firstChunk.choices[0].delta?.content == .string(""))

        // Verify: text delta lines contain text content
        let deltaChunk1 = try decodeSSELine(nonEmpty[1])
        #expect(deltaChunk1.choices[0].delta?.content == .string("Hey"))

        let deltaChunk2 = try decodeSSELine(nonEmpty[2])
        #expect(deltaChunk2.choices[0].delta?.content == .string("! I'm doing great"))

        let deltaChunk3 = try decodeSSELine(nonEmpty[3])
        #expect(deltaChunk3.choices[0].delta?.content == .string(", thanks for asking."))

        // Verify: finish_reason is "stop"
        let finishChunk = try decodeSSELine(nonEmpty[4])
        #expect(finishChunk.choices[0].finishReason == "stop")

        // Verify: usage chunk present
        let usageChunk = try decodeSSELine(nonEmpty[5])
        let usage = try #require(usageChunk.usage)
        #expect(usage.promptTokens == 100)
        #expect(usage.completionTokens == 15)
        #expect(usage.totalTokens == 115)
        #expect(usageChunk.choices.isEmpty)

        // Verify: ends with data: [DONE]
        #expect(nonEmpty.last == "data: [DONE]\n\n")

        // Verify: all decoded chunks share the same id, model, and created
        let dataLines = nonEmpty.filter { $0 != "data: [DONE]\n\n" }
        let decoded = try dataLines.map { try decodeSSELine($0) }
        let ids = Set(decoded.map(\.id))
        let models = Set(decoded.map(\.model))
        let createdValues = Set(decoded.map(\.created))
        #expect(ids.count == 1)
        #expect(models.count == 1)
        #expect(createdValues.count == 1)
        #expect(models.first == testModel)
    }
}
