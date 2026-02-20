#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Testing
@testable import App

@Suite("XcodeTraceValidation Tests")
struct XcodeTraceValidationTests {

    private func resolveModel(_ name: String) throws -> String {
        let mapping: [String: String] = [
            "claude-opus-4.6": "anthropic.claude-opus-4-6-v1:0",
        ]
        guard let resolved = mapping[name] else {
            throw TranslationError.emptyMessages
        }
        return resolved
    }

    @Test("Xcode trace request translated correctly end-to-end")
    func testXcodeRequestTranslation() throws {
        // Reproduce the exact Xcode request structure:
        // - system message + user message with content array
        // - model "anthropic/claude-opus-4.6"
        // - stream true
        // - stream_options.include_usage true
        // - empty tools array
        let request = ChatCompletionRequest(
            model: "anthropic/claude-opus-4.6",
            messages: [
                ChatMessage(
                    role: "system",
                    content: .string("You are a helpful coding assistant integrated into Xcode.")
                ),
                ChatMessage(
                    role: "user",
                    content: .parts([
                        ContentPart(type: "text", text: "Explain this code."),
                    ])
                ),
            ],
            stream: true,
            streamOptions: StreamOptions(includeUsage: true),
            tools: []
        )

        let result = try RequestTranslator().translate(request, resolveModel: resolveModel)

        // 1. System message extracted to top-level system field
        #expect(result.bedrockBody.system == "You are a helpful coding assistant integrated into Xcode.")

        // 2. User message content array passed through as blocks
        #expect(result.bedrockBody.messages.count == 1)
        let userMessage = result.bedrockBody.messages[0]
        #expect(userMessage.role == "user")
        let expectedContent = AnthropicContent.blocks([.text(TextBlock(text: "Explain this code."))])
        #expect(userMessage.content == expectedContent)

        // 3. anthropic_version injected
        #expect(result.bedrockBody.anthropicVersion == "bedrock-2023-05-31")

        // 4. max_tokens defaults to 8192
        #expect(result.bedrockBody.maxTokens == 8192)

        // 5. Empty tools omitted
        #expect(result.bedrockBody.tools == nil)

        // 6. anthropic/ prefix stripped (verified via successful model resolution to path)
        #expect(result.bedrockPath.contains("anthropic.claude-opus-4-6-v1:0"))

        // 7. isStreaming is true
        #expect(result.isStreaming == true)
        #expect(result.bedrockPath.hasSuffix("/invoke-with-response-stream"))

        // 8. includeUsage is true
        #expect(result.includeUsage == true)

        // 9. originalModel preserves the full original model string
        #expect(result.originalModel == "anthropic/claude-opus-4.6")
    }
}
