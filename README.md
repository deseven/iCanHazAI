# iCanHazAI

A macOS app for AI chat with agentic capabilities.

> [!NOTE]
> WORK IN PROGRESS, NOT READY FOR DAILY USE YET

## Data Directory

On first launch, iCanHazAI creates its data directory at:

```
~/iCanHazAI/
├── chats/
├── roles/
└── connections/
    ├── openai/
    └── anthropic/
```

The directory lives directly in your home folder so you can edit chats, roles, and connections as plain text files with any editor. All subdirectories are watched with FSEvents — editing, adding, or removing files reloads the affected data automatically.

## Connections

A connection is a `{name}.toml` file placed in either `connections/openai/` or `connections/anthropic/`. The folder determines the provider (OpenAI-compatible or Anthropic) and `{name}` could be anything you like.

### OpenAI-compatible connections (`connections/openai/{name}.toml`)

```toml
# Optional. Custom endpoint for OpenAI-compatible providers.
# If omitted, the default OpenAI API is used.
endpoint = "https://api.openai.com/v1"

# Optional. API key. Some local endpoints may not require it.
token = "sk-..."

# Required. Any model string supported by the endpoint.
model = "gpt-4o"

# Optional parameters (all OpenAI-compatible):
temperature = 0.7
top_p = 0.9
reasoning_effort = "high"       # none/minimal/low/medium/high or custom string
frequency_penalty = 0.0
presence_penalty = 0.0
max_completion_tokens = 4096
seed = 42

# Optional. Arbitrary vendor-specific parameters injected into the request JSON.
# Useful for providers like DeepSeek/x.ai that support non-standard fields.
# Example: enable thinking on DeepSeek
# [vendor_parameters]
# thinking = { type = "enabled" }
```

### Anthropic connections (`connections/anthropic/{name}.toml`)

```toml
# Optional. Custom endpoint. If omitted, the default Anthropic API is used.
endpoint = "https://api.anthropic.com"

# Optional. API key. Some local endpoints may not require it.
token = "sk-ant-..."

# Required. Any model string supported by the endpoint.
model = "claude-3-5-sonnet-latest"

# Optional. Maximum number of tokens to generate. Defaults to 4096.
max_tokens = 8192

# Optional parameters (all Anthropic-specific):
temperature = 0.7
top_p = 0.9
top_k = 40
stop_sequences = ["END"]

# Optional. Extended thinking mode (Claude 3.7 Sonnet).
thinking_enabled = true
thinking_budget = 16000         # minimum 1024
```

### Connection attributes

| Attribute              | Provider  | Description                                                        |
|------------------------|-----------|--------------------------------------------------------------------|
| `endpoint`             | Both      | Custom API endpoint. Omit to use OpenAI/Anthropic defaults.        |
| `token`                | Both      | API key. Some local endpoints may not require authentication.      |
| `model`                | Both      | Model identifier (any text supported by the endpoint).             |
| `max_tokens`           | Anthropic | Max tokens to generate. Defaults to `4096`.                        |
| `temperature`          | Both      | Sampling temperature.                                              |
| `top_p`                | Both      | Nucleus sampling probability.                                      |
| `reasoning_effort`     | OpenAI    | Reasoning effort: none/minimal/low/medium/high or custom string.   |
| `frequency_penalty`    | OpenAI    | Frequency penalty.                                                 |
| `presence_penalty`     | OpenAI    | Presence penalty.                                                  |
| `max_completion_tokens`| OpenAI    | Maximum completion tokens.                                         |
| `seed`                 | OpenAI    | Random seed for deterministic output.                              |
| `top_k`                | Anthropic | Top-K sampling.                                                    |
| `stop_sequences`       | Anthropic | Custom stop sequences (array of strings).                          |
| `thinking_enabled`     | Anthropic | Enable extended thinking mode.                                     |
| `thinking_budget`      | Anthropic | Token budget for thinking (min 1024). Defaults to 16000.           |
| `vendor_parameters`    | OpenAI    | Arbitrary vendor-specific fields injected into the request JSON.   |

## Chats

A chat is a `name.json` file under `chats/`. New chats are named using the current date and time:

```
YYYY-MM-DD HH:mm:ss.json
```

### Structure

```json
{
  "id": "UUID",
  "messages": [
    {"id": "UUID", "role": "system", "content": "..."},
    {"id": "UUID", "role": "user", "content": "..."},
    {"id": "UUID", "role": "assistant", "content": "...", "thinking": "..."}
  ],
  "connection": "openai/my-connection",
  "role": "Assistant"
}
```

### Fields

| Field        | Description                                                                 |
|--------------|-----------------------------------------------------------------------------|
| `id`         | Unique chat identifier (UUID).                                              |
| `messages`   | Array of messages in the conversation.                                      |
| `connection` | Selected connection ID in the form `provider/name` (e.g. `openai/my-conn`). |
| `role`       | Selected role name. The role's content is sent as the system prompt.        |

### Message roles

- `system` — System prompt (injected from the selected role).
- `user` — User message.
- `assistant` — Model response. May include a `thinking` field for reasoning content from thinking models.

## Roles

A role is a `name.md` file containing plain text that becomes the system prompt when making requests.

### Custom roles

Place your own `name.md` files in the `roles/` directory. Custom roles with the same name as a default role will override it.

Example (`roles/Translator.md`):

```markdown
You are a professional translator. Translate the user's text to French. Provide only the translation, no explanations.
```

## Building

```bash
./build.sh
```

This builds the app and launches it. See `build.sh` for additional build modes (`dev-release`, `release`).
