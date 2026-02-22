#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Testing
@testable import App

/// Decode a JSON string into `[String: JSONValue]` for use as a request fixture.
private func json(_ string: String) throws -> [String: JSONValue] {
    try JSONDecoder().decode([String: JSONValue].self, from: Data(string.utf8))
}

private let defaultBedrockModelId = "anthropic.claude-sonnet-4-5-20250514-v1:0"

@Suite("RequestTranslator Tests")
struct RequestTranslatorTests {

    // MARK: - Basic Translation

    @Test("Basic translation: model, messages, stream flag")
    func testBasicTranslation() throws {
        let request = try json("""
        {
            "model": "claude-sonnet-4-5-20250514",
            "messages": [{"role": "user", "content": "Hello"}],
            "stream": true
        }
        """)

        let result = try RequestTranslator().translate(request, bedrockModelId: defaultBedrockModelId)

        #expect(result.bedrockBody.anthropicVersion == "bedrock-2023-05-31")
        #expect(result.bedrockPath.contains("anthropic.claude-sonnet-4-5-20250514-v1:0"))
        #expect(result.bedrockPath.hasSuffix("/invoke-with-response-stream"))
        #expect(result.isStreaming == true)
        #expect(result.originalModel == "claude-sonnet-4-5-20250514")
    }

    // MARK: - System Message Extraction

    @Test("System messages extracted to top-level system field")
    func testSystemMessageExtraction() throws {
        let request = try json("""
        {
            "model": "claude-sonnet-4-5-20250514",
            "messages": [
                {"role": "system", "content": "You are helpful."},
                {"role": "user", "content": "Hi"}
            ]
        }
        """)

        let result = try RequestTranslator().translate(request, bedrockModelId: defaultBedrockModelId)

        #expect(result.bedrockBody.system == "You are helpful.")
        #expect(result.bedrockBody.messages.count == 1)
        #expect(result.bedrockBody.messages[0].role == "user")
    }

    // MARK: - Multiple System Messages

    @Test("Multiple system messages concatenated with newline")
    func testMultipleSystemMessages() throws {
        let request = try json("""
        {
            "model": "claude-sonnet-4-5-20250514",
            "messages": [
                {"role": "system", "content": "First instruction."},
                {"role": "system", "content": "Second instruction."},
                {"role": "user", "content": "Hi"}
            ]
        }
        """)

        let result = try RequestTranslator().translate(request, bedrockModelId: defaultBedrockModelId)

        #expect(result.bedrockBody.system == "First instruction.\nSecond instruction.")
    }

    // MARK: - Content Normalization

    @Test("String content normalized to array of content blocks")
    func testContentNormalization() throws {
        let request = try json("""
        {
            "model": "claude-sonnet-4-5-20250514",
            "messages": [{"role": "user", "content": "Hello"}]
        }
        """)

        let result = try RequestTranslator().translate(request, bedrockModelId: defaultBedrockModelId)

        let userMessage = result.bedrockBody.messages[0]
        let expected = AnthropicContent.blocks([.text(TextBlock(text: "Hello"))])
        #expect(userMessage.content == expected)
    }

    // MARK: - Content Array Passthrough

    @Test("Array content passes through as content blocks")
    func testContentArrayPassthrough() throws {
        let request = try json("""
        {
            "model": "claude-sonnet-4-5-20250514",
            "messages": [
                {"role": "user", "content": [{"type": "text", "text": "Hello"}]}
            ]
        }
        """)

        let result = try RequestTranslator().translate(request, bedrockModelId: defaultBedrockModelId)

        let userMessage = result.bedrockBody.messages[0]
        let expected = AnthropicContent.blocks([.text(TextBlock(text: "Hello"))])
        #expect(userMessage.content == expected)
    }

    // MARK: - Anthropic Prefix Stripping

    @Test("anthropic/ prefix preserved in originalModel")
    func testAnthropicPrefixPreserved() throws {
        let request = try json("""
        {
            "model": "anthropic/claude-opus-4.6",
            "messages": [{"role": "user", "content": "Hello"}]
        }
        """)

        let result = try RequestTranslator().translate(request, bedrockModelId: "anthropic.claude-opus-4-6-v1:0")

        #expect(result.bedrockPath.contains("anthropic.claude-opus-4-6-v1:0"))
        #expect(result.originalModel == "anthropic/claude-opus-4.6")
    }

    // MARK: - Max Tokens

    @Test("Default max_tokens is 8192 when not specified")
    func testMaxTokensDefault() throws {
        let request = try json("""
        {
            "model": "claude-sonnet-4-5-20250514",
            "messages": [{"role": "user", "content": "Hello"}]
        }
        """)

        let result = try RequestTranslator().translate(request, bedrockModelId: defaultBedrockModelId)
        #expect(result.bedrockBody.maxTokens == 8192)
    }

    @Test("Explicit max_tokens is passed through")
    func testMaxTokensPassthrough() throws {
        let request = try json("""
        {
            "model": "claude-sonnet-4-5-20250514",
            "messages": [{"role": "user", "content": "Hello"}],
            "max_tokens": 1024
        }
        """)

        let result = try RequestTranslator().translate(request, bedrockModelId: defaultBedrockModelId)
        #expect(result.bedrockBody.maxTokens == 1024)
    }

    // MARK: - Stream Options

    @Test("stream_options.include_usage extracted to includeUsage")
    func testStreamOptionsExtracted() throws {
        let request = try json("""
        {
            "model": "claude-sonnet-4-5-20250514",
            "messages": [{"role": "user", "content": "Hello"}],
            "stream": true,
            "stream_options": {"include_usage": true}
        }
        """)

        let result = try RequestTranslator().translate(request, bedrockModelId: defaultBedrockModelId)
        #expect(result.includeUsage == true)
    }

    // MARK: - Tool Translation

    @Test("OpenAI tools translated to Anthropic format")
    func testToolTranslation() throws {
        let request = try json("""
        {
            "model": "claude-sonnet-4-5-20250514",
            "messages": [{"role": "user", "content": "Search for cats"}],
            "tools": [{
                "type": "function",
                "function": {
                    "name": "search",
                    "description": "Search the web",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "query": {"type": "string", "description": "The search query"}
                        }
                    }
                }
            }]
        }
        """)

        let result = try RequestTranslator().translate(request, bedrockModelId: defaultBedrockModelId)

        let tools = try #require(result.bedrockBody.tools)
        #expect(tools.count == 1)
        #expect(tools[0].name == "search")
        #expect(tools[0].description == "Search the web")
    }

    @Test("Empty tools array results in nil tools")
    func testEmptyToolsOmitted() throws {
        let request = try json("""
        {
            "model": "claude-sonnet-4-5-20250514",
            "messages": [{"role": "user", "content": "Hello"}],
            "tools": []
        }
        """)

        let result = try RequestTranslator().translate(request, bedrockModelId: defaultBedrockModelId)
        #expect(result.bedrockBody.tools == nil)
    }

    // MARK: - Tool Choice Translation

    @Test("All tool_choice variants translated correctly")
    func testToolChoiceTranslation() throws {
        let base = """
        {
            "model": "claude-sonnet-4-5-20250514",
            "messages": [{"role": "user", "content": "Hi"}],
            "tools": [{"type": "function", "function": {"name": "myTool", "description": "A tool", "parameters": {"type": "object"}}}],
        """

        // auto
        let autoResult = try RequestTranslator().translate(
            json(base + #""tool_choice": "auto"}"#), bedrockModelId: defaultBedrockModelId)
        #expect(autoResult.bedrockBody.toolChoice?.type == "auto")
        #expect(autoResult.bedrockBody.toolChoice?.name == nil)

        // none
        let noneResult = try RequestTranslator().translate(
            json(base + #""tool_choice": "none"}"#), bedrockModelId: defaultBedrockModelId)
        #expect(noneResult.bedrockBody.toolChoice == nil)

        // required → any
        let requiredResult = try RequestTranslator().translate(
            json(base + #""tool_choice": "required"}"#), bedrockModelId: defaultBedrockModelId)
        #expect(requiredResult.bedrockBody.toolChoice?.type == "any")

        // function → tool with name
        let fnResult = try RequestTranslator().translate(
            json(base + #""tool_choice": {"type": "function", "function": {"name": "myTool"}}}"#),
            bedrockModelId: defaultBedrockModelId)
        #expect(fnResult.bedrockBody.toolChoice?.type == "tool")
        #expect(fnResult.bedrockBody.toolChoice?.name == "myTool")
    }

    // MARK: - Stop Sequences

    @Test("stop values translated to stop_sequences")
    func testStopToStopSequences() throws {
        let stringResult = try RequestTranslator().translate(json("""
        {
            "model": "claude-sonnet-4-5-20250514",
            "messages": [{"role": "user", "content": "Hi"}],
            "stop": "END"
        }
        """), bedrockModelId: defaultBedrockModelId)
        #expect(stringResult.bedrockBody.stopSequences == ["END"])

        let arrayResult = try RequestTranslator().translate(json("""
        {
            "model": "claude-sonnet-4-5-20250514",
            "messages": [{"role": "user", "content": "Hi"}],
            "stop": ["END", "STOP"]
        }
        """), bedrockModelId: defaultBedrockModelId)
        #expect(arrayResult.bedrockBody.stopSequences == ["END", "STOP"])
    }

    // MARK: - Non-Streaming Path

    @Test("Non-streaming request uses /invoke path")
    func testNonStreamingPath() throws {
        let request = try json("""
        {
            "model": "claude-sonnet-4-5-20250514",
            "messages": [{"role": "user", "content": "Hello"}],
            "stream": false
        }
        """)

        let result = try RequestTranslator().translate(request, bedrockModelId: defaultBedrockModelId)

        #expect(result.bedrockPath.hasSuffix("/invoke"))
        #expect(!result.bedrockPath.contains("invoke-with-response-stream"))
        #expect(result.isStreaming == false)
    }

    // MARK: - Unknown Fields Ignored

    @Test("Unknown fields in request are silently ignored")
    func testUnknownFieldsIgnored() throws {
        let request = try json("""
        {
            "model": "claude-sonnet-4-5-20250514",
            "messages": [{"role": "user", "content": "Hello"}],
            "reasoning_effort": "high",
            "metadata": {"user_id": "abc123"},
            "some_future_field": 42
        }
        """)

        let result = try RequestTranslator().translate(request, bedrockModelId: defaultBedrockModelId)

        #expect(result.bedrockBody.messages.count == 1)
        #expect(result.originalModel == "claude-sonnet-4-5-20250514")
    }

    // MARK: - Tool Result Merging

    @Test("Adjacent tool results merged into single user message")
    func testAdjacentToolResultsMerged() throws {
        let request = try json("""
        {
            "model": "claude-sonnet-4-5-20250514",
            "messages": [
                {"role": "user", "content": "Call both tools"},
                {
                    "role": "assistant",
                    "content": "",
                    "tool_calls": [
                        {"id": "call_1", "type": "function", "function": {"name": "search", "arguments": "{\\"q\\":\\"cats\\"}"}},
                        {"id": "call_2", "type": "function", "function": {"name": "weather", "arguments": "{\\"city\\":\\"Paris\\"}"}}
                    ]
                },
                {"role": "tool", "tool_call_id": "call_1", "content": "Found cats"},
                {"role": "tool", "tool_call_id": "call_2", "content": "Sunny 25C"}
            ]
        }
        """)

        let result = try RequestTranslator().translate(request, bedrockModelId: defaultBedrockModelId)

        #expect(result.bedrockBody.messages.count == 3)
        let lastMessage = result.bedrockBody.messages[2]
        #expect(lastMessage.role == "user")

        guard case .blocks(let blocks) = lastMessage.content else {
            Issue.record("Expected .blocks content for merged tool results")
            return
        }
        #expect(blocks.count == 2)

        guard case .toolResult(let first) = blocks[0] else {
            Issue.record("Expected first block to be toolResult")
            return
        }
        #expect(first.toolUseId == "call_1")

        guard case .toolResult(let second) = blocks[1] else {
            Issue.record("Expected second block to be toolResult")
            return
        }
        #expect(second.toolUseId == "call_2")
    }

    // MARK: - Assistant Text + Tool Calls

    @Test("Assistant message with text and tool calls produces both block types")
    func testAssistantTextAndToolCalls() throws {
        let request = try json("""
        {
            "model": "claude-sonnet-4-5-20250514",
            "messages": [
                {"role": "user", "content": "Help me"},
                {
                    "role": "assistant",
                    "content": "Let me search for that",
                    "tool_calls": [
                        {"id": "call_1", "type": "function", "function": {"name": "search", "arguments": "{\\"q\\":\\"help\\"}"}}
                    ]
                },
                {"role": "tool", "tool_call_id": "call_1", "content": "Results here"},
                {"role": "user", "content": "Thanks"}
            ]
        }
        """)

        let result = try RequestTranslator().translate(request, bedrockModelId: defaultBedrockModelId)

        let assistantMessage = result.bedrockBody.messages[1]
        guard case .blocks(let blocks) = assistantMessage.content else {
            Issue.record("Expected .blocks content for assistant message")
            return
        }

        var hasText = false
        var hasToolUse = false
        for block in blocks {
            switch block {
            case .text(let tb):
                if tb.text == "Let me search for that" { hasText = true }
            case .toolUse(let tu):
                if tu.name == "search" { hasToolUse = true }
            default:
                break
            }
        }
        #expect(hasText, "Expected a text block with 'Let me search for that'")
        #expect(hasToolUse, "Expected a toolUse block with name 'search'")
    }

    // MARK: - max_completion_tokens Fallback

    @Test("max_completion_tokens used when max_tokens absent")
    func testMaxCompletionTokensFallback() throws {
        let request = try json("""
        {
            "model": "claude-sonnet-4-5-20250514",
            "messages": [{"role": "user", "content": "Hi"}],
            "max_completion_tokens": 2048
        }
        """)

        let result = try RequestTranslator().translate(request, bedrockModelId: defaultBedrockModelId)
        #expect(result.bedrockBody.maxTokens == 2048)
    }
}
