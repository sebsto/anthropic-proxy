#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// MARK: - Request

struct BedrockInvokeRequest: Codable, Sendable {
    var anthropicVersion: String
    var maxTokens: Int
    var system: String?
    var messages: [AnthropicMessage]
    var temperature: Double?
    var topP: Double?
    var topK: Int?
    var stopSequences: [String]?
    var tools: [AnthropicTool]?
    var toolChoice: AnthropicToolChoice?

    enum CodingKeys: String, CodingKey {
        case messages, system, temperature, tools
        case anthropicVersion = "anthropic_version"
        case maxTokens = "max_tokens"
        case topP = "top_p"
        case topK = "top_k"
        case stopSequences = "stop_sequences"
        case toolChoice = "tool_choice"
    }
}

struct AnthropicMessage: Codable, Sendable {
    var role: String
    var content: AnthropicContent
}

enum AnthropicContent: Sendable, Equatable {
    case string(String)
    case blocks([AnthropicContentBlock])
}

extension AnthropicContent: Codable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let text = try? container.decode(String.self) {
            self = .string(text)
            return
        }

        if let blocks = try? container.decode([AnthropicContentBlock].self) {
            self = .blocks(blocks)
            return
        }

        throw DecodingError.typeMismatch(
            AnthropicContent.self,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected a string or an array of content blocks"
            )
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let text):
            try container.encode(text)
        case .blocks(let blocks):
            try container.encode(blocks)
        }
    }
}

// MARK: - Content Blocks

enum AnthropicContentBlock: Sendable, Equatable {
    case text(TextBlock)
    case toolUse(ToolUseBlock)
    case toolResult(ToolResultBlock)
}

extension AnthropicContentBlock: Codable {
    private enum TypeDiscriminator: String, Codable {
        case text
        case toolUse = "tool_use"
        case toolResult = "tool_result"
    }

    private enum CodingKeys: String, CodingKey {
        case type
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(TypeDiscriminator.self, forKey: .type)

        let singleContainer = try decoder.singleValueContainer()
        switch type {
        case .text:
            self = .text(try singleContainer.decode(TextBlock.self))
        case .toolUse:
            self = .toolUse(try singleContainer.decode(ToolUseBlock.self))
        case .toolResult:
            self = .toolResult(try singleContainer.decode(ToolResultBlock.self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .text(let block):
            try block.encode(to: encoder)
        case .toolUse(let block):
            try block.encode(to: encoder)
        case .toolResult(let block):
            try block.encode(to: encoder)
        }
    }
}

struct TextBlock: Codable, Sendable, Equatable {
    var type: String
    var text: String

    init(text: String) {
        self.type = "text"
        self.text = text
    }
}

struct ToolUseBlock: Codable, Sendable, Equatable {
    var type: String
    var id: String
    var name: String
    var input: JSONValue

    init(id: String, name: String, input: JSONValue) {
        self.type = "tool_use"
        self.id = id
        self.name = name
        self.input = input
    }
}

struct ToolResultBlock: Codable, Sendable, Equatable {
    var type: String
    var toolUseId: String
    var content: String?

    enum CodingKeys: String, CodingKey {
        case type, content
        case toolUseId = "tool_use_id"
    }

    init(toolUseId: String, content: String?) {
        self.type = "tool_result"
        self.toolUseId = toolUseId
        self.content = content
    }
}

// MARK: - Tools

struct AnthropicTool: Codable, Sendable {
    var name: String
    var description: String?
    var inputSchema: JSONValue?

    enum CodingKeys: String, CodingKey {
        case name, description
        case inputSchema = "input_schema"
    }
}

struct AnthropicToolChoice: Codable, Sendable {
    var type: String
    var name: String?
}

// MARK: - EventStream

struct EventStreamPayload: Codable, Sendable {
    var bytes: String
}
