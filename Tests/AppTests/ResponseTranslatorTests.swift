#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Testing
@testable import App

@Suite("ResponseTranslator Tests")
struct ResponseTranslatorTests {

    // MARK: - Basic Text Response

    @Test("Basic text response translated to OpenAI format")
    func testBasicTextResponse() throws {
        let bedrockResponse = BedrockInvokeResponse(
            id: "msg_123",
            type: "message",
            role: "assistant",
            content: [.text(TextBlock(text: "Hello, world!"))],
            model: "anthropic.claude-sonnet-4-5-20250514-v1:0",
            stopReason: "end_turn",
            usage: AnthropicUsage(inputTokens: 10, outputTokens: 20)
        )

        let result = ResponseTranslator().translate(bedrockResponse, originalModel: "claude-sonnet-4-5-20250514")

        #expect(result.object == "chat.completion")
        #expect(result.id == "chatcmpl-msg_123")
        #expect(result.choices.count == 1)
        #expect(result.choices[0].message?.content == .string("Hello, world!"))
        #expect(result.choices[0].message?.role == "assistant")
        #expect(result.choices[0].finishReason == "stop")
    }

    // MARK: - Original Model Echoed

    @Test("Original model name echoed in response, not Bedrock model")
    func testOriginalModelEchoed() throws {
        let bedrockResponse = BedrockInvokeResponse(
            id: "msg_456",
            type: "message",
            role: "assistant",
            content: [.text(TextBlock(text: "Hi"))],
            model: "anthropic.claude-sonnet-4-5-20250514-v1:0",
            stopReason: "end_turn"
        )

        let result = ResponseTranslator().translate(bedrockResponse, originalModel: "anthropic/claude-sonnet-4-5-20250514")

        #expect(result.model == "anthropic/claude-sonnet-4-5-20250514")
    }

    // MARK: - Finish Reason Mapping

    @Test("All finish reasons mapped correctly")
    func testFinishReasonMapping() throws {
        #expect(ResponseTranslator().mapFinishReason("end_turn") == "stop")
        #expect(ResponseTranslator().mapFinishReason("max_tokens") == "length")
        #expect(ResponseTranslator().mapFinishReason("tool_use") == "tool_calls")
        #expect(ResponseTranslator().mapFinishReason("stop_sequence") == "stop")
        #expect(ResponseTranslator().mapFinishReason(nil) == nil)
    }

    // MARK: - Tool Use Response

    @Test("Tool use content blocks translated to OpenAI tool_calls")
    func testToolUseResponse() throws {
        let toolInput: JSONValue = .object([
            "query": .string("weather in SF"),
        ])

        let bedrockResponse = BedrockInvokeResponse(
            id: "msg_789",
            type: "message",
            role: "assistant",
            content: [
                .toolUse(ToolUseBlock(
                    id: "toolu_01",
                    name: "get_weather",
                    input: toolInput
                )),
            ],
            model: "anthropic.claude-sonnet-4-5-20250514-v1:0",
            stopReason: "tool_use"
        )

        let result = ResponseTranslator().translate(bedrockResponse, originalModel: "claude-sonnet-4-5-20250514")

        let toolCalls = try #require(result.choices[0].message?.toolCalls)
        #expect(toolCalls.count == 1)
        #expect(toolCalls[0].id == "toolu_01")
        #expect(toolCalls[0].type == "function")
        #expect(toolCalls[0].function.name == "get_weather")

        // Verify arguments is a valid JSON string
        let argsData = try #require(toolCalls[0].function.arguments.data(using: .utf8))
        let parsed = try JSONDecoder().decode(JSONValue.self, from: argsData)
        #expect(parsed == toolInput)
    }

    // MARK: - Usage Translation

    @Test("Anthropic usage translated to OpenAI usage format")
    func testUsageTranslation() throws {
        let bedrockResponse = BedrockInvokeResponse(
            id: "msg_usage",
            type: "message",
            role: "assistant",
            content: [.text(TextBlock(text: "Hi"))],
            model: "anthropic.claude-sonnet-4-5-20250514-v1:0",
            stopReason: "end_turn",
            usage: AnthropicUsage(inputTokens: 42, outputTokens: 58)
        )

        let result = ResponseTranslator().translate(bedrockResponse, originalModel: "claude-sonnet-4-5-20250514")

        let usage = try #require(result.usage)
        #expect(usage.promptTokens == 42)
        #expect(usage.completionTokens == 58)
        #expect(usage.totalTokens == 100)
    }

    // MARK: - Mixed Content Blocks

    @Test("Mixed text and tool_use blocks: text in content, tools in tool_calls")
    func testMixedContentBlocks() throws {
        let toolInput: JSONValue = .object(["city": .string("London")])

        let bedrockResponse = BedrockInvokeResponse(
            id: "msg_mixed",
            type: "message",
            role: "assistant",
            content: [
                .text(TextBlock(text: "Let me check ")),
                .text(TextBlock(text: "the weather.")),
                .toolUse(ToolUseBlock(
                    id: "toolu_02",
                    name: "weather",
                    input: toolInput
                )),
            ],
            model: "anthropic.claude-sonnet-4-5-20250514-v1:0",
            stopReason: "tool_use"
        )

        let result = ResponseTranslator().translate(bedrockResponse, originalModel: "claude-sonnet-4-5-20250514")

        // Text blocks are concatenated
        #expect(result.choices[0].message?.content == .string("Let me check the weather."))

        // Tool calls are extracted separately
        let toolCalls = try #require(result.choices[0].message?.toolCalls)
        #expect(toolCalls.count == 1)
        #expect(toolCalls[0].function.name == "weather")
    }
}
