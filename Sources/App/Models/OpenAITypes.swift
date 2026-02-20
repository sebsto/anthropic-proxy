#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// MARK: - Request

struct ChatCompletionRequest: Codable, Sendable {
    var model: String
    var messages: [ChatMessage]
    var stream: Bool?
    var streamOptions: StreamOptions?
    var tools: [Tool]?
    var toolChoice: ToolChoice?
    var maxTokens: Int?
    var maxCompletionTokens: Int?
    var temperature: Double?
    var topP: Double?
    var stop: Stop?
    var n: Int?

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, tools, temperature, n, stop
        case streamOptions = "stream_options"
        case toolChoice = "tool_choice"
        case maxTokens = "max_tokens"
        case maxCompletionTokens = "max_completion_tokens"
        case topP = "top_p"
    }
}

struct StreamOptions: Codable, Sendable {
    var includeUsage: Bool?

    enum CodingKeys: String, CodingKey {
        case includeUsage = "include_usage"
    }
}

// MARK: - Messages

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

// MARK: - Tools

struct Tool: Codable, Sendable {
    var type: String
    var function: FunctionDefinition?
}

struct FunctionDefinition: Codable, Sendable {
    var name: String
    var description: String?
    var parameters: JSONValue?
}

enum ToolChoice: Sendable {
    case auto
    case none
    case required
    case function(name: String)
}

extension ToolChoice: Codable {
    private struct FunctionWrapper: Codable, Sendable {
        var type: String
        var function: FunctionName
    }

    private struct FunctionName: Codable, Sendable {
        var name: String
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let stringValue = try? container.decode(String.self) {
            switch stringValue {
            case "auto":
                self = .auto
            case "none":
                self = .none
            case "required":
                self = .required
            default:
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Unknown tool_choice string: \(stringValue)"
                    )
                )
            }
            return
        }

        if let wrapper = try? container.decode(FunctionWrapper.self) {
            self = .function(name: wrapper.function.name)
            return
        }

        throw DecodingError.typeMismatch(
            ToolChoice.self,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected string or object for tool_choice"
            )
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .auto:
            try container.encode("auto")
        case .none:
            try container.encode("none")
        case .required:
            try container.encode("required")
        case .function(let name):
            try container.encode(FunctionWrapper(type: "function", function: FunctionName(name: name)))
        }
    }
}

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

enum Stop: Sendable, Equatable {
    case string(String)
    case array([String])
}

extension Stop: Codable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
            return
        }

        if let arrayValue = try? container.decode([String].self) {
            self = .array(arrayValue)
            return
        }

        throw DecodingError.typeMismatch(
            Stop.self,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected string or array of strings for stop"
            )
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        }
    }
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

typealias ChatCompletionChunk = ChatCompletionResponse

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
