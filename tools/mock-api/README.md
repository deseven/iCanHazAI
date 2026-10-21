# Mock provider API

A local server that speaks the APIs of DeepSeek, OpenAI, Anthropic, OpenRouter, Ollama and llama.cpp (as documented in `dev-docs/`), for the smoke tests (`./build.sh smoke`). It can also be pointed at by hand, e.g. as a custom provider with the endpoint `http://127.0.0.1:<port>/ollama/v1`.

```sh
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt   # build.sh smoke does this itself
.venv/bin/python server.py --port 0       # prints "LISTENING http://127.0.0.1:<port>"
```

Streaming only (`stream: true`). Requests are validated strictly (auth headers, required fields, tool call pairing, Anthropic `max_tokens` against the model limit, no `system` role for Anthropic, …) and rejected with the provider's own error shape.

## Routes

The layout mirrors each provider's real base URL under a prefix.

| Prefix | Chat | Models |
| --- | --- | --- |
| `/deepseek` | `POST /chat/completions` | `GET /models` |
| `/openai` | `POST /v1/chat/completions` | `GET /v1/models` |
| `/anthropic` | `POST /v1/messages` | `GET /v1/models` (cursor paginated) |
| `/openrouter` | `POST /api/v1/chat/completions` | `GET /api/v1/models` (`q`, `limit`, `offset`), `GET /api/v1/key` |
| `/ollama` | `POST /v1/chat/completions` | `GET /v1/models` |
| `/llama-cpp` | `POST /v1/chat/completions` | `GET /v1/models` |
| `/litellm` | | `GET /model_prices_and_context_window.json` (the LiteLLM excerpt the app reads) |

The API key `bad-key` is rejected with 401 everywhere. Without a queued scenario a chat request gets an echo reply (flagged `scripted: false` in the log). Unknown URLs answer 404 and are logged under the channel `unknown`.

## Control API (`/__mock`)

| Call | Meaning |
| --- | --- |
| `POST /reset` | Clear scenarios, request log, gates and config |
| `POST /scenarios` `{"channel", "steps": [...]}` | Queue a scenario for the next chat request of the channel (`deepseek`, `openai`, `anthropic`, `openrouter`, `ollama`, `llama-cpp`) |
| `GET /requests[?channel=]` | The request log: headers (lowercased), parsed body, `state`, `status`, `scripted`, `waiting_gate`, `client_disconnected`, `mock_error` |
| `POST /gates/{name}/release` | Release a gate; releasing before it is reached works too |
| `POST /config` `{"channel", "page_size"?, "models"?, "models_status"?, "reject_keys"?}` | Per-channel overrides |
| `GET /status` | Pending scenarios, unscripted requests, mock-side rejections |

## Steps

See the docstring of `scenario.py`: `text`, `thinking`, `tool_call`, `usage`, `finish`, `open`, `gate`, `delay`, `keepalive`, `sse_error`, `http_error`, `drop` (reset), `close` (clean close mid-stream), `hold`. An empty step list is a valid scenario: an empty stream that just finishes.

```sh
curl -XPOST $MOCK/__mock/scenarios -d '{"channel":"deepseek","steps":[
  {"type":"thinking","text":"Let me think"},{"type":"text","text":"Hel"},{"type":"gate","name":"mid"},
  {"type":"text","text":"lo"},{"type":"usage","input":12,"output":4}]}'
curl -XPOST $MOCK/__mock/gates/mid/release
```

## Provider quirks reproduced

- DeepSeek: `reasoning_content`, usage in the final chunk, `usage: null` on the others.
- OpenAI: usage in a separate trailing chunk; no reasoning text.
- Anthropic: typed events (`message_start`, `content_block_*`, `message_delta`, `message_stop`), thinking blocks with signatures, `input_json_delta` tool calls, pagination, `tool_use`/`tool_result` pairing checks.
- OpenRouter: `reasoning` deltas, `cost` in usage, public `/models`, `/key` check.
- Ollama: no auth, whole tool call in a single delta, `reasoning` deltas, thin model list.
- llama.cpp: `reasoning_content`, `timings` next to usage, ignores the requested model name.
