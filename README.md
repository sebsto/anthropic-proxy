# anthopric-proxy

A self-hosted Swift 6 proxy that sits between Xcode 26 and Amazon Bedrock, translating between the OpenAI Chat Completions API and Bedrock's SigV4-signed, binary EventStream protocol.

## How It Works

```
┌────────┐  OpenAI Chat Completions  ┌─────────────┐  Bedrock REST (SigV4)  ┌─────────┐
│ Xcode  │ ────────────────────────► │anthopric-   │ ─────────────────────► │ Amazon  │
│ (or    │  x-api-key: <key>        │proxy        │  AWS4-HMAC-SHA256      │ Bedrock │
│  curl) │ ◄──────────────────────── │(Hummingbird)│ ◄───────────────────── │(Claude) │
│        │  SSE stream / JSON        │             │  EventStream / JSON    │         │
└────────┘                           └─────────────┘                        └─────────┘
```

The proxy handles:

- **Request translation** -- OpenAI Chat Completions format to Bedrock/Anthropic request body and URL
- **Response translation** -- Bedrock JSON to OpenAI JSON, or Bedrock EventStream binary frames to OpenAI SSE text chunks
- **Model discovery** -- Bedrock `ListFoundationModels` to OpenAI models list for Xcode's model picker
- **AWS authentication** -- SigV4 signing via the standard AWS credential chain
- **Model name resolution** -- maps between OpenAI-style model IDs (e.g. `anthropic/claude-opus-4.6`) and Bedrock model IDs

For the full design, see [docs/DESIGN.md](docs/DESIGN.md).

## Prerequisites

- **Swift 6.0+** (tested with Swift 6.2)
- **AWS credentials** configured via any standard method (environment variables, `~/.aws/credentials`, SSO, IAM roles)
- **Bedrock model access** enabled in your AWS account for the Anthropic models you want to use
- **macOS 15+** or **Linux** (builds on both)

## Quick Start

```bash
# Clone
git clone https://github.com/your-org/anthopric-proxy.git
cd anthopric-proxy

# Build
swift build

# Run (API key is required)
PROXY_API_KEY=my-secret-key swift run App

# The proxy is now listening on http://127.0.0.1:8080
```

Or use a `config.json` file (see Configuration below) to avoid the key in your shell history.

### Configure Xcode 26

1. Open Xcode Settings > AI > Chat Model Configuration
2. Set the server URL to `http://127.0.0.1:8080/v1`
3. Enter your `PROXY_API_KEY` value as the API key
4. Select a Claude model from the model picker

## Configuration

Configuration is read from environment variables, with optional overrides from a `config.json` file in the working directory. CLI flags take highest precedence.

| Variable | Default | Description |
|---|---|---|
| `PROXY_HOST` | `127.0.0.1` | Listen address |
| `PROXY_PORT` | `8080` | Listen port |
| `AWS_REGION` / `AWS_DEFAULT_REGION` | `us-east-1` | AWS region for Bedrock API calls |
| `PROXY_API_KEY` | _(required)_ | API key clients must provide via `x-api-key` header. Proxy refuses to start without one. |
| `MODEL_CACHE_TTL_SECONDS` | `300` | How long to cache the Bedrock model list (seconds) |
| `REQUEST_TIMEOUT_SECONDS` | `600` | Timeout for chat completion requests (seconds) |
| `MODELS_TIMEOUT_SECONDS` | `30` | Timeout for model listing requests (seconds) |
| `LOG_LEVEL` | `info` | Logging verbosity: `debug`, `info`, `warning`, `error` |

### config.json

You can also place a `config.json` file in the working directory. Environment variables take precedence over file values.

```json
{
  "PROXY_HOST": "0.0.0.0",
  "PROXY_PORT": "8080",
  "AWS_REGION": "us-west-2",
  "PROXY_API_KEY": "my-secret-key",
  "LOG_LEVEL": "debug"
}
```

## CLI Options

```
USAGE: anthopric-proxy [--hostname <hostname>] [--port <port>]

OPTIONS:
  --hostname <hostname>   Hostname to listen on (default: 127.0.0.1)
  --port <port>           Port to listen on (default: 8080)
  -h, --help              Show help information.
```

CLI flags override both environment variables and `config.json`.

## API Endpoints

| Method | Path | Description |
|---|---|---|
| `GET` | `/health` | Health check (unauthenticated). Returns `{"status":"ok"}`. |
| `GET` | `/v1/models` | List available Anthropic models from Bedrock, in OpenAI format. |
| `GET` | `/v1/models/{model_id}` | Get a single model by ID. Returns 404 if not found. |
| `POST` | `/v1/chat/completions` | Chat completion (streaming and non-streaming). |

All `/v1/*` endpoints require the `x-api-key` header matching the configured `PROXY_API_KEY`.

## Container

Build and run with [Apple Container](https://github.com/apple/container):

```bash
# Build the image
container build --tag anthopric-proxy -f ./Containerfile

# Run (pass AWS credentials via environment)
container run \
  -p 8080:8080 \
  -e AWS_ACCESS_KEY_ID \
  -e AWS_SECRET_ACCESS_KEY \
  -e AWS_SESSION_TOKEN \
  -e AWS_REGION=us-east-1 \
  -e PROXY_API_KEY=my-secret-key \
  anthopric-proxy --hostname 0.0.0.0

# Run tests inside a container
container build --tag anthopric-proxy-test -f ./Containerfile --target builder
container run anthopric-proxy-test swift test
```

The Containerfile uses a multi-stage build: Swift 6.2 for compilation, `swift:6.2-slim` for the runtime image.

## Example curl Commands

### List models

```bash
curl http://127.0.0.1:8080/v1/models \
  -H "x-api-key: my-secret-key"
```

```json
{
  "object": "list",
  "data": [
    {
      "id": "claude-sonnet-4-5-20250514",
      "object": "model",
      "created": 1747267200,
      "owned_by": "anthropic"
    }
  ]
}
```

### Chat completion (streaming)

```bash
curl http://127.0.0.1:8080/v1/chat/completions \
  -H "x-api-key: my-secret-key" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude-sonnet-4-5-20250514",
    "stream": true,
    "messages": [
      {"role": "system", "content": "You are a helpful assistant."},
      {"role": "user", "content": "Hello!"}
    ]
  }'
```

### Chat completion (non-streaming)

```bash
curl http://127.0.0.1:8080/v1/chat/completions \
  -H "x-api-key: my-secret-key" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude-sonnet-4-5-20250514",
    "stream": false,
    "messages": [
      {"role": "user", "content": "What is 2 + 2?"}
    ]
  }'
```

```json
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
        "content": "2 + 2 = 4."
      },
      "finish_reason": "stop"
    }
  ],
  "usage": {
    "prompt_tokens": 12,
    "completion_tokens": 8,
    "total_tokens": 20
  }
}
```

## AWS Setup

1. **Enable model access** in the [Amazon Bedrock console](https://console.aws.amazon.com/bedrock/). Go to Model access, request access to the Anthropic Claude models you need, and wait for approval.

2. **Configure credentials** using any method supported by the AWS credential chain:

   ```bash
   # Option A: Environment variables
   export AWS_ACCESS_KEY_ID=AKIA...
   export AWS_SECRET_ACCESS_KEY=...
   export AWS_REGION=us-east-1

   # Option B: SSO (recommended for local development)
   aws sso login --profile my-profile
   export AWS_PROFILE=my-profile

   # Option C: IAM role (automatic on EC2/ECS/Lambda)
   # No configuration needed -- credentials are resolved via instance metadata.
   ```

3. **Verify access** by listing models through the proxy:

   ```bash
   swift run App
   curl http://127.0.0.1:8080/v1/models
   ```

   If you see an empty model list or errors, check that your credentials are valid and that Bedrock model access is enabled in the correct region.
