# Plan: Replace Strict Codable Types with `[String: JSONValue]` for Bedrock Responses

## Context

The proxy decodes Bedrock responses and streaming events using strict `Codable` structs. This is brittle: the `message_delta` streaming event has `usage: {"output_tokens": 12}` (no `input_tokens`), but `AnthropicUsage` requires both fields, causing a `keyNotFound` decoding error that breaks streaming.

The DESIGN.md (line 925) anticipated this: *"Using `Codable` with strict types risks dropping unknown fields when OpenAI or Anthropic adds new API parameters. Consider a JSON-preserving approach: decode as `[String: JSONValue]`, mutate only the fields we care about, re-encode."*

The fix: replace all Bedrock **response** types with `[String: JSONValue]` dictionary processing. Extract only the fields we need, tolerate missing/extra fields, and ignore unknown event types gracefully.

## What Changes

### Types to REMOVE from `BedrockTypes.swift` (lines 183-329)

These are all decoded from external Bedrock JSON and are fragile:

| Type | Replacement |
|---|---|
| `BedrockInvokeResponse` | `[String: JSONValue]` in `ResponseTranslator` |
| `AnthropicUsage` | Extract `input_tokens`/`output_tokens` as optional ints |
| `AnthropicStreamEvent` (enum + Codable) | `[String: JSONValue]` with string `type` dispatch |
| `MessageStartEvent` | Dictionary field access |
| `ContentBlockStartEvent` | Dictionary field access |
| `ContentBlockDeltaEvent` | Dictionary field access |
| `ContentBlockStopEvent` | Dictionary field access |
| `MessageDeltaEvent` | Dictionary field access |
| `MessageDeltaPayload` | Dictionary field access |
| `DeltaPayload` | Dictionary field access |

### Types to KEEP (we construct these or they have stable schemas)

- `BedrockInvokeRequest` and all sub-types (`AnthropicMessage`, `AnthropicContent`, `AnthropicContentBlock`, `TextBlock`, `ToolUseBlock`, `ToolResultBlock`, `AnthropicTool`, `AnthropicToolChoice`)
- `EventStreamPayload` (simple `{ "bytes": "<base64>" }` wrapper)
- All OpenAI types (`ChatCompletionRequest`, `ChatCompletionResponse`, `Choice`, `Usage`, `ChatMessage`, etc.)
- All Bedrock model discovery types (`ListFoundationModelsResponse`, `FoundationModelSummary`, etc.)

## Implementation Steps

### Step 1: Add convenience accessors to `JSONValue`

**File:** `Sources/App/Models/JSONValue.swift`

Add computed properties and subscript to `JSONValue` for ergonomic dictionary access:

```swift
extension JSONValue {
    var stringValue: String? { if case .string(let v) = self { return v }; return nil }
    var intValue: Int? { if case .number(let v) = self { return Int(v) }; return nil }
    var doubleValue: Double? { if case .number(let v) = self { return v }; return nil }
    var boolValue: Bool? { if case .bool(let v) = self { return v }; return nil }
    var arrayValue: [JSONValue]? { if case .array(let v) = self { return v }; return nil }
    var objectValue: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }

    subscript(_ key: String) -> JSONValue? { objectValue?[key] }
}
```

This enables chained access: `event["message"]?["usage"]?["input_tokens"]?.intValue`

### Step 2: Remove Bedrock response/streaming types from `BedrockTypes.swift`

**File:** `Sources/App/Models/BedrockTypes.swift`

Delete everything from line 183 (`// MARK: - Response`) through line 329 (`MessageDeltaPayload`), EXCEPT keep `EventStreamPayload` (lines 210-212). The file retains all request-side types.

### Step 3: Rewrite `OpenAISSEEncoder` to use `[String: JSONValue]`

**File:** `Sources/App/Streaming/OpenAISSEEncoder.swift`

Change signature: `encode(_ event: AnthropicStreamEvent, ...)` → `encode(_ event: [String: JSONValue], ...)`

Dispatch on `event["type"]?.stringValue` instead of enum cases:

```swift
func encode(_ event: [String: JSONValue], state: inout StreamState) -> [String] {
    guard let type = event["type"]?.stringValue else { return [] }
    switch type {
    case "message_start":     return encodeMessageStart(event, state: &state)
    case "content_block_start": return encodeContentBlockStart(event, state: &state)
    case "content_block_delta": return encodeContentBlockDelta(event, state: &state)
    case "content_block_stop":  return encodeContentBlockStop(state: &state)
    case "message_delta":     return encodeMessageDelta(event, state: &state)
    case "message_stop":      return encodeMessageStop(state: &state)
    default:                  return [] // Unknown events silently ignored
    }
}
```

Each handler extracts fields from the dictionary. Example for `encodeMessageStart`:
```swift
private func encodeMessageStart(_ event: [String: JSONValue], state: inout StreamState) -> [String] {
    let message = event["message"]?.objectValue ?? [:]
    state.id = "chatcmpl-\(message["id"]?.stringValue ?? UUID().uuidString)"
    state.model = originalModel
    state.created = Int(Date().timeIntervalSince1970)
    state.inputTokens = message["usage"]?["input_tokens"]?.intValue ?? 0
    // ... build Choice and return SSE line
}
```

**Key fix for the bug:** `encodeMessageDelta` extracts `output_tokens` as optional:
```swift
if let outputTokens = event["usage"]?["output_tokens"]?.intValue {
    state.outputTokens = outputTokens
}
// No crash if input_tokens is missing
```

### Step 4: Rewrite `ResponseTranslator` to use `[String: JSONValue]`

**File:** `Sources/App/Proxy/ResponseTranslator.swift`

Change signature: `translate(_ response: BedrockInvokeResponse, ...)` → `translate(_ response: [String: JSONValue], ...)`

Extract fields from dictionary:
```swift
let id = response["id"]?.stringValue.map { "chatcmpl-\($0)" } ?? "chatcmpl-\(UUID().uuidString)"
let contentBlocks = response["content"]?.arrayValue ?? []
let stopReason = response["stop_reason"]?.stringValue
let usage = response["usage"]?.objectValue
let inputTokens = usage?["input_tokens"]?.intValue ?? 0
let outputTokens = usage?["output_tokens"]?.intValue ?? 0
```

`extractTextContent` and `extractToolCalls` change from `[AnthropicContentBlock]` to `[JSONValue]`:
```swift
private func extractTextContent(from blocks: [JSONValue]) -> String? {
    let texts = blocks.compactMap { block -> String? in
        guard block["type"]?.stringValue == "text" else { return nil }
        return block["text"]?.stringValue
    }
    return texts.isEmpty ? nil : texts.joined()
}
```

### Step 5: Update decode calls in `ChatCompletionsHandler`

**File:** `Sources/App/Proxy/ChatCompletionsHandler.swift`

Two changes:

**Non-streaming (line ~199):**
```swift
// Before:
let bedrockResult = try JSONDecoder().decode(BedrockInvokeResponse.self, from: responseBody)
// After:
let bedrockResult = try JSONDecoder().decode([String: JSONValue].self, from: responseBody)
```

**Streaming (line ~320):**
```swift
// Before:
let event = try JSONDecoder().decode(AnthropicStreamEvent.self, from: jsonData)
// After:
let event = try JSONDecoder().decode([String: JSONValue].self, from: jsonData)
```

### Step 6: Update tests

**`Tests/AppTests/IntegrationTests.swift`** — Replace test helpers that construct `AnthropicStreamEvent` enum cases with helpers that construct `[String: JSONValue]` dictionaries:

```swift
private func makeMessageStartEvent(...) -> [String: JSONValue] {
    [
        "type": .string("message_start"),
        "message": .object([
            "id": .string(id),
            "usage": .object([
                "input_tokens": .number(Double(inputTokens)),
                "output_tokens": .number(Double(outputTokens)),
            ]),
        ]),
    ]
}
```

**`Tests/AppTests/ResponseTranslatorTests.swift`** — Replace `BedrockInvokeResponse(...)` with `[String: JSONValue]` dictionaries:

```swift
let bedrockResponse: [String: JSONValue] = [
    "id": .string("msg_test"),
    "content": .array([.object(["type": .string("text"), "text": .string("Hello")])]),
    "stop_reason": .string("end_turn"),
    "usage": .object(["input_tokens": .number(10), "output_tokens": .number(20)]),
]
```

**`Tests/AppTests/EventStreamParserTests.swift`** — Change `ContentBlockDeltaEvent` decodes to `[String: JSONValue]` decodes, then assert on dictionary values.

## Verification

1. `swift build` — compiles without errors
2. `swift test` — all 35 tests pass
3. Manual test with Xcode + Bedrock — streaming works without `keyNotFound` error on `message_delta` usage
4. Verify unknown event types are silently ignored (no crash)
