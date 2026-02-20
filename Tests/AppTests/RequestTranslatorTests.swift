#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Testing
@testable import App

@Suite("RequestTranslator Tests")
struct RequestTranslatorTests {

    // Simple mock that maps known model names to Bedrock IDs.
    private func resolveModel(_ name: String) throws -> String {
        let mapping: [String: String] = [
            "claude-sonnet-4-5-20250514": "anthropic.claude-sonnet-4-5-20250514-v1:0",
            "claude-opus-4.6": "anthropic.claude-opus-4-6-v1:0",
        ]
        guard let resolved = mapping[name] else {
            throw TranslationError.emptyMessages
        }
        return resolved
    }

    // MARK: - Basic Translation

    @Test("Basic translation: model, messages, stream flag")
    func testBasicTranslation() throws {
        let request = ChatCompletionRequest(
            model: "claude-sonnet-4-5-20250514",
            messages: [
                ChatMessage(role: "user", content: .string("Hello"))
            ],
            stream: true
        )

        let result = try RequestTranslator().translate(request, resolveModel: resolveModel)

        #expect(result.bedrockBody.anthropicVersion == "bedrock-2023-05-31")
        #expect(result.bedrockPath.contains("anthropic.claude-sonnet-4-5-20250514-v1:0"))
        #expect(result.bedrockPath.hasSuffix("/invoke-with-response-stream"))
        #expect(result.isStreaming == true)
        #expect(result.originalModel == "claude-sonnet-4-5-20250514")
    }

    // MARK: - System Message Extraction

    @Test("System messages extracted to top-level system field")
    func testSystemMessageExtraction() throws {
        let request = ChatCompletionRequest(
            model: "claude-sonnet-4-5-20250514",
            messages: [
                ChatMessage(role: "system", content: .string("You are helpful.")),
                ChatMessage(role: "user", content: .string("Hi")),
            ]
        )

        let result = try RequestTranslator().translate(request, resolveModel: resolveModel)

        #expect(result.bedrockBody.system == "You are helpful.")
        #expect(result.bedrockBody.messages.count == 1)
        #expect(result.bedrockBody.messages[0].role == "user")
    }

    // MARK: - Multiple System Messages

    @Test("Multiple system messages concatenated with newline")
    func testMultipleSystemMessages() throws {
        let request = ChatCompletionRequest(
            model: "claude-sonnet-4-5-20250514",
            messages: [
                ChatMessage(role: "system", content: .string("First instruction.")),
                ChatMessage(role: "system", content: .string("Second instruction.")),
                ChatMessage(role: "user", content: .string("Hi")),
            ]
        )

        let result = try RequestTranslator().translate(request, resolveModel: resolveModel)

        #expect(result.bedrockBody.system == "First instruction.\nSecond instruction.")
    }

    // MARK: - Content Normalization

    @Test("String content normalized to array of content blocks")
    func testContentNormalization() throws {
        let request = ChatCompletionRequest(
            model: "claude-sonnet-4-5-20250514",
            messages: [
                ChatMessage(role: "user", content: .string("Hello")),
            ]
        )

        let result = try RequestTranslator().translate(request, resolveModel: resolveModel)

        let userMessage = result.bedrockBody.messages[0]
        let expected = AnthropicContent.blocks([.text(TextBlock(text: "Hello"))])
        #expect(userMessage.content == expected)
    }

    // MARK: - Content Array Passthrough

    @Test("Array content passes through as content blocks")
    func testContentArrayPassthrough() throws {
        let request = ChatCompletionRequest(
            model: "claude-sonnet-4-5-20250514",
            messages: [
                ChatMessage(
                    role: "user",
                    content: .parts([ContentPart(type: "text", text: "Hello")])
                ),
            ]
        )

        let result = try RequestTranslator().translate(request, resolveModel: resolveModel)

        let userMessage = result.bedrockBody.messages[0]
        let expected = AnthropicContent.blocks([.text(TextBlock(text: "Hello"))])
        #expect(userMessage.content == expected)
    }

    // MARK: - Anthropic Prefix Stripping

    @Test("anthropic/ prefix stripped before model resolution")
    func testAnthropicPrefixStripping() throws {
        let request = ChatCompletionRequest(
            model: "anthropic/claude-opus-4.6",
            messages: [
                ChatMessage(role: "user", content: .string("Hello")),
            ]
        )

        let result = try RequestTranslator().translate(request, resolveModel: resolveModel)

        #expect(result.bedrockPath.contains("anthropic.claude-opus-4-6-v1:0"))
        #expect(result.originalModel == "anthropic/claude-opus-4.6")
    }

    // MARK: - Max Tokens Default

    @Test("Default max_tokens is 8192 when not specified")
    func testMaxTokensDefault() throws {
        let request = ChatCompletionRequest(
            model: "claude-sonnet-4-5-20250514",
            messages: [
                ChatMessage(role: "user", content: .string("Hello")),
            ]
        )

        let result = try RequestTranslator().translate(request, resolveModel: resolveModel)

        #expect(result.bedrockBody.maxTokens == 8192)
    }

    // MARK: - Max Tokens Passthrough

    @Test("Explicit max_tokens is passed through")
    func testMaxTokensPassthrough() throws {
        let request = ChatCompletionRequest(
            model: "claude-sonnet-4-5-20250514",
            messages: [
                ChatMessage(role: "user", content: .string("Hello")),
            ],
            maxTokens: 1024
        )

        let result = try RequestTranslator().translate(request, resolveModel: resolveModel)

        #expect(result.bedrockBody.maxTokens == 1024)
    }

    // MARK: - Stream Options Extracted

    @Test("stream_options.include_usage extracted to includeUsage")
    func testStreamOptionsExtracted() throws {
        let request = ChatCompletionRequest(
            model: "claude-sonnet-4-5-20250514",
            messages: [
                ChatMessage(role: "user", content: .string("Hello")),
            ],
            stream: true,
            streamOptions: StreamOptions(includeUsage: true)
        )

        let result = try RequestTranslator().translate(request, resolveModel: resolveModel)

        #expect(result.includeUsage == true)
    }

    // MARK: - Tool Translation

    @Test("OpenAI tools translated to Anthropic format")
    func testToolTranslation() throws {
        let parameters: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object([
                    "type": .string("string"),
                    "description": .string("The search query"),
                ])
            ]),
        ])

        let request = ChatCompletionRequest(
            model: "claude-sonnet-4-5-20250514",
            messages: [
                ChatMessage(role: "user", content: .string("Search for cats")),
            ],
            tools: [
                Tool(
                    type: "function",
                    function: FunctionDefinition(
                        name: "search",
                        description: "Search the web",
                        parameters: parameters
                    )
                ),
            ]
        )

        let result = try RequestTranslator().translate(request, resolveModel: resolveModel)

        let tools = try #require(result.bedrockBody.tools)
        #expect(tools.count == 1)
        #expect(tools[0].name == "search")
        #expect(tools[0].description == "Search the web")
        #expect(tools[0].inputSchema == parameters)
    }

    // MARK: - Empty Tools Omitted

    @Test("Empty tools array results in nil tools")
    func testEmptyToolsOmitted() throws {
        let request = ChatCompletionRequest(
            model: "claude-sonnet-4-5-20250514",
            messages: [
                ChatMessage(role: "user", content: .string("Hello")),
            ],
            tools: []
        )

        let result = try RequestTranslator().translate(request, resolveModel: resolveModel)

        #expect(result.bedrockBody.tools == nil)
    }

    // MARK: - Tool Choice Translation

    @Test("All tool_choice variants translated correctly")
    func testToolChoiceTranslation() throws {
        let parameters: JSONValue = .object(["type": .string("object")])

        let tools = [
            Tool(
                type: "function",
                function: FunctionDefinition(
                    name: "myTool",
                    description: "A tool",
                    parameters: parameters
                )
            ),
        ]

        // auto
        let autoRequest = ChatCompletionRequest(
            model: "claude-sonnet-4-5-20250514",
            messages: [ChatMessage(role: "user", content: .string("Hi"))],
            tools: tools,
            toolChoice: .auto
        )
        let autoResult = try RequestTranslator().translate(autoRequest, resolveModel: resolveModel)
        #expect(autoResult.bedrockBody.toolChoice?.type == "auto")
        #expect(autoResult.bedrockBody.toolChoice?.name == nil)

        // none
        let noneRequest = ChatCompletionRequest(
            model: "claude-sonnet-4-5-20250514",
            messages: [ChatMessage(role: "user", content: .string("Hi"))],
            tools: tools,
            toolChoice: ToolChoice.none
        )
        let noneResult = try RequestTranslator().translate(noneRequest, resolveModel: resolveModel)
        #expect(noneResult.bedrockBody.toolChoice == nil)

        // required → any
        let requiredRequest = ChatCompletionRequest(
            model: "claude-sonnet-4-5-20250514",
            messages: [ChatMessage(role: "user", content: .string("Hi"))],
            tools: tools,
            toolChoice: .required
        )
        let requiredResult = try RequestTranslator().translate(requiredRequest, resolveModel: resolveModel)
        #expect(requiredResult.bedrockBody.toolChoice?.type == "any")

        // function → tool with name
        let fnRequest = ChatCompletionRequest(
            model: "claude-sonnet-4-5-20250514",
            messages: [ChatMessage(role: "user", content: .string("Hi"))],
            tools: tools,
            toolChoice: .function(name: "myTool")
        )
        let fnResult = try RequestTranslator().translate(fnRequest, resolveModel: resolveModel)
        #expect(fnResult.bedrockBody.toolChoice?.type == "tool")
        #expect(fnResult.bedrockBody.toolChoice?.name == "myTool")
    }

    // MARK: - Stop to Stop Sequences

    @Test("stop values translated to stop_sequences")
    func testStopToStopSequences() throws {
        // String stop
        let stringStopRequest = ChatCompletionRequest(
            model: "claude-sonnet-4-5-20250514",
            messages: [ChatMessage(role: "user", content: .string("Hi"))],
            stop: .string("END")
        )
        let stringResult = try RequestTranslator().translate(stringStopRequest, resolveModel: resolveModel)
        #expect(stringResult.bedrockBody.stopSequences == ["END"])

        // Array stop
        let arrayStopRequest = ChatCompletionRequest(
            model: "claude-sonnet-4-5-20250514",
            messages: [ChatMessage(role: "user", content: .string("Hi"))],
            stop: .array(["END", "STOP"])
        )
        let arrayResult = try RequestTranslator().translate(arrayStopRequest, resolveModel: resolveModel)
        #expect(arrayResult.bedrockBody.stopSequences == ["END", "STOP"])
    }

    // MARK: - Non-Streaming Path

    @Test("Non-streaming request uses /invoke path")
    func testNonStreamingPath() throws {
        let request = ChatCompletionRequest(
            model: "claude-sonnet-4-5-20250514",
            messages: [
                ChatMessage(role: "user", content: .string("Hello")),
            ],
            stream: false
        )

        let result = try RequestTranslator().translate(request, resolveModel: resolveModel)

        #expect(result.bedrockPath.hasSuffix("/invoke"))
        #expect(!result.bedrockPath.contains("invoke-with-response-stream"))
        #expect(result.isStreaming == false)
    }
}
