<p align="center">
  <img src="res/main.png" width="160" alt="iCanHazAI">
</p>

<p align="center">
  AI chat with agentic capabilities, for macOS 15 or higher.
</p>


## Why

To address the elephant in the room: there are many AI chat apps and agentic harnesses already, both macOS-only and crossplatform. However, none of them really checked all the points for me. I wanted a single native app covering the whole spectrum of tasks — simple chats, agentic work, coding, remote sessions, CLI. Juggling multiple harnesses, getting used to their quirks, keeping them updated and properly configured is a pain in the ass no matter how much you can offload to the AI. So I decided to invent my own bicycle that would unify anything and everything.


## Features

- native macOS app: Swift backend, fully native chat rendering (Markdown, tables, code blocks with syntax highlighting) built on AppKit and TextKit, fast on huge chats, low resource usage
- BYOK support: OpenAI, Anthropic, DeepSeek and OpenRouter, plus any OpenAI-compatible endpoint (Ollama, LM Studio, vLLM, etc) as a custom provider — add a key once, the model list and each model's capabilities are loaded for you and picked per chat from a searchable list; several named keys per provider, switchable from the Provider menu and managed in Provider → Manage Keys…
- roles: clearly defined templates bundling a prompt, tools, and a working directory — several bundled, easy to create your own
- agentic toolset: built-in filesystem/code/shell/utils/web tool groups with per-tool approval and optional directory isolation; file editing uses the [oh-my-pi](https://github.com/can1357/oh-my-pi) hashline patch format for optimistic-concurrency edits
- integrated web access: web search and page extraction via Exa, Linkup, or Tavily (unified interface, your choice of provider, set up with a short wizard in Preferences > Web Search that verifies your API key), plus raw URL fetching
- MCP: stdio and streamable HTTP servers with tool filtering, name prefixing, and run policies
- remote work: seamless SSH working directories for agentic sessions on remote machines
- CLI: one-shot and interactive modes, piping, unlimited concurrency — run ten chats in the CLI, ten more in the GUI, continue any of them anywhere
- attachments: attach images, plain text, and documents (docx/doc/odt/rtf/pdf) to any chat on any model — images on non-vision models get a local text fallback
- clean configuration/data structure in a single directory (`~/iCanHazAI`)
- bundled Configurator role that edits the configuration for you
- in-chat search (⌘F): browser-style find over user and assistant message text with match count, next/previous (⌘G / ⇧⌘G) and highlighting
- chat list modes: browse all chats, filter by role, or filter by working directory — the sidebar adapts and new chats inherit the active filter


## Roadmap

- Role creation wizard
- Prompt creation wizard
- Notifications
- App update system
- Memory system
- Skills support
- Global hotkey trigger / quick access
- Chat trees / response regeneration


## Quick Start

1. Grab the latest release from [GitHub Releases](https://github.com/deseven/icanhazai/releases/latest). If you want bleeding-edge features and the most recent changes, a [development build](https://d7.wtf/s/ichai-dev.zip) is also available — obviously, it could be unstable.
2. Move the app to `/Applications`.
3. If you plan to use the CLI, add `alias ichai='/Applications/iCanHazAI.app/Contents/MacOS/iCanHazAI'` to your favourite shell.
4. Run the app and follow the onboarding process.


## Usage Notes

- **CLI**: `ichai "your message"` sends a one-shot message, `command | ichai "..."` pipes input in, `ichai -i` starts an interactive session. `-m provider:model-id` picks the model of a new chat (default: the role's preferred model, else the default model from Preferences). Run `ichai -h` for the full list of features. The app starts itself (without a window) when needed.
- **Tool approvals**: when a model calls a tool, approve it once (⌘Y) or pick "Allow for this chat" (⌥⌘Y), or deny it (⌘N) with an optional reason; roles can also pre-approve tools via `auto_allow`. The state of tool approval can also be controlled in the Chat Info sidebar to the right.
- **Messages while streaming**: you can keep writing while the model works. Return queues the message (shown above the input); queued messages go out together as a single user message once the model finishes its current step — along with its tool results, if it made tool calls. Hold ⌥ to send immediately instead: this stops the current response and sends your message plus anything queued (⌥Return works too). The queue strip has buttons to send everything now or discard it. With nothing typed, the stop button stays a stop button (hold ⌥ for "stop after current step", ⌘B / ⌥⌘B). A hard stop or an error leaves the queue in place instead of sending it.
- **Custom providers**: **Provider → New Provider… → Custom Provider (OpenAI-compatible)** connects any endpoint that speaks the OpenAI API. Give it a name (up to 30 characters, unique, no colon; `OpenAI`, `Anthropic`, `DeepSeek` and `OpenRouter` are taken), the endpoint, an optional API key and a color for its label. The endpoint is used exactly as written — `/models` and `/chat/completions` are appended to it, so include `/v1` yourself if the provider needs it (`http://localhost:11434/v1` for Ollama). The provider is accepted as soon as its `/models` route answers, and an empty list is taken at its word (no models, no error; other providers treat an empty list as a glitch and keep their cache). Each listing leaves one line in the app log (`CustomProviderAdapter`: the URL, how many models, how many were hidden or matched in LiteLLM), and failed refreshes are logged too. Models are listed as `Name:model-id`; each one's capabilities are looked up by its full model name in the [LiteLLM](https://github.com/BerriAI/litellm) definitions (the same ones used for OpenAI), and a model that isn't there gets 128k context, no reasoning and no image input (models LiteLLM knows to be embedding, speech or image models are left out). Reasoning is requested the OpenAI way (`reasoning_effort`). Without an API key no `Authorization` header is sent. You can add as many custom providers as you like; in the model picker narrow the list to one by its name (`ollama.`, `ollama:`). A custom provider is saved in `config.toml` as a `[[custom_providers]]` entry (`name`, `endpoint`, `color`, and `key` — the id of its active API key); it exists as long as it has a key, so deleting its last key removes it.
- **Provider keys**: a provider can have several API keys (say, personal and work). **Provider → New Provider…** only adds providers that aren't added yet (the others are grayed out) — more keys for an added provider go through **Provider → Manage Keys… → Add Key…**, where you give the key a name (up to 30 characters) and choose whether to start using it right away. Every provider gets its own entry in the **Provider** menu with its model count and a checkable `Use '…' Key` item per key; the checked key is used for new requests, while requests already running keep the key they started with. Switching the key re-fetches that provider's models, as another key may offer a different set. The choice is saved under `[providers]` in `config.toml` (as the key's id); if that key is gone at launch the provider's next key takes over, and a provider left without keys is disabled. **Provider → Manage Keys…** lists every key by its first and last 4 characters: rename one (only its name — the key itself can't be changed), delete one (after a confirmation), or add another to a provider (the wizard opens on its key step). Deleting the active key makes the provider's next key active and re-fetches its models. Deleting a provider's last key disables the provider and drops its models, and a default or utility model that belonged to it is reset; with no key left at all the app asks you to add a provider again.
- **Model picker**: the default model from Preferences is always pinned to the top (unless your search filters it out) and highlighted, so just pressing ↵ right after opening picks it. Type a provider prefix to narrow the list to one provider — `or.`, `oa.`, `an.`, `ds.` (OpenRouter, OpenAI, Anthropic, DeepSeek), or the full name (`openrouter.`, `anthropic:`, or a custom provider's name). The prefix only filters; the rest is a case-insensitive search, so `an.sonnet` finds Sonnet among Anthropic models. The whole OpenRouter text-model catalog (including `~vendor/model-latest` aliases) is cached and refreshed every 24 hours.
- **Search**: the pickers and the chat list filter are case-insensitive. Every word you type must appear in the item, in any order (`sonnet claude` finds `claude-sonnet-5.5`), with whole-name, start-of-name and start-of-word matches listed first. If nothing matches that way, letters typed in order are accepted instead (`dpl` finds "Deploy scripts"). In the directory picker, the last path component filters subdirectories by plain case-insensitive substring (names starting with it first).
- **Reasoning**: models that can reason get a reasoning control in the chat toolbar showing the current level; click it to pick another one (`Off` appears when the model can switch reasoning off). New chats use the default level the provider reports for the model, or the middle of the model's levels when it doesn't report one (e.g. Medium for low/medium/high, High for low through max) — reasoning is on whenever the model allows it. The choice is saved with the chat and survives a model switch only if the new model offers exactly the same level; otherwise it goes back to the default. The utility model always runs with that same default level, regardless of any chat's setting; when the model has no reasoning control, the provider's own default applies.
- **SSH**: any working directory can be remote — use the scp form `host:/absolute/path` (or `user@host:/path`; a bare `host:` means the remote home) as a role's `working_directory` or type it into the per-chat directory picker, which will browse the remote for you. Auth must be pre-configured so `ssh host` works without prompts (keys, `~/.ssh/config`) — interactive auth is not supported.


## Data Directory & Entities

On first launch, iCanHazAI creates its data directory at `~/iCanHazAI`:

```
~/iCanHazAI/
├── MCPs/            # MCP servers (*.toml)
├── Prompts/         # system prompts (*.md)
├── Roles/           # roles (*.toml)
├── Chats/           # chats (*.json) and their attachments
├── .cache/          # chat metadata and model list caches (safe to delete)
├── .storage/        # encrypted API keys (provider keys and the web search token)
├── config.toml      # app settings
├── app.log          # debug log
├── last_request.log # full dump of the most recent LLM request (app debug only)
└── app.sock         # CLI control socket
```

Everything lives directly in your home folder, most of it is in plain text, so you can inspect it with any editor.


## Building

```bash
./build.sh
```

This builds the app and launches it. See `build.sh` for additional build modes (`dev-release`, `release`, `clean`).

Run `./build.sh test` for tests.


## Third-Party Notices

Syntax highlighting uses [tree-sitter](https://github.com/tree-sitter/tree-sitter) with the grammars of the `tree-sitter` and `tree-sitter-grammars` GitHub organizations plus [tree-sitter-swift](https://github.com/alex-pinkus/tree-sitter-swift). The Python, JavaScript, CSS, Lua and YAML external scanners are vendored in `shared/TreeSitterScanners` (each with its license) because those packages' manifests fail to include them. The code colors are from [GitHub's Primer theme](https://github.com/primer/github-vscode-theme) (MIT).


## Help & Support

- [File an issue](https://github.com/deseven/icanhazai/issues/new) for bugs, suggestions, or questions
- Reddit: https://www.reddit.com/r/iCanHazApps
- Telegram: https://t.me/icanhazapps


## Contributions

Contributions are welcome — feel free to open a pull request. AI code is welcome, AI slop isn't. Expect to receive a thorough review.
