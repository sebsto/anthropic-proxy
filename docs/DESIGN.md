# Design Doc: OpenAI-to-Bedrock Proxy ("anthopric-proxy")

## Context

Xcode 26 includes an AI coding assistant that can connect to any OpenAI-compatible API endpoint. Under the hood it speaks the **OpenAI Chat Completions API** — `POST /v1/chat/completions` for inference and `GET /v1/models` for model discovery (see Appendix for captured traffic).

Amazon Bedrock hosts Claude models inside your own AWS account, giving you data residency, existing billing, and IAM-based access control. However, Bedrock exposes its own REST API (SigV4-signed, with a binary EventStream protocol for streaming) that is incompatible with the OpenAI format Xcode expects.

This project bridges the gap: a lightweight, self-hosted Swift 6 proxy that sits between Xcode and Bedrock, translating between the two protocols in real time.

```
Xcode  ──OpenAI format──►  Proxy  ──Bedrock format (SigV4)──►  Amazon Bedrock (Claude)
```

The proxy handles:

- **Request translation** — OpenAI Chat Completions → Bedrock/Anthropic request body and URL
- **Response translation** — Bedrock/Anthropic JSON → OpenAI JSON (non-streaming), or Bedrock EventStream binary frames → OpenAI SSE text chunks (streaming)
- **Model discovery** — Bedrock `ListFoundationModels` → OpenAI models list, so Xcode's model picker works
- **AWS authentication** — SigV4 signing via the standard AWS credential chain (env vars, SSO, IAM roles)
- **Model name resolution** — mapping between OpenAI-style model IDs and Bedrock model IDs

---

## Architecture Overview

```
┌──────────┐  OpenAI Chat Completions  ┌───────────┐   Bedrock REST API (SigV4)   ┌─────────┐
│  Client  │  ───────────────────────► │   Proxy   │  ──────────────────────────► │ Bedrock │
│ (Xcode,  │   x-api-key: <key>        │Hummingbird│   Authorization: AWS4-HMAC   │ Runtime │
│  curl…)  │  ◄─────────────────────── │+ AsyncHTTP│  ◄────────────────────────── │         │
│          │   SSE stream / JSON       │ Client    │   EventStream / JSON         │         │
└──────────┘   (OpenAI format)         └───────────┘                              └─────────┘
```

### Components

| Component | Role |
|---|---|
| **Hummingbird Router** | Accepts `POST /v1/chat/completions`, `GET /v1/models`, `GET /v1/models/{model_id}` |
| **Auth Middleware** | Validates a static API key from clients (config-driven) |
| **Request Translator** | Converts OpenAI Chat Completions request → Bedrock request body + URL |
| **SigV4 Signer (soto-core)** | Signs outbound requests to Bedrock with AWS credentials |
| **AsyncHTTPClient** | Sends HTTPS requests to Bedrock (runtime + control plane) |
| **Response Translator** | Non-streaming: Bedrock/Anthropic JSON → OpenAI JSON. Streaming: parses AWS EventStream binary frames and emits OpenAI SSE chunks back to the client |

---

## API Translation

### Model Discovery (OpenAI Models API → Bedrock ListFoundationModels)

Xcode calls `GET /v1/models` to populate its model picker. The proxy fetches available models from Bedrock's `ListFoundationModels` API, filters to Anthropic models, and translates the response into OpenAI's format.

#### Inbound from client

**Endpoint:** `GET /v1/models`

Xcode sends this with an empty query string (`GET /v1/models?`). No pagination parameters are used — Xcode fetches the full list.

**Endpoint:** `GET /v1/models/{model_id}`

Returns a single model object, or 404 with OpenAI-style error JSON if the model is not found.

#### Outbound to Bedrock

**Bedrock endpoint:**
```
GET https://bedrock.{region}.amazonaws.com/foundation-models?byProvider=Anthropic
```

Note: this is the **control plane** host (`bedrock.{region}`) not the runtime host (`bedrock-runtime.{region}`). SigV4 service name is still `bedrock`.

**Bedrock response:**
```json
{
  "modelSummaries": [
    {
      "modelId": "anthropic.claude-sonnet-4-5-20250514-v1:0",
      "modelArn": "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-sonnet-4-5-20250514-v1:0",
      "modelName": "Claude Sonnet 4.5",
      "providerName": "Anthropic",
      "inputModalities": ["TEXT", "IMAGE"],
      "outputModalities": ["TEXT"],
      "responseStreamingSupported": true,
      "modelLifecycle": { "status": "ACTIVE" }
    }
  ]
}
```

#### Translation to OpenAI format

Each Bedrock `FoundationModelSummary` is translated to an OpenAI model object:

| Bedrock field | OpenAI field | Transformation |
|---|---|---|
| `modelId` | `id` | Reverse model mapping: strip `anthropic.` prefix and `-v1:0` suffix (e.g. `anthropic.claude-sonnet-4-5-20250514-v1:0` → `claude-sonnet-4-5-20250514`). If the ID doesn't match the expected pattern, use the raw `modelId`. |
| (derived) | `created` | Extract the date from the model ID if present (e.g. `20250514` → Unix timestamp for `2025-05-14T00:00:00Z`), otherwise use `0`. **Integer (Unix seconds)**, not an ISO string. |
| `providerName` | `owned_by` | Pass through directly (e.g. `"Anthropic"` → `"anthropic"`, lowercased). |
| — | `object` | Always `"model"` |

Only models with `modelLifecycle.status == "ACTIVE"` are included. The list is sorted newest first (by `created`).

**Response to client (`GET /v1/models`):**
```json
{
  "object": "list",
  "data": [
    {
      "id": "claude-sonnet-4-5-20250514",
      "object": "model",
      "created": 1747267200,
      "owned_by": "anthropic"
    },
    {
      "id": "claude-haiku-3-5-20241022",
      "object": "model",
      "created": 1729555200,
      "owned_by": "anthropic"
    }
  ]
}
```

**Response to client (`GET /v1/models/{model_id}`):**
```json
{
  "id": "claude-sonnet-4-5-20250514",
  "object": "model",
  "created": 1747267200,
  "owned_by": "anthropic"
}
```

#### Caching

The proxy caches the Bedrock `ListFoundationModels` response for a configurable TTL (default: 5 minutes, env var `MODEL_CACHE_TTL_SECONDS`). Model lists rarely change, and this avoids hitting the Bedrock control plane on every model list request. The cache is a simple actor holding the response and a timestamp.

---

### Inbound (OpenAI Chat Completions API)

**Endpoint:** `POST /v1/chat/completions`

**Headers from client (observed from Xcode trace):**
- `x-api-key: <proxy-api-key>` — client authenticates with this header
- `Content-Type: application/json`
- `Accept: application/json`
- `User-Agent: Xcode/24577 CFNetwork/3860.400.51 Darwin/25.3.0`
- `Accept-Encoding: gzip, deflate`
- `Connection: keep-alive`

Note: Xcode does **not** send `anthropic-version` or `x-api-key` headers. It speaks pure OpenAI protocol.

**Request body (OpenAI format, from Xcode trace):**
```json
{
  "messages": [
    {
      "content": "You are a coding assistant...",
      "role": "system"
    },
    {
      "content": [
        {
          "text": "The user is currently inside this file...",
          "type": "text"
        }
      ],
      "role": "user"
    }
  ],
  "model": "anthropic/claude-opus-4.6",
  "stream": true,
  "stream_options": {
    "include_usage": true
  },
  "tools": []
}
```

**Key observations from trace:**
- `model` uses OpenRouter convention: `"anthropic/claude-opus-4.6"` (provider prefix + display name, not a dated model ID).
- `messages` array includes system prompt as a message with `"role": "system"` (not a top-level `system` field).
- User message `content` can be a string or an array of content parts (`[{"type": "text", "text": "..."}]`).
- `stream_options.include_usage` requests a final usage chunk in the SSE stream.
- `tools` is an array (may be empty `[]`). When populated, uses OpenAI function-calling format.

### Outbound (Bedrock InvokeModel)

**Endpoint (non-streaming):**
```
POST https://bedrock-runtime.{region}.amazonaws.com/model/{bedrockModelId}/invoke
```

**Endpoint (streaming):**
```
POST https://bedrock-runtime.{region}.amazonaws.com/model/{bedrockModelId}/invoke-with-response-stream
```

**Required headers:**
- `Content-Type: application/json`
- `Accept: application/json`
- `Authorization: AWS4-HMAC-SHA256 Credential=...` (SigV4)
- `X-Amz-Date: <ISO8601>`
- `X-Amz-Security-Token: <token>` (if using temporary credentials)

**Request body (Bedrock/Anthropic format):**
```json
{
  "anthropic_version": "bedrock-2023-05-31",
  "max_tokens": 8192,
  "system": "You are a coding assistant...",
  "messages": [
    {
      "role": "user",
      "content": [
        {
          "type": "text",
          "text": "The user is currently inside this file..."
        }
      ]
    }
  ]
}
```

### Translation Rules (OpenAI → Bedrock)

| OpenAI field | Bedrock handling |
|---|---|
| `model` | **Removed from body.** Resolved to a Bedrock model ID and placed in URL path (see model resolution below). |
| `stream` | **Removed from body.** Determines whether proxy calls `/invoke` or `/invoke-with-response-stream`. |
| `stream_options` | **Removed from body.** `include_usage` flag is stored and used when generating the OpenAI SSE response. |
| `messages` (system) | **Extracted.** Messages with `"role": "system"` are removed from the array and concatenated into the top-level `"system"` field (Bedrock/Anthropic uses a separate `system` field, not a system message). |
| `messages` (user/assistant) | **Passed through** with minor content format normalization (see below). |
| `messages` (tool results) | **Translated.** OpenAI `{"role": "tool", "tool_call_id": "...", "content": "..."}` → Anthropic `{"role": "user", "content": [{"type": "tool_result", "tool_use_id": "...", "content": "..."}]}`. Adjacent tool results are merged into a single `user` message. |
| `tools` | **Translated.** OpenAI `{"type": "function", "function": {"name": "...", "description": "...", "parameters": {...}}}` → Anthropic `{"name": "...", "description": "...", "input_schema": {...}}`. Empty arrays are omitted. |
| `tool_choice` | **Translated.** OpenAI `"auto"` → Anthropic `{"type": "auto"}`, `"none"` → omit, `"required"` → `{"type": "any"}`, `{"type": "function", "function": {"name": "X"}}` → `{"type": "tool", "name": "X"}`. |
| `max_tokens` | **Passed through** (or default to `8192` if absent — Bedrock requires this field). |
| `max_completion_tokens` | **Mapped** to `max_tokens` (OpenAI alias). |
| `temperature` | **Passed through.** |
| `top_p` | **Passed through.** |
| `stop` | **Mapped** to `stop_sequences` (OpenAI uses `stop`, Anthropic uses `stop_sequences`). |
| `n` | **Ignored** (only `n=1` is meaningful; Bedrock doesn't support multiple completions). |
| — | `anthropic_version` **injected** as `"bedrock-2023-05-31"`. |

#### Message content normalization

OpenAI allows `content` to be either a plain string or an array of content parts. Bedrock/Anthropic always expects an array for user messages:

- String `"Hello"` → `[{"type": "text", "text": "Hello"}]`
- Array `[{"type": "text", "text": "Hello"}]` → passed through as-is
- Array with `image_url` parts → translated to Anthropic `{"type": "image", "source": {"type": "base64", ...}}` (future work — data URLs only initially)

#### Assistant message tool_calls translation

OpenAI assistant messages with `tool_calls` are translated to Anthropic content blocks:

```json
// OpenAI
{"role": "assistant", "tool_calls": [{"id": "call_1", "type": "function", "function": {"name": "get_weather", "arguments": "{\"city\":\"SF\"}"}}]}

// → Anthropic/Bedrock
{"role": "assistant", "content": [{"type": "tool_use", "id": "call_1", "name": "get_weather", "input": {"city": "SF"}}]}
```

Note: OpenAI `arguments` is a JSON **string**; Anthropic `input` is a JSON **object**. The proxy parses the string.

### Translation Rules (Bedrock → OpenAI)

#### Non-streaming response

Bedrock returns Anthropic-format JSON. The proxy translates to OpenAI Chat Completion format:

```json
// Bedrock/Anthropic response
{
  "id": "msg_abc123",
  "type": "message",
  "role": "assistant",
  "content": [{"type": "text", "text": "Hello!"}],
  "model": "claude-sonnet-4-5-20250514",
  "stop_reason": "end_turn",
  "usage": {"input_tokens": 25, "output_tokens": 10}
}

// → OpenAI response
{
  "id": "chatcmpl-msg_abc123",
  "object": "chat.completion",
  "created": 1740063600,
  "model": "claude-sonnet-4-5-20250514",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "Hello!"
      },
      "finish_reason": "stop"
    }
  ],
  "usage": {
    "prompt_tokens": 25,
    "completion_tokens": 10,
    "total_tokens": 35
  }
}
```

**Field mapping:**

| Bedrock/Anthropic | OpenAI | Notes |
|---|---|---|
| `id` | `id` | Prefix with `chatcmpl-` |
| — | `object` | Always `"chat.completion"` |
| — | `created` | Current Unix timestamp |
| `model` | `model` | Echo the **client's original model name** (e.g. `"anthropic/claude-opus-4.6"`), not the resolved Bedrock ID. Observed in OpenRouter trace. |
| `content` (text blocks) | `choices[0].message.content` | Concatenate all text blocks into a single string |
| `content` (tool_use blocks) | `choices[0].message.tool_calls` | Translate: `{"type": "tool_use", "id": "X", "name": "Y", "input": {...}}` → `{"id": "X", "type": "function", "function": {"name": "Y", "arguments": "{...}"}}`. Note: `arguments` must be a JSON string. |
| `stop_reason` | `choices[0].finish_reason` | Map: `"end_turn"` → `"stop"`, `"max_tokens"` → `"length"`, `"tool_use"` → `"tool_calls"`, `"stop_sequence"` → `"stop"` |
| `usage.input_tokens` | `usage.prompt_tokens` | Rename |
| `usage.output_tokens` | `usage.completion_tokens` | Rename |
| — | `usage.total_tokens` | Sum of prompt + completion |

### Model Name Resolution

The `model` field from the client is resolved to a Bedrock model ID using the cached `ListFoundationModels` data (see Model Discovery above). Resolution steps:

1. **Strip `anthropic/` prefix** — If the model name starts with `anthropic/` (OpenRouter/Xcode convention, as seen in trace), strip the prefix before lookup.
2. **Pass-through Bedrock IDs** — If the name already contains `anthropic.` (i.e. looks like a Bedrock model ID, ARN, or cross-region inference profile), use it as-is.
3. **Exact match in cached model list** — Match against the OpenAI-style `id` values derived from the cached Bedrock model list (e.g. `claude-sonnet-4-5-20250514` → `anthropic.claude-sonnet-4-5-20250514-v1:0`).
4. **Fuzzy match** — If no exact match, attempt prefix/contains matching. This handles cases like the trace's `claude-opus-4.6` which may not exactly match a dated Bedrock model ID. Match strategy: find models whose derived ID starts with the input after normalizing dots to hyphens (e.g. `claude-opus-4.6` → look for model IDs starting with `claude-opus-4-6`).
5. **404 on miss** — If no match is found, return 404 with an OpenAI-style error before contacting Bedrock.

---

## Authentication

### Client → Proxy (API Key)

- Proxy reads a configured API key (environment variable `PROXY_API_KEY`).
- Hummingbird middleware checks `x-api-key` header.
- Returns `401 Unauthorized` with OpenAI-style error JSON on mismatch:
  ```json
  {"error": {"message": "Invalid API key", "type": "invalid_request_error", "code": "invalid_api_key"}}
  ```
- If `PROXY_API_KEY` is not set, auth is disabled (development mode).

### Proxy → Bedrock (AWS SigV4 via soto-core)

Credential resolution and SigV4 signing are handled by **soto-core** (`SotoCore` + `SotoSignerV4`). This provides the full AWS credential chain out of the box:

1. Environment variables: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`
2. `~/.aws/credentials` file (default profile or `AWS_PROFILE`)
3. `~/.aws/config` (SSO, role assumption via `role_arn` / `source_profile`)
4. ECS task role (via `AWS_CONTAINER_CREDENTIALS_RELATIVE_URI`)
5. EC2 instance metadata (IMDSv2)
6. `aws login` command cache / SSO token refresh

Region sourced from:
1. Environment variable `AWS_REGION` or `AWS_DEFAULT_REGION`
2. `~/.aws/config`
3. CLI argument `--region`

#### SigV4 signing

The proxy creates an `AWSSigner` (from `SotoSignerV4`) with the loaded credentials, service name `"bedrock"`, and region. For each outbound request, it calls:

```swift
let signedHeaders = signer.signHeaders(
    url: bedrockURL,
    method: .POST,
    headers: headers,
    body: .byteBuffer(requestBody)
)
```

This returns `HTTPHeaders` with the `Authorization`, `X-Amz-Date`, `X-Amz-Security-Token` (if applicable), and `X-Amz-Content-Sha256` headers already computed.

#### Credential refresh

Soto-core's `CredentialProvider` protocol handles credential expiry and refresh automatically. SSO tokens, STS assumed-role credentials, and IMDS temporary credentials are all refreshed transparently. The proxy creates the credential provider once at startup and calls `getCredential(logger:)` before each signing operation.

#### Two Bedrock hosts

The proxy signs requests against two different Bedrock hosts. The SigV4 service name is `bedrock` in both cases, but the host differs:

| Purpose | Host | Used by |
|---|---|---|
| Runtime (inference) | `bedrock-runtime.{region}.amazonaws.com` | `POST /model/{id}/invoke`, `POST /model/{id}/invoke-with-response-stream` |
| Control plane (model listing) | `bedrock.{region}.amazonaws.com` | `GET /foundation-models` |

The proxy creates the `AWSSigner` with the appropriate host for each request.

---

## Streaming: EventStream → OpenAI SSE Translation

This is the most complex part of the proxy.

### Non-Streaming Path

1. Client sends `"stream": false` (or omits it).
2. Proxy calls Bedrock `/invoke`.
3. Bedrock returns Anthropic-format JSON.
4. Proxy translates to OpenAI Chat Completion JSON (see translation rules above).
5. Returns to client with `Content-Type: application/json`.

### Streaming Path

1. Client sends `"stream": true`.
2. Proxy calls Bedrock `/invoke-with-response-stream`.
3. Bedrock returns `Content-Type: application/vnd.amazon.eventstream` — a **binary** protocol.
4. Proxy parses EventStream frames, translates Anthropic streaming events to OpenAI SSE chunks, and emits them to the client.

#### AWS EventStream Binary Frame Format

```
[total_length: 4 bytes, big-endian uint32]
[headers_length: 4 bytes, big-endian uint32]
[prelude_crc: 4 bytes, CRC-32]
[headers: variable length]
[payload: variable length]
[message_crc: 4 bytes, CRC-32]
```

Each header:
```
[name_length: 1 byte]
[name: variable]
[type: 1 byte]  (7 = string)
[value_length: 2 bytes, big-endian]
[value: variable]
```

Key headers in each frame:
- `:message-type` — `"event"` or `"exception"`
- `:event-type` — `"chunk"` for data frames
- `:content-type` — `"application/json"`

The **payload** of each `chunk` event is a JSON object:
```json
{"bytes": "<base64-encoded JSON>"}
```

After base64-decoding `bytes`, you get Anthropic streaming events:
```json
{"type": "message_start", "message": {...}}
{"type": "content_block_start", ...}
{"type": "content_block_delta", ...}
{"type": "content_block_stop", ...}
{"type": "message_delta", ...}
{"type": "message_stop"}
```

#### SSE Heartbeat Comments

The captured OpenRouter response shows SSE comment lines (`: OPENROUTER PROCESSING`) emitted **before** the first data chunk and intermittently during the stream. These are valid SSE and serve as keep-alive signals, preventing the client from timing out while the backend processes the request.

The proxy emits similar heartbeat comments:
- `: processing` — emitted every 5 seconds while waiting for Bedrock's first EventStream frame (Bedrock can take several seconds to start streaming, especially with extended thinking).
- Implemented as a background task that yields comment lines into the SSE response stream until the first data chunk is ready.

#### Anthropic Event → OpenAI SSE Chunk Translation

The proxy maintains state across the stream (a generated `id`, the `model` name, a `created` timestamp) and translates each Anthropic event to an OpenAI chunk.

**Important:** The captured OpenRouter response includes `"role": "assistant"` in the `delta` of **every** chunk, not just the first one. For maximum Xcode compatibility, the proxy does the same — every chunk's `delta` includes `"role": "assistant"`.

| Anthropic event | OpenAI SSE chunk | Notes |
|---|---|---|
| `message_start` | `{"id":"chatcmpl-...","object":"chat.completion.chunk","created":T,"model":"...","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}` | First chunk establishes the role with empty content. Extract `id` from the `message` payload. Use the **client's original model name** (not Bedrock's). Capture `usage.input_tokens` for later. |
| `content_block_start` (type=text) | (no output) | Nothing to emit; text content comes via deltas. |
| `content_block_start` (type=tool_use) | `{"choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":N,"id":"...","type":"function","function":{"name":"...","arguments":""}}]},"finish_reason":null}]}` | Start of a tool call. Track the tool_call index. |
| `content_block_delta` (text_delta) | `{"choices":[{"index":0,"delta":{"role":"assistant","content":"Hello"},"finish_reason":null}]}` | Stream text content. Every chunk includes `role`. |
| `content_block_delta` (input_json_delta) | `{"choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":N,"function":{"arguments":"..."}}]},"finish_reason":null}]}` | Stream tool call arguments incrementally. |
| `content_block_stop` | (no output) | Nothing to emit. |
| `message_delta` | `{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}` | Map `stop_reason` to `finish_reason` (same mapping as non-streaming). |
| `message_stop` | — | If `include_usage` was requested, emit a usage chunk: `{"choices":[],"usage":{"prompt_tokens":P,"completion_tokens":C,"total_tokens":T}}`. Then emit `data: [DONE]`. |

#### SSE Output Format

OpenAI SSE uses `data:` lines and `:` comment lines (no `event:` line), terminated by `data: [DONE]`:

```
: processing

: processing

data: {"id":"chatcmpl-msg_abc","object":"chat.completion.chunk","created":1740063600,"model":"claude-sonnet-4-5-20250514","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}

data: {"id":"chatcmpl-msg_abc","object":"chat.completion.chunk","created":1740063600,"model":"claude-sonnet-4-5-20250514","choices":[{"index":0,"delta":{"role":"assistant","content":"Hello"},"finish_reason":null}]}

data: {"id":"chatcmpl-msg_abc","object":"chat.completion.chunk","created":1740063600,"model":"claude-sonnet-4-5-20250514","choices":[{"index":0,"delta":{"role":"assistant","content":"!"},"finish_reason":null}]}

data: {"id":"chatcmpl-msg_abc","object":"chat.completion.chunk","created":1740063600,"model":"claude-sonnet-4-5-20250514","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

data: {"id":"chatcmpl-msg_abc","object":"chat.completion.chunk","created":1740063600,"model":"claude-sonnet-4-5-20250514","choices":[],"usage":{"prompt_tokens":25,"completion_tokens":10,"total_tokens":35}}

data: [DONE]
```

Note: `:` comment lines are SSE heartbeat/keep-alive signals emitted while waiting for Bedrock. `delta.role` is included on every content chunk (matching observed OpenRouter behavior for Xcode compatibility).

The proxy streams these using Hummingbird's `Response.Body` with an `AsyncStream` that yields SSE-formatted chunks as Bedrock events arrive.

Response headers to client:
- `Content-Type: text/event-stream`
- `Cache-Control: no-cache`
- `Connection: keep-alive`

---

## Error Handling

Errors are returned in **OpenAI format**:

```json
{
  "error": {
    "message": "...",
    "type": "...",
    "code": "..."
  }
}
```

| Bedrock error | Proxy response to client |
|---|---|
| 400 ValidationException | 400 `{"error":{"message":"...","type":"invalid_request_error","code":"invalid_request"}}` |
| 403 AccessDeniedException | 500 `{"error":{"message":"Bedrock access denied","type":"server_error","code":"server_error"}}` |
| 429 ThrottlingException | 429 `{"error":{"message":"...","type":"rate_limit_error","code":"rate_limit_exceeded"}}` |
| 404 ResourceNotFoundException | 404 `{"error":{"message":"Model not found","type":"invalid_request_error","code":"model_not_found"}}` |
| 408 ModelTimeoutException | 408 `{"error":{"message":"...","type":"server_error","code":"timeout"}}` |
| 5xx | 500 `{"error":{"message":"...","type":"server_error","code":"server_error"}}` |
| EventStream exception frame | SSE `data: {"error":{"message":"...","type":"server_error"}}` then `data: [DONE]` |

Unknown model names that fail resolution return 404 before reaching Bedrock.

---

## Configuration

All configuration via environment variables and/or CLI arguments (using ArgumentParser):

| Env Var / CLI Flag | Default | Description |
|---|---|---|
| `--hostname` / `PROXY_HOST` | `127.0.0.1` | Listen address |
| `--port` / `PROXY_PORT` | `8080` | Listen port |
| `PROXY_API_KEY` | (none — auth disabled) | API key clients must provide |
| `AWS_REGION` | `us-east-1` | Bedrock region |
| `AWS_PROFILE` | `default` | AWS credential profile (soto-core handles the full credential chain: env vars, config files, SSO, IMDS) |
| `MODEL_CACHE_TTL_SECONDS` | `300` | How long to cache the Bedrock model list (seconds) |
| `LOG_LEVEL` | `info` | Logging verbosity (`debug` enables full HTTP tracing) |

### Debug Mode

When `LOG_LEVEL` is set to `debug`, the proxy logs the complete HTTP traffic on both sides of the proxy for every request. This is essential for diagnosing translation issues, signing failures, and unexpected Bedrock behavior.

**Client → Proxy (inbound):**
```
→ POST /v1/chat/completions HTTP/1.1
→ host: localhost:8080
→ authorization: Bearer sk-***
→ content-type: application/json
→ content-length: 10470
→ <request body JSON, pretty-printed>
```

**Proxy → Bedrock (outbound):**
```
⇒ POST /model/anthropic.claude-opus-4-6-20251014-v1:0/invoke-with-response-stream HTTP/1.1
⇒ host: bedrock-runtime.us-east-1.amazonaws.com
⇒ content-type: application/json
⇒ x-amz-date: 20260220T120000Z
⇒ x-amz-security-token: FwoGZX...
⇒ x-amz-content-sha256: abc123...
⇒ authorization: AWS4-HMAC-SHA256 Credential=AKIA.../20260220/us-east-1/bedrock/aws4_request, ...
⇒ <request body JSON, pretty-printed>
```

**Bedrock → Proxy (inbound response):**
```
⇐ HTTP/1.1 200 OK
⇐ content-type: application/vnd.amazon.eventstream
⇐ x-amzn-requestid: abc-123
⇐ <for non-streaming: response body JSON, pretty-printed>
⇐ <for streaming: each decoded EventStream frame payload, as JSON>
```

**Proxy → Client (outbound response):**
```
← HTTP/1.1 200 OK
← content-type: text/event-stream
← cache-control: no-cache
← <for non-streaming: response body JSON, pretty-printed>
← <for streaming: each SSE data line as emitted>
```

Implementation notes:
- Uses directional arrow prefixes (`→` `⇒` `⇐` `←`) to distinguish the four legs of each request at a glance in log output.
- Request/response bodies are pretty-printed JSON for readability.
- All headers are logged without redaction in debug mode — this includes `Authorization` and `x-amz-security-token`. Debug mode is intended for local development only.
- At `info` level, the proxy logs a single line per request: method, path, model, streaming flag, Bedrock status code, and latency. No headers or bodies.
- At `warning`/`error` levels, only errors and Bedrock failures are logged.
- Implemented as a Hummingbird `RouterMiddleware` that wraps the request/response lifecycle and logs before/after forwarding.

---

## Dependencies (Package.swift)

```
swift-tools-version: 6.0
platforms: [.macOS(.v14)]
```

| Package | Version | Purpose |
|---|---|---|
| `hummingbird` | 2.19.0+ | HTTP server, router, middleware |
| `async-http-client` | 1.24.0+ | HTTPS client to Bedrock |
| `soto-core` | 7.0.0+ | AWS credential chain (env, file, SSO, IMDS) + SigV4 signing |
| `swift-argument-parser` | 1.4.0+ | CLI argument parsing |
| `swift-nio` | (transitive) | Byte buffer manipulation, EventStream parsing |
| `swift-log` | (transitive) | Structured logging |
| `swift-crypto` | (transitive via soto-core) | Cryptographic primitives |

**No dependency on:** AWS SDK for Swift, Combine, or any Apple-only framework. Use `FoundationEssentials` (via `import FoundationEssentials`) for JSON encoding/decoding, Date, URL — compiles on Linux. Soto-core is used only for credential resolution and SigV4 signing — the proxy does not use any Soto service clients.

---

## Project Structure

```
anthopric-proxy/
├── Package.swift
├── Sources/
│   └── App/
│       ├── app.swift                         # @main entry point (ArgumentParser)
│       ├── Application+build.swift           # Hummingbird app setup, routes, service lifecycle
│       ├── Config.swift                      # Configuration struct (env vars + CLI args)
│       ├── Middleware/
│       │   ├── APIKeyAuthMiddleware.swift     # Validates x-api-key header
│       │   └── DebugLoggingMiddleware.swift   # Logs full HTTP traffic at debug level
│       ├── Models/
│       │   ├── OpenAITypes.swift             # Codable types for OpenAI request/response
│       │   ├── BedrockTypes.swift            # Codable types for Bedrock/Anthropic request/response
│       │   ├── BedrockModels.swift           # Codable types for ListFoundationModels response
│       │   └── JSONValue.swift               # Generic JSON value type for passthrough
│       ├── Proxy/
│       │   ├── ChatCompletionsHandler.swift  # POST /v1/chat/completions route handler
│       │   ├── ModelsHandler.swift           # GET /v1/models and /v1/models/{model_id}
│       │   ├── RequestTranslator.swift       # OpenAI → Bedrock body + URL
│       │   └── ResponseTranslator.swift      # Bedrock → OpenAI response
│       └── Streaming/
│           ├── EventStreamParser.swift       # AWS EventStream binary frame decoder
│           └── OpenAISSEEncoder.swift        # Translates Anthropic events → OpenAI SSE chunks
├── Tests/
│   └── AppTests/
│       ├── RequestTranslatorTests.swift      # OpenAI → Bedrock translation tests
│       ├── ResponseTranslatorTests.swift     # Bedrock → OpenAI translation tests
│       ├── EventStreamParserTests.swift      # Binary frame parsing tests
│       ├── ModelsHandlerTests.swift          # Model discovery, Bedrock→OpenAI translation, caching
│       ├── XcodeTraceValidationTests.swift   # Tests based on captured Xcode trace
│       └── IntegrationTests.swift            # End-to-end with mock Bedrock server
├── Fixtures/
│   └── xcode-chat-request.json              # Captured Xcode request body for test fixtures
├── Containerfile                             # For Apple container / Linux testing
└── README.md
```

---

## Linux Testing with Apple Container

```bash
# Build the Containerfile
container build --tag anthopric-proxy-test -f ./Containerfile

# Run tests inside the container
container run anthopric-proxy-test swift test
```

**Containerfile:**
```dockerfile
FROM swift:6.2
WORKDIR /app
COPY . .
RUN swift build
CMD ["swift", "test"]
```

Alternatively, for iterative development:
```bash
container run --volume .:/app swift:6.2 bash -c "cd /app && swift build && swift test"
```

---

## Task List

### Phase 1: Project Scaffolding
1. **Initialize Swift package** — Create `Package.swift` with all dependencies, create directory structure, verify `swift build` compiles an empty executable on macOS.
2. **Set up Containerfile** — Create `Containerfile` using `swift:6.2` base image, verify `container build` and `swift build` succeed inside it.
3. **Create `app.swift` entry point** — ArgumentParser `@main` struct with CLI flags (hostname, port, region). Wire up Hummingbird app skeleton that responds to `GET /health` with 200.

### Phase 2: Core Data Models
4. **Define OpenAI request/response Codable types** — `ChatCompletionRequest`, `ChatCompletionResponse`, `ChatCompletionChunk`, message types with string-or-array content, tool call types. Use a JSON-preserving approach where feasible: decode known fields, preserve unknown fields via `JSONValue` for forward compatibility.
5. **Define Bedrock/Anthropic request/response types** — `BedrockInvokeRequest` with `anthropic_version` plus pass-through fields. `BedrockListModelsResponse` and `FoundationModelSummary` for the `ListFoundationModels` API. Anthropic streaming event types (`message_start`, `content_block_delta`, etc.).

### Phase 3: AWS Credentials & Signing
6. **Wire up soto-core credentials and signing** — Initialize `CredentialProviderFactory.default` for the full AWS credential chain (env, config file, SSO, IMDS). Create a helper that loads credentials via `getCredential(logger:)` and builds an `AWSSigner` for a given service/host/region. Verify credentials load correctly with a simple test that signs a dummy request.

### Phase 4: Request/Response Translation
7. **Implement `RequestTranslator`** — Takes OpenAI `ChatCompletionRequest` JSON, returns Bedrock URL + Bedrock request body. Handles: `model` extraction + resolution, `stream`/`stream_options` extraction, system message extraction, message content normalization, tool format translation, `anthropic_version` injection.
8. **Implement `ResponseTranslator` (non-streaming)** — Takes Bedrock/Anthropic JSON response, returns OpenAI `ChatCompletionResponse` JSON. Translates content blocks, tool_use blocks, stop_reason, usage.
9. **Write translation unit tests** — Cover: system message extraction, content normalization (string → array), tool format translation (both directions), stop_reason mapping, model name resolution, unknown-field passthrough. **Include `XcodeTraceValidationTests`** that feed the exact captured Xcode request body through `RequestTranslator` and verify the Bedrock output.

### Phase 5: Model Discovery Endpoint
10. **Implement `ModelsHandler`** — `GET /v1/models` calls Bedrock `ListFoundationModels` (control plane), filters to active Anthropic models, translates to OpenAI model objects (`id`, `object`, `created` as Unix timestamp, `owned_by`), and returns `{"object": "list", "data": [...]}`. `GET /v1/models/{model_id}` returns a single model or 404. Implement a caching actor with configurable TTL. The cached model list is also used by `RequestTranslator` for model name resolution. Wire into router. Write unit tests.

### Phase 6: API Key Auth Middleware
11. **Implement `APIKeyAuthMiddleware`** — Hummingbird `RouterMiddleware` that checks `x-api-key` header against configured key. Returns OpenAI-style 401 error JSON on failure. Proxy refuses to start if no key is configured.

### Phase 7: Non-Streaming Proxy Path
12. **Implement `ChatCompletionsHandler` (non-streaming)** — Hummingbird route handler for `POST /v1/chat/completions`. Reads body, translates OpenAI → Bedrock, signs via `AWSSigner.signHeaders()`, sends via `AsyncHTTPClient`, translates Bedrock → OpenAI, returns to client. Wire into router.
13. **Implement Bedrock error → OpenAI error mapping** — Map HTTP status codes and Bedrock exception types to OpenAI error format.
14. **End-to-end test (non-streaming)** — Use `HummingbirdTesting` to send an OpenAI-format request to the proxy, mock Bedrock responses, verify correct OpenAI-format response.

### Phase 8: Streaming
15. **Implement `EventStreamParser`** — Parses AWS EventStream binary frames from a `NIOCore.ByteBuffer` or `AsyncSequence<ByteBuffer>`. Yields decoded payloads (JSON bytes) as an `AsyncStream`. Handle CRC validation, header parsing, base64 decoding of the `bytes` field.
16. **Implement `OpenAISSEEncoder`** — Stateful translator that takes decoded Anthropic event JSON and emits OpenAI SSE `data:` lines. Maintains stream state (id, original client model name, created, tool_call index, usage accumulator). Includes `delta.role: "assistant"` on every content chunk (matching observed OpenRouter behavior). Emits usage chunk if `include_usage` was requested. Terminates with `data: [DONE]`.
17. **Implement streaming proxy path** — When `stream: true`, call `/invoke-with-response-stream`, pipe response through `EventStreamParser` → `OpenAISSEEncoder` → Hummingbird streaming `Response.Body`. Set correct SSE headers. Emit `: processing` heartbeat comment lines every 5 seconds while waiting for Bedrock's first frame (prevents Xcode client timeout).
18. **Write EventStream parser tests** — Construct sample binary frames, verify correct parsing. Test partial frame buffering (frames may span multiple TCP reads).
19. **End-to-end streaming test** — Send streaming request in OpenAI format, mock Bedrock EventStream response with Anthropic events, verify OpenAI SSE output matches expected format including `data: [DONE]` terminator and optional usage chunk.

### Phase 9: Hardening & Polish
20. **Timeout configuration** — Set `AsyncHTTPClient` read timeout to 600s (Bedrock Claude timeouts can be up to 60 min for thinking models; 10 min is a reasonable default). Make configurable.
21. **Graceful shutdown** — Wire Hummingbird + AsyncHTTPClient into `ServiceGroup` for clean lifecycle management (modeled after the Hummingbird proxy example).
22. **Logging** — Implement `DebugLoggingMiddleware` for full HTTP tracing at `debug` level (all headers and bodies on all four legs). At `info` level, log a single summary line per request. Pretty-print JSON bodies in debug output.
23. **Request validation** — Validate required fields (`model`, `messages`) before forwarding. Return early with 400 in OpenAI error format if missing.

### Phase 10: Linux Verification
24. **Full Linux build + test** — Run `container build` and `container run ... swift test` to verify everything compiles and tests pass on Linux with `swift:6.2`. Fix any platform-specific issues (Foundation vs. FoundationEssentials imports).

### Phase 11: Documentation
25. **Write README** — Usage instructions, configuration reference, Docker/container instructions, example curl commands showing OpenAI Chat Completions format.

---

## Validation Test: Xcode Trace

The following test verifies that the proxy correctly translates the exact request captured from Xcode 26 talking to OpenRouter. This is the primary acceptance test for request translation.

### Test: `testXcodeRequestTranslation`

**Input** (captured Xcode request body — truncated for readability):

```json
{
  "messages": [
    {
      "content": "You are a coding assistant...",
      "role": "system"
    },
    {
      "content": [
        {
          "text": "The user is currently inside this file: CLIMain.swift\n...\nThe user has asked:\n\nWho are you\n",
          "type": "text"
        }
      ],
      "role": "user"
    }
  ],
  "model": "anthropic/claude-opus-4.6",
  "stream": true,
  "stream_options": {
    "include_usage": true
  },
  "tools": []
}
```

**Expected Bedrock request body:**

```json
{
  "anthropic_version": "bedrock-2023-05-31",
  "max_tokens": 8192,
  "system": "You are a coding assistant...",
  "messages": [
    {
      "role": "user",
      "content": [
        {
          "type": "text",
          "text": "The user is currently inside this file: CLIMain.swift\n...\nThe user has asked:\n\nWho are you\n"
        }
      ]
    }
  ]
}
```

**Assertions:**
1. `model` field is removed from body and resolved to Bedrock model ID in URL path.
2. `stream` and `stream_options` are removed from body; `stream=true` routes to `/invoke-with-response-stream`; `include_usage=true` is stored for SSE encoding.
3. System message (`role: "system"`) is extracted from `messages` array and placed in top-level `system` field.
4. User message `content` array is passed through unchanged (already in Anthropic format).
5. `anthropic_version` is injected as `"bedrock-2023-05-31"`.
6. `max_tokens` defaults to `8192` since client did not specify it.
7. Empty `tools` array is omitted from Bedrock body.
8. `anthropic/` prefix is stripped from model name → `claude-opus-4.6`.
9. Model resolution finds a matching Bedrock model ID (e.g. `anthropic.claude-opus-4-6-20251014-v1:0`) via fuzzy matching.

### Test: `testXcodeModelsRequest`

**Input:** `GET /v1/models?` (empty query string, as Xcode sends)

**Mock Bedrock response:**
```json
{
  "modelSummaries": [
    {
      "modelId": "anthropic.claude-opus-4-6-20251014-v1:0",
      "modelName": "Claude Opus 4.6",
      "providerName": "Anthropic",
      "inputModalities": ["TEXT", "IMAGE"],
      "outputModalities": ["TEXT"],
      "responseStreamingSupported": true,
      "modelLifecycle": { "status": "ACTIVE" }
    },
    {
      "modelId": "anthropic.claude-sonnet-4-5-20250514-v1:0",
      "modelName": "Claude Sonnet 4.5",
      "providerName": "Anthropic",
      "inputModalities": ["TEXT", "IMAGE"],
      "outputModalities": ["TEXT"],
      "responseStreamingSupported": true,
      "modelLifecycle": { "status": "ACTIVE" }
    }
  ]
}
```

**Expected response to Xcode:**
```json
{
  "object": "list",
  "data": [
    {
      "id": "claude-opus-4-6-20251014",
      "object": "model",
      "created": 1728864000,
      "owned_by": "anthropic"
    },
    {
      "id": "claude-sonnet-4-5-20250514",
      "object": "model",
      "created": 1747267200,
      "owned_by": "anthropic"
    }
  ]
}
```

**Assertions:**
1. Response uses OpenAI format (`object: "list"`, `data` array, each item has `object: "model"`).
2. `created` is a Unix timestamp integer, not an ISO date string.
3. `owned_by` is `"anthropic"` (lowercased from `providerName`).
4. Model IDs have `anthropic.` prefix and `-v1:0` suffix stripped.
5. No Anthropic-format fields (`type`, `display_name`, `created_at`, `first_id`, `last_id`, `has_more`).

### Test: `testXcodeStreamingResponse`

Verifies that a streaming Bedrock response is correctly translated to OpenAI SSE format, matching the structure observed in the captured OpenRouter response.

**Bedrock EventStream payload sequence** (after base64 decoding):
```json
{"type":"message_start","message":{"id":"msg_abc","type":"message","role":"assistant","model":"claude-opus-4-6-20251014","content":[],"usage":{"input_tokens":512,"output_tokens":1}}}
{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hey"}}
{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"! I'm doing great"}}
{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":", thanks for asking."}}
{"type":"content_block_stop","index":0}
{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":12}}
{"type":"message_stop"}
```

**Expected SSE output to Xcode** (matching observed OpenRouter format):
```
data: {"id":"chatcmpl-msg_abc","object":"chat.completion.chunk","created":1740063600,"model":"claude-opus-4-6-20251014","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}

data: {"id":"chatcmpl-msg_abc","object":"chat.completion.chunk","created":1740063600,"model":"claude-opus-4-6-20251014","choices":[{"index":0,"delta":{"role":"assistant","content":"Hey"},"finish_reason":null}]}

data: {"id":"chatcmpl-msg_abc","object":"chat.completion.chunk","created":1740063600,"model":"claude-opus-4-6-20251014","choices":[{"index":0,"delta":{"role":"assistant","content":"! I'm doing great"},"finish_reason":null}]}

data: {"id":"chatcmpl-msg_abc","object":"chat.completion.chunk","created":1740063600,"model":"claude-opus-4-6-20251014","choices":[{"index":0,"delta":{"role":"assistant","content":", thanks for asking."},"finish_reason":null}]}

data: {"id":"chatcmpl-msg_abc","object":"chat.completion.chunk","created":1740063600,"model":"claude-opus-4-6-20251014","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

data: {"id":"chatcmpl-msg_abc","object":"chat.completion.chunk","created":1740063600,"model":"claude-opus-4-6-20251014","choices":[],"usage":{"prompt_tokens":512,"completion_tokens":12,"total_tokens":524}}

data: [DONE]
```

**Assertions:**
1. SSE uses `data:` lines only (no `event:` lines — that's Anthropic SSE format).
2. Each chunk has consistent `id`, `object`, `created`, `model`.
3. First chunk has `delta.role` and empty `delta.content`.
4. **Every content chunk includes `delta.role: "assistant"`** (matching observed OpenRouter behavior).
5. Text deltas map to `delta.content`.
6. `stop_reason: "end_turn"` maps to `finish_reason: "stop"`.
7. Usage chunk is emitted (because `stream_options.include_usage` was `true`).
8. Stream terminates with `data: [DONE]`.
9. Heartbeat comment lines (`: processing`) may precede the first data chunk.

---

## Open Questions / Future Work

- **Request body passthrough strategy**: Using `Codable` with strict types risks dropping unknown fields when OpenAI or Anthropic adds new API parameters. Consider a JSON-preserving approach: decode as `[String: JSONValue]`, mutate only the fields we care about, re-encode. This ensures forward compatibility.
- **Cross-region inference**: Bedrock supports inference profiles for cross-region routing. The proxy should allow model IDs that are full ARNs or inference profile IDs — the "pass-through if it looks like a Bedrock ID" rule handles this.
- **Image content**: OpenAI uses `image_url` content parts with data URLs or HTTP URLs. Anthropic uses `image` content parts with base64 source. Translation needed for multi-modal requests.
- **Extended thinking / reasoning**: The captured OpenRouter response includes `reasoning` and `reasoning_details` fields (currently `null`/`[]`). When Claude's extended thinking is enabled, Bedrock returns `thinking` content blocks. These should map to `reasoning`/`reasoning_details` in the OpenAI SSE chunks so Xcode can display the thinking process. Not in scope for v1 but the response translator should be structured to support this.
- **Model name echo**: The captured response echoes back `"anthropic/claude-opus-4.6"` as the `model` field, matching what the client sent. The proxy should store the original client model name and echo it back in responses rather than using the resolved Bedrock model ID. This ensures clients see the model name they requested.
- **Rate limiting**: Not in scope for v1. Bedrock enforces its own throttling; the proxy surfaces it as 429.
- **Multi-region failover**: Not in scope for v1.
- **Response caching**: Not in scope for v1.

---

## Appendix: Captured Xcode Traffic

Real HTTP traffic captured from Xcode 26 talking to OpenRouter via a sniffing proxy. This trace is the ground truth for the proxy's inbound API surface.

### Model listing request

```
GET /v1/models? HTTP/1.1
Host: localhost:8080
Content-Type: application/json
Connection: keep-alive
Accept: application/json
User-Agent: Xcode/24577 CFNetwork/3860.400.51 Darwin/25.3.0
Authorization: Bearer sk-or-v1-2db4dce59b29cd8c024183f09b4709f0...
Accept-Language: en-GB,en;q=0.9
Accept-Encoding: gzip, deflate
```

### Chat completions request

```
POST /v1/chat/completions HTTP/1.1
Host: localhost:8080
Content-Type: application/json
User-Agent: Xcode/24577 CFNetwork/3860.400.51 Darwin/25.3.0
Connection: keep-alive
Accept: application/json
Accept-Language: en-GB,en;q=0.9
Authorization: Bearer sk-or-v1-2db4dce59b29cd8c024183f09b4709f0...
Accept-Encoding: gzip, deflate
Content-Length: 10470

{
  "messages": [
    {
      "content": "You are a coding assistant--with access to tools--specializing in analyzing codebases...",
      "role": "system"
    },
    {
      "content": [
        {
          "text": "The user is currently inside this file: CLIMain.swift\n...\nThe user has asked:\n\nWho are you\n",
          "type": "text"
        }
      ],
      "role": "user"
    }
  ],
  "model": "anthropic/claude-opus-4.6",
  "stream": true,
  "stream_options": {
    "include_usage": true
  },
  "tools": []
}
```

**Key observations (request):**
- Xcode uses `POST /v1/chat/completions` — the **OpenAI Chat Completions API**, not `POST /v1/messages` (Anthropic).
- Xcode sends the API key via the `x-api-key` header.
- No `anthropic-version` or `x-api-key` headers — pure OpenAI protocol.
- Model name uses OpenRouter convention: `"anthropic/claude-opus-4.6"` (provider prefix + display name).
- System prompt is a message with `"role": "system"` in the messages array.
- User message content is an array of `{"type": "text", "text": "..."}` parts.
- `stream_options.include_usage` is set to `true` — expects usage data in streaming response.
- `tools` is an empty array (Xcode sends this even when no tools are available).
- Empty query string on models endpoint (`GET /v1/models?`).
- `Accept: application/json` on all requests.

### Streaming response (from OpenRouter)

```
HTTP/1.1 200
Content-Type: text/event-stream
Transfer-Encoding: chunked
Connection: close
Cache-Control: no-cache

: OPENROUTER PROCESSING

: OPENROUTER PROCESSING

: OPENROUTER PROCESSING

data: {"id":"gen-1771592802-hDlyfTXagKZBer6JQTBv","provider":"Amazon Bedrock","model":"anthropic/claude-opus-4.6","object":"chat.completion.chunk","created":1771592802,"choices":[{"index":0,"delta":{"role":"assistant","content":"","reasoning":null,"reasoning_details":[]},"finish_reason":null,"native_finish_reason":null,"logprobs":null}]}

data: {"id":"gen-1771592802-hDlyfTXagKZBer6JQTBv","provider":"Amazon Bedrock","model":"anthropic/claude-opus-4.6","object":"chat.completion.chunk","created":1771592802,"choices":[{"index":0,"delta":{"role":"assistant","content":"","reasoning":null,"reasoning_details":[]},"finish_reason":null,"native_finish_reason":null,"logprobs":null}]}

data: {"id":"gen-1771592802-hDlyfTXagKZBer6JQTBv","provider":"Amazon Bedrock","model":"anthropic/claude-opus-4.6","object":"chat.completion.chunk","created":1771592802,"choices":[{"index":0,"delta":{"role":"assistant","content":"Hey","reasoning":null,"reasoning_details":[]},"finish_reason":null,"native_finish_reason":null,"logprobs":null}]}

data: {"id":"gen-1771592802-hDlyfTXagKZBer6JQTBv","provider":"Amazon Bedrock","model":"anthropic/claude-opus-4.6","object":"chat.completion.chunk","created":1771592802,"choices":[{"index":0,"delta":{"role":"assistant","content":"! I'm doing great","reasoning":null,"reasoning_details":[]},"finish_reason":null,"native_finish_reason":null,"logprobs":null}]}

data: {"id":"gen-1771592802-hDlyfTXagKZBer6JQTBv","provider":"Amazon Bedrock","model":"anthropic/claude-opus-4.6","object":"chat.completion.chunk","created":1771592802,"choices":[{"index":0,"delta":{"role":"assistant","content":", thanks for asking.","reasoning":null,"reasoning_details":[]},"finish_reason":null,"native_finish_reason":null,"logprobs":null}]}

...truncated (stream continues with more content chunks)...
```

**Key observations (response):**
- **SSE comment lines for heartbeat**: `: OPENROUTER PROCESSING` lines emitted before and during the stream. Valid SSE — serves as keep-alive to prevent client timeouts.
- **`delta.role` on every chunk**: `"role": "assistant"` appears in the `delta` of **every** chunk, not just the first. The proxy must replicate this for Xcode compatibility.
- **Two empty-content chunks at start**: The first two data chunks both have `"content": ""`. This likely corresponds to Bedrock's `message_start` and `content_block_start` events both translating to empty content chunks.
- **Extra OpenRouter-specific fields**: `provider`, `reasoning`, `reasoning_details`, `native_finish_reason`, `logprobs` — these are not part of the standard OpenAI spec. Xcode ignores unknown fields. The proxy does **not** need to emit these.
- **`reasoning` / `reasoning_details`**: These fields (currently `null`/`[]`) are how OpenRouter surfaces Claude's extended thinking output. Future work: when extended thinking is enabled, Bedrock returns `thinking` content blocks that should map to these fields.
- **ID format**: OpenRouter uses `gen-` prefix. Standard OpenAI uses `chatcmpl-`. The proxy uses `chatcmpl-` (Xcode accepts any prefix).
- **`model` in response**: Echoes back `"anthropic/claude-opus-4.6"` (the model name as sent by the client). The proxy should echo back the model name from the request, not the resolved Bedrock model ID.
