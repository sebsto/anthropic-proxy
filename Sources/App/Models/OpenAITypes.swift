#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// MARK: - Outbound Messages
// Encodable is used in production to serialize OpenAI-compatible JSON responses.
// Decodable exists only so tests can decode and verify the output shape.

struct ChatMessage: Sendable {
    var role: String
    var content: MessageContent?
    var toolCalls: [ToolCall]?
    var streamingToolCalls: [StreamingToolCall]?
    var toolCallId: String?
}

extension ChatMessage: Codable {
    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolCallId = "tool_call_id"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(String.self, forKey: .role)
        content = try container.decodeIfPresent(MessageContent.self, forKey: .content)
        toolCalls = try container.decodeIfPresent([ToolCall].self, forKey: .toolCalls)
        streamingToolCalls = nil
        toolCallId = try container.decodeIfPresent(String.self, forKey: .toolCallId)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encodeIfPresent(content, forKey: .content)
        if let streamingToolCalls {
            try container.encode(streamingToolCalls, forKey: .toolCalls)
        } else {
            try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
        }
        try container.encodeIfPresent(toolCallId, forKey: .toolCallId)
    }
}

enum MessageContent: Sendable, Equatable {
    case string(String)
    case parts([ContentPart])
}

extension MessageContent: Codable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
            return
        }

        if let parts = try? container.decode([ContentPart].self) {
            self = .parts(parts)
            return
        }

        throw DecodingError.typeMismatch(
            MessageContent.self,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected string or array of content parts"
            )
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .string(let value):
            try container.encode(value)
        case .parts(let value):
            try container.encode(value)
        }
    }
}

struct ContentPart: Codable, Sendable, Equatable {
    var type: String
    var text: String?
}

// MARK: - Tool Calls (outbound)

struct ToolCall: Codable, Sendable {
    var id: String
    var type: String
    var function: FunctionCall
}

struct FunctionCall: Codable, Sendable {
    var name: String
    var arguments: String
}

struct StreamingToolCall: Codable, Sendable {
    var index: Int
    var id: String?
    var type: String?
    var function: StreamingFunctionCall
}

struct StreamingFunctionCall: Codable, Sendable {
    var name: String?
    var arguments: String
}

// MARK: - Response

struct ChatCompletionResponse: Codable, Sendable {
    var id: String
    var object: String
    var created: Int
    var model: String
    var choices: [Choice]
    var usage: Usage?
}

struct Choice: Codable, Sendable {
    var index: Int
    var message: ChatMessage?
    var delta: ChatMessage?
    var finishReason: String?

    enum CodingKeys: String, CodingKey {
        case index, message, delta
        case finishReason = "finish_reason"
    }
}

struct Usage: Codable, Sendable {
    var promptTokens: Int
    var completionTokens: Int
    var totalTokens: Int

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }
}

// MARK: - Error

struct OpenAIErrorResponse: Codable, Sendable {
    var error: OpenAIError
}

struct OpenAIError: Codable, Sendable {
    var message: String
    var type: String
    var code: String?
}

// MARK: - Models

struct ModelList: Codable, Sendable {
    var object: String
    var data: [Model]
}

struct Model: Codable, Sendable {
    var id: String
    var object: String
    var created: Int
    var ownedBy: String

    enum CodingKeys: String, CodingKey {
        case id, object, created
        case ownedBy = "owned_by"
    }
}
