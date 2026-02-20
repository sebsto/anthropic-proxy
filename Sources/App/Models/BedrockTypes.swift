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

// MARK: - Response (non-streaming)

struct BedrockInvokeResponse: Codable, Sendable {
    var id: String?
    var type: String?
    var role: String?
    var content: [AnthropicContentBlock]?
    var model: String?
    var stopReason: String?
    var usage: AnthropicUsage?

    enum CodingKeys: String, CodingKey {
        case id, type, role, content, model, usage
        case stopReason = "stop_reason"
    }
}

struct AnthropicUsage: Codable, Sendable {
    var inputTokens: Int
    var outputTokens: Int

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}

// MARK: - EventStream

struct EventStreamPayload: Codable, Sendable {
    var bytes: String
}

// MARK: - Streaming Events

enum AnthropicStreamEvent: Sendable {
    case messageStart(MessageStartEvent)
    case contentBlockStart(ContentBlockStartEvent)
    case contentBlockDelta(ContentBlockDeltaEvent)
    case contentBlockStop(ContentBlockStopEvent)
    case messageDelta(MessageDeltaEvent)
    case messageStop
}

extension AnthropicStreamEvent: Codable {
    private enum EventType: String, Codable {
        case messageStart = "message_start"
        case contentBlockStart = "content_block_start"
        case contentBlockDelta = "content_block_delta"
        case contentBlockStop = "content_block_stop"
        case messageDelta = "message_delta"
        case messageStop = "message_stop"
    }

    private enum CodingKeys: String, CodingKey {
        case type
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let eventType = try container.decode(EventType.self, forKey: .type)

        let singleContainer = try decoder.singleValueContainer()
        switch eventType {
        case .messageStart:
            self = .messageStart(try singleContainer.decode(MessageStartEvent.self))
        case .contentBlockStart:
            self = .contentBlockStart(try singleContainer.decode(ContentBlockStartEvent.self))
        case .contentBlockDelta:
            self = .contentBlockDelta(try singleContainer.decode(ContentBlockDeltaEvent.self))
        case .contentBlockStop:
            self = .contentBlockStop(try singleContainer.decode(ContentBlockStopEvent.self))
        case .messageDelta:
            self = .messageDelta(try singleContainer.decode(MessageDeltaEvent.self))
        case .messageStop:
            self = .messageStop
        }
    }

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .messageStart(let event):
            try event.encode(to: encoder)
        case .contentBlockStart(let event):
            try event.encode(to: encoder)
        case .contentBlockDelta(let event):
            try event.encode(to: encoder)
        case .contentBlockStop(let event):
            try event.encode(to: encoder)
        case .messageDelta(let event):
            try event.encode(to: encoder)
        case .messageStop:
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(EventType.messageStop, forKey: .type)
        }
    }
}

struct MessageStartEvent: Codable, Sendable {
    var type: String
    var message: BedrockInvokeResponse
}

struct ContentBlockStartEvent: Codable, Sendable {
    var type: String
    var index: Int
    var contentBlock: AnthropicContentBlock

    enum CodingKeys: String, CodingKey {
        case type, index
        case contentBlock = "content_block"
    }
}

struct ContentBlockDeltaEvent: Codable, Sendable {
    var type: String
    var index: Int
    var delta: DeltaPayload
}

struct DeltaPayload: Codable, Sendable {
    var type: String
    var text: String?
    var partialJson: String?

    enum CodingKeys: String, CodingKey {
        case type, text
        case partialJson = "partial_json"
    }
}

struct ContentBlockStopEvent: Codable, Sendable {
    var type: String
    var index: Int
}

struct MessageDeltaEvent: Codable, Sendable {
    var type: String
    var delta: MessageDeltaPayload
    var usage: AnthropicUsage?
}

struct MessageDeltaPayload: Codable, Sendable {
    var stopReason: String?

    enum CodingKeys: String, CodingKey {
        case stopReason = "stop_reason"
    }
}
