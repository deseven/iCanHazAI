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
- extensive BYOK support: Anthropic, OpenAI, or any OpenAI-compatible API (OpenRouter, Together, DeepSeek, local servers like Ollama/LM Studio, and countless others)
- roles: clearly defined templates bundling a prompt, a connection, tools, and a working directory — several bundled, easy to create your own
- agentic toolset: built-in filesystem/code/shell/utils/web tool groups with per-tool approval and optional directory isolation; file editing uses the [oh-my-pi](https://github.com/can1357/oh-my-pi) hashline patch format for optimistic-concurrency edits
- integrated web access: web search and page extraction via Exa, Linkup, or Tavily (unified interface, your choice of provider), plus raw URL fetching
- MCP: stdio and streamable HTTP servers with tool filtering, name prefixing, and run policies
- remote work: seamless SSH working directories for agentic sessions on remote machines
- CLI: one-shot and interactive modes, piping, unlimited concurrency — run ten chats in the CLI, ten more in the GUI, continue any of them anywhere
- attachments: attach images, plain text, and documents (docx/doc/odt/rtf/pdf) to any chat on any connection — images on non-vision connections get a local text fallback
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
4. Run the app and create your first connection — the wizard will guide you. Then check Preferences to tune things how you like, or just ask the Configurator role.


## Usage Notes

- **CLI**: `ichai "your message"` sends a one-shot message, `command | ichai "..."` pipes input in, `ichai -i` starts an interactive session. Run `ichai -h` for the full list of features. The app starts itself (without a window) when needed.
- **Tool approvals**: when a model calls a tool, approve it once (⌘Y) or pick "Allow for this chat" (⌥⌘Y), or deny it (⌘N) with an optional reason; roles can also pre-approve tools via `auto_allow`. The state of tool approval can also be controlled in the Chat Info sidebar to the right.
- **Messages while streaming**: you can keep writing while the model works. Return queues the message (shown above the input); queued messages go out together as a single user message once the model finishes its current step — along with its tool results, if it made tool calls. Hold ⌥ to send immediately instead: this stops the current response and sends your message plus anything queued (⌥Return works too). The queue strip has buttons to send everything now or discard it. With nothing typed, the stop button stays a stop button (hold ⌥ for "stop after current step", ⌘B / ⌥⌘B). A hard stop or an error leaves the queue in place instead of sending it.
- **SSH**: any working directory can be remote — use the scp form `host:/absolute/path` (or `user@host:/path`; a bare `host:` means the remote home) as a role's `working_directory` or type it into the per-chat directory picker, which will browse the remote for you. Auth must be pre-configured so `ssh host` works without prompts (keys, `~/.ssh/config`) — interactive auth is not supported.


## Data Directory & Entities

On first launch, iCanHazAI creates its data directory at `~/iCanHazAI`:

```
~/iCanHazAI/
├── Connections/     # provider connections (*.jsonc)
│   ├── openai/
│   └── anthropic/
├── MCPs/            # MCP servers (*.toml)
├── Prompts/         # system prompts (*.md)
├── Roles/           # roles (*.toml)
├── Chats/           # chats (*.json) and their attachments
├── config.toml      # app settings
├── app.log          # debug log
├── last_request.log # full dump of the most recent LLM request (app debug only)
└── app.sock         # CLI control socket
```

Everything lives directly in your home folder as plain text, so you can inspect it with any editor.

### Connection

A `{name}.jsonc` file in `Connections/openai/` or `Connections/anthropic/`. The folder determines the API flavor (OpenAI-compatible or Anthropic); together with the name it forms the connection id (`openai/gpt-4o`, `anthropic/claude`, ...) that roles and the app config refer to. The file defines the base URL, API key, model, and any extra request parameters — JSONC means comments and trailing commas are welcome. The first-run wizard creates one for you; afterwards use "Connection → New Connection…" or the Configurator role.

### MCP

A `{name}.toml` file in `MCPs/` describing how to reach an MCP server: either stdio (a command executed via your login shell) or http (a streamable HTTP endpoint with an optional bearer token). Supports an optional tool allowlist, a name prefix for its tools, and a run policy — always-on servers start with the app, on-demand ones spin up on first use and shut down when idle.

### Prompt

A `{name}.md` file in `Prompts/` — the entire file content is the system prompt. Prompts support `{variable}` placeholders substituted at request time: `{date}`, `{user}`, `{current_directory}`, `{output_rendering}` (markup capabilities of the chat's surface), and `{load_first_available:AGENTS.md,CLAUDE.md,...}` for pulling in project instructions.

### Role

A `{name}.toml` file in `Roles/` — a template for new chats combining a prompt, a connection, a working directory, and tools. Tools come from the built-in groups (utils, filesystem, code, shell, web) and/or configured MCP servers, each with optional allowlists and auto-approve rules. The working directory can be pre-set, picked once per chat, or a remote SSH location (`host:/path`), and filesystem/code tools can be isolated to it. A chat's role and working directory are fixed at creation. An optional `[features]` table gates per-role UI capabilities.

### Chat

A `YYYY-MM-DD HH-mm-ss.json` file in `Chats/`, with a numeric suffix like ` (2)` if needed, and attachments in a same-named directory next to it. Attached documents are extracted to text at send time and embedded in the chat JSON; the originals are kept on disk as a user-facing backup. Chats created via the CLI are regular chats — visible and continuable in the GUI, and vice versa.


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
