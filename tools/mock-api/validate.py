"""Strict request validation, written from the rules in dev-docs/.

Each validator returns None for a valid request, or an `Err` that the server turns into the provider's
documented error response. The point is to fail loudly when the app builds a request a real provider
would reject.
"""

import base64
import binascii
import re
from dataclasses import dataclass
from typing import Optional

from catalog import model_ids, models_for
from providers import Provider


@dataclass
class Err:
    status: int
    message: str
    error_type: Optional[str] = None


OPENAI_ROLES = {"system", "user", "assistant", "tool", "developer"}
OPENAI_PART_TYPES = {"text", "image_url", "input_audio", "input_video", "file"}
OPENAI_TOOL_NAME = re.compile(r"^[a-zA-Z0-9_-]{1,64}$")
ANTHROPIC_TOOL_NAME = re.compile(r"^[a-zA-Z0-9_-]{1,128}$")
REASONING_EFFORTS = {"none", "minimal", "low", "medium", "high", "xhigh", "max"}
ANTHROPIC_IMAGE_TYPES = {"image/jpeg", "image/png", "image/gif", "image/webp"}


def check_model(provider: Provider, model, config: dict) -> Optional[Err]:
    if not isinstance(model, str) or not model:
        return Err(400, "Missing required parameter: 'model'.")
    # A single-model llama-server answers whatever name is asked for; a router routes by it.
    if not provider.validates_model and not (provider.name == "llama-cpp" and config.get("router")):
        return None
    known = model_ids(provider.name, config)
    if model in known:
        return None
    if provider.wire == "ollama":
        return Err(404, f"model '{model}' not found")
    if provider.name == "ollama":
        return Err(404, f'model "{model}" not found, try pulling it first')
    if provider.name == "llama-cpp":
        return Err(400, f"model '{model}' not found", "invalid_request_error")
    if provider.name == "openrouter":
        return Err(400, f"{model} is not a valid model ID")
    if provider.name == "anthropic":
        return Err(404, f"model: {model}")
    return Err(404, f"The model `{model}` does not exist or you do not have access to it.")


# ---------------------------------------------------------------------------------------------------------
# OpenAI wire (OpenAI, DeepSeek, OpenRouter, Ollama, llama.cpp)
# ---------------------------------------------------------------------------------------------------------


def validate_openai(provider: Provider, body, config: dict) -> Optional[Err]:
    if not isinstance(body, dict):
        return Err(400, "Invalid request: the body must be a JSON object.")
    if err := check_model(provider, body.get("model"), config):
        return err

    messages = body.get("messages")
    if not isinstance(messages, list) or not messages:
        return Err(400, "Invalid 'messages': expected a non-empty array.")

    if body.get("stream_options") is not None and body.get("stream") is not True:
        return Err(400, "The 'stream_options' parameter is only allowed when 'stream' is enabled.")

    if (effort := body.get("reasoning_effort")) is not None and effort not in REASONING_EFFORTS:
        return Err(400, f"Invalid value for 'reasoning_effort': {effort!r}.")
    if provider.name == "deepseek" and (thinking := body.get("thinking")) is not None:
        if not isinstance(thinking, dict) or thinking.get("type") not in ("enabled", "disabled"):
            return Err(400, "Invalid 'thinking': type must be 'enabled' or 'disabled'.")

    if err := _openai_messages(messages):
        return err
    return _openai_tools(body.get("tools"))


def _openai_messages(messages: list) -> Optional[Err]:
    pending: set = set()  # tool_call ids the next messages must answer
    for i, m in enumerate(messages):
        if not isinstance(m, dict) or m.get("role") not in OPENAI_ROLES:
            return Err(400, f"Invalid value for 'messages[{i}].role'.")
        role = m["role"]

        if pending and role != "tool":
            return Err(
                400,
                "An assistant message with 'tool_calls' must be followed by tool messages responding to each "
                f"'tool_call_id'. The following tool_call_ids did not have response messages: {sorted(pending)[0]}",
            )

        content = m.get("content")
        calls = m.get("tool_calls")
        if role == "assistant" and calls is not None:
            if not isinstance(calls, list) or not calls:
                return Err(400, f"Invalid 'messages[{i}].tool_calls': expected a non-empty array.")
            ids = set()
            for j, call in enumerate(calls):
                where = f"messages[{i}].tool_calls[{j}]"
                if not isinstance(call, dict) or not isinstance(call.get("id"), str) or not call["id"]:
                    return Err(400, f"Missing required parameter: '{where}.id'.")
                if call.get("type") != "function":
                    return Err(400, f"Invalid value for '{where}.type': expected 'function'.")
                function = call.get("function")
                if not isinstance(function, dict) or not isinstance(function.get("name"), str):
                    return Err(400, f"Missing required parameter: '{where}.function.name'.")
                if not isinstance(function.get("arguments"), str):
                    return Err(400, f"Invalid type for '{where}.function.arguments': expected a JSON string.")
                if call["id"] in ids:
                    return Err(400, f"Duplicate tool_call id '{call['id']}' in messages[{i}].")
                ids.add(call["id"])
            pending = ids
            if content is not None and not isinstance(content, (str, list)):
                return Err(400, f"Invalid type for 'messages[{i}].content'.")
            continue

        if role == "tool":
            call_id = m.get("tool_call_id")
            if not isinstance(call_id, str) or not call_id:
                return Err(400, f"Missing required parameter: 'messages[{i}].tool_call_id'.")
            if call_id not in pending:
                return Err(
                    400,
                    f"Invalid parameter: messages with role 'tool' must be a response to a preceding message "
                    f"with 'tool_calls' (tool_call_id '{call_id}').",
                )
            pending.discard(call_id)

        if not isinstance(content, (str, list)):
            return Err(400, f"Invalid type for 'messages[{i}].content': expected a string or an array.")
        if isinstance(content, list):
            for j, part in enumerate(content):
                if err := _openai_part(part, f"messages[{i}].content[{j}]"):
                    return err

    if pending:
        return Err(
            400,
            "An assistant message with 'tool_calls' must be followed by tool messages responding to each "
            f"'tool_call_id'. The following tool_call_ids did not have response messages: {sorted(pending)[0]}",
        )
    return None


def _openai_part(part, where: str) -> Optional[Err]:
    if not isinstance(part, dict) or part.get("type") not in OPENAI_PART_TYPES:
        return Err(400, f"Invalid value for '{where}.type'.")
    if part["type"] == "text" and not isinstance(part.get("text"), str):
        return Err(400, f"Missing required parameter: '{where}.text'.")
    if part["type"] == "image_url":
        image = part.get("image_url")
        # Ollama documents the bare data-URI string form; the OpenAI schema uses {"url": ...}.
        if isinstance(image, str):
            url = image
        elif isinstance(image, dict):
            url = image.get("url")
        else:
            url = None
        if not isinstance(url, str) or not url:
            return Err(400, f"Missing required parameter: '{where}.image_url.url'.")
    return None


def _openai_tools(tools) -> Optional[Err]:
    if tools is None:
        return None
    if not isinstance(tools, list) or not tools:
        return Err(400, "Invalid 'tools': expected a non-empty array.")
    names = set()
    for i, tool in enumerate(tools):
        function = tool.get("function") if isinstance(tool, dict) else None
        if not isinstance(tool, dict) or tool.get("type") != "function" or not isinstance(function, dict):
            return Err(400, f"Invalid value for 'tools[{i}]': expected a function tool.")
        name = function.get("name")
        if not isinstance(name, str) or not OPENAI_TOOL_NAME.match(name):
            return Err(400, f"Invalid 'tools[{i}].function.name': {name!r} must match ^[a-zA-Z0-9_-]{{1,64}}$.")
        if name in names:
            return Err(400, f"Duplicate tool name '{name}'.")
        names.add(name)
        if "parameters" in function and not isinstance(function["parameters"], dict):
            return Err(400, f"Invalid 'tools[{i}].function.parameters': expected an object.")
    return None


# ---------------------------------------------------------------------------------------------------------
# Ollama native wire (/api/chat)
# ---------------------------------------------------------------------------------------------------------

OLLAMA_ROLES = {"system", "user", "assistant", "tool"}


def validate_ollama(provider: Provider, body, config: dict) -> Optional[Err]:
    if not isinstance(body, dict):
        return Err(400, "invalid request: the body must be a JSON object")
    if err := check_model(provider, body.get("model"), config):
        return err

    messages = body.get("messages")
    if not isinstance(messages, list) or not messages:
        return Err(400, "invalid request: 'messages' must be a non-empty array")
    if "stream" in body and not isinstance(body["stream"], bool):
        return Err(400, "invalid request: 'stream' must be a boolean")
    if "options" in body and body["options"] is not None and not isinstance(body["options"], dict):
        return Err(400, "invalid request: 'options' must be an object")
    think = body.get("think")
    if think is not None and not isinstance(think, (bool, str)):
        return Err(400, "invalid request: 'think' must be a boolean or a string")
    # A request never carries OpenAI-style leftovers: they would be silently ignored by the real server.
    for stray in ("stream_options", "max_tokens", "reasoning_effort", "temperature", "top_p"):
        if stray in body:
            return Err(400, f"invalid request: '{stray}' is not an Ollama parameter (use 'options')")

    capabilities = _ollama_capabilities(config, body["model"])
    if think not in (None, False) and "thinking" not in capabilities:
        return Err(400, f'"{body["model"]}" does not support thinking')
    if body.get("tools") and "tools" not in capabilities:
        return Err(400, f'"{body["model"]}" does not support tools')

    if err := _ollama_messages(messages, capabilities, body["model"]):
        return err
    return _ollama_tools(body.get("tools"))


def _ollama_capabilities(config: dict, name: str) -> set:
    for m in models_for("ollama", config):
        if (m.get("name") or m.get("id")) == name:
            return set((m.get("show") or {}).get("capabilities", ["completion", "tools", "thinking", "vision"]))
    return set()


def _ollama_messages(messages: list, capabilities: set, model: str) -> Optional[Err]:
    pending: list = []  # names of the calls the next tool messages must answer, in order
    for i, m in enumerate(messages):
        if not isinstance(m, dict) or str(m.get("role", "")).lower() not in OLLAMA_ROLES:
            return Err(400, f"invalid message role at messages[{i}]")
        role = m["role"].lower()

        if pending and role != "tool":
            return Err(400, f"messages[{i}]: the tool calls of the previous message were not answered "
                            f"(missing a result for '{pending[0]}')")
        if not isinstance(m.get("content", ""), str):
            return Err(400, f"json: cannot unmarshal non-string into Go struct field Message.messages[{i}].content "
                            "of type string")

        calls = m.get("tool_calls")
        if calls is not None:
            if role != "assistant":
                return Err(400, f"messages[{i}]: only an assistant message carries tool_calls")
            if not isinstance(calls, list) or not calls:
                return Err(400, f"messages[{i}].tool_calls must be a non-empty array")
            names = []
            for j, call in enumerate(calls):
                function = call.get("function") if isinstance(call, dict) else None
                if not isinstance(function, dict) or not isinstance(function.get("name"), str) \
                        or not function["name"]:
                    return Err(400, f"messages[{i}].tool_calls[{j}].function.name is required")
                if not isinstance(function.get("arguments"), dict):
                    # What Go's decoder says about a string where an object belongs.
                    return Err(400, "json: cannot unmarshal string into Go struct field "
                                    "ToolCallFunction.messages.tool_calls.function.arguments of type "
                                    "api.ToolCallFunctionArguments")
                names.append(function["name"])
            pending = names
            continue

        if role == "tool":
            name = m.get("tool_name")
            if not isinstance(name, str) or not name:
                return Err(400, f"messages[{i}]: a tool message needs 'tool_name'")
            if not pending:
                return Err(400, f"messages[{i}]: a tool message must answer a preceding assistant tool call")
            if name != pending[0]:
                return Err(400, f"messages[{i}]: expected the result of '{pending[0]}' (results come in call "
                                f"order), got '{name}'")
            pending.pop(0)

        images = m.get("images")
        if images is not None:
            if not isinstance(images, list) or not all(isinstance(x, str) and x for x in images):
                return Err(400, f"messages[{i}].images must be an array of base64 strings")
            for image in images:
                if image.startswith("data:"):
                    return Err(400, f"messages[{i}].images: send bare base64, not a data URL")
                try:
                    base64.b64decode(image, validate=True)
                except (binascii.Error, ValueError):
                    return Err(400, f"messages[{i}].images: invalid base64")
            if images and "vision" not in capabilities:
                return Err(400, f'"{model}" does not support image input')

    if pending:
        return Err(400, f"the tool calls of the last assistant message were not answered "
                        f"(missing a result for '{pending[0]}')")
    return None


def _ollama_tools(tools) -> Optional[Err]:
    if tools is None:
        return None
    if not isinstance(tools, list) or not tools:
        return Err(400, "invalid request: 'tools' must be a non-empty array")
    names = set()
    for i, tool in enumerate(tools):
        function = tool.get("function") if isinstance(tool, dict) else None
        if not isinstance(tool, dict) or tool.get("type") != "function" or not isinstance(function, dict):
            return Err(400, f"tools[{i}] must be a function tool")
        name = function.get("name")
        if not isinstance(name, str) or not name:
            return Err(400, f"tools[{i}].function.name is required")
        if name in names:
            return Err(400, f"duplicate tool name '{name}'")
        names.add(name)
        if not isinstance(function.get("parameters"), dict):
            return Err(400, f"tools[{i}].function.parameters is required and must be an object")
    return None


# ---------------------------------------------------------------------------------------------------------
# Anthropic wire
# ---------------------------------------------------------------------------------------------------------


def validate_anthropic(provider: Provider, body, config: dict) -> Optional[Err]:
    if not isinstance(body, dict):
        return Err(400, "Invalid request: the body must be a JSON object.")
    if err := check_model(provider, body.get("model"), config):
        return err

    max_tokens = body.get("max_tokens")
    if not isinstance(max_tokens, int) or isinstance(max_tokens, bool):
        return Err(400, "max_tokens: Field required")
    if max_tokens < 1:
        return Err(400, "max_tokens: Input should be greater than or equal to 1")
    limit = next((m.get("max_tokens") for m in models_for("anthropic", config) if m["id"] == body["model"]), None)
    if limit and max_tokens > limit:
        return Err(
            400,
            f"max_tokens: {max_tokens} > {limit}, which is the maximum allowed number of output tokens "
            f"for {body['model']}",
        )

    messages = body.get("messages")
    if not isinstance(messages, list) or not messages:
        return Err(400, "messages: Field required")

    system = body.get("system")
    if system is not None and not isinstance(system, (str, list)):
        return Err(400, "system: Input should be a valid string or an array of text blocks")

    if err := _anthropic_thinking(body.get("thinking"), max_tokens):
        return err
    if (effort := (body.get("output_config") or {}).get("effort")) is not None:
        if effort not in ("low", "medium", "high", "xhigh", "max"):
            return Err(400, "output_config.effort: Input should be 'low', 'medium', 'high', 'xhigh' or 'max'")

    if err := _anthropic_messages(messages):
        return err
    return _anthropic_tools(body.get("tools"))


def _anthropic_thinking(thinking, max_tokens: int) -> Optional[Err]:
    if thinking is None:
        return None
    kind = thinking.get("type") if isinstance(thinking, dict) else None
    if kind not in ("adaptive", "enabled", "disabled", "between_tools"):
        return Err(400, "thinking.type: Input should be 'adaptive', 'enabled', 'disabled' or 'between_tools'")
    if kind == "enabled":
        budget = thinking.get("budget_tokens")
        if not isinstance(budget, int) or budget < 1024:
            return Err(400, "thinking.enabled.budget_tokens: Input should be greater than or equal to 1024")
        if budget >= max_tokens:
            return Err(400, "`max_tokens` must be greater than `thinking.budget_tokens`")
    return None


def _anthropic_blocks(content, where: str, *, allow_empty_text: bool = False):
    """Normalizes string content to blocks; returns (blocks, Err)."""
    if isinstance(content, str):
        if not content and not allow_empty_text:
            return None, Err(400, f"{where}: text content blocks must be non-empty")
        return [{"type": "text", "text": content}], None
    if not isinstance(content, list) or not content:
        return None, Err(400, f"{where}: Input should be a valid string or a non-empty array of content blocks")
    for j, block in enumerate(content):
        if not isinstance(block, dict) or not isinstance(block.get("type"), str):
            return None, Err(400, f"{where}.{j}: Input should be a valid content block")
        kind = block["type"]
        if kind == "text":
            if not isinstance(block.get("text"), str):
                return None, Err(400, f"{where}.{j}.text: Field required")
            if not block["text"] and not allow_empty_text:
                return None, Err(400, f"{where}.{j}.text: text content blocks must be non-empty")
        elif kind == "image":
            source = block.get("source")
            if not isinstance(source, dict) or source.get("type") not in ("base64", "url"):
                return None, Err(400, f"{where}.{j}.source: Field required")
            if source["type"] == "base64":
                if source.get("media_type") not in ANTHROPIC_IMAGE_TYPES:
                    return None, Err(400, f"{where}.{j}.source.base64.media_type: unsupported image type")
                if not isinstance(source.get("data"), str) or not source["data"]:
                    return None, Err(400, f"{where}.{j}.source.base64.data: Field required")
        elif kind == "tool_use":
            if not all(isinstance(block.get(k), str) and block[k] for k in ("id", "name")):
                return None, Err(400, f"{where}.{j}: tool_use blocks need `id` and `name`")
            if not isinstance(block.get("input"), dict):
                return None, Err(400, f"{where}.{j}.tool_use.input: Input should be a valid dictionary")
        elif kind == "tool_result":
            if not isinstance(block.get("tool_use_id"), str) or not block["tool_use_id"]:
                return None, Err(400, f"{where}.{j}.tool_result.tool_use_id: Field required")
    return content, None


def _anthropic_messages(messages: list) -> Optional[Err]:
    normalized = []
    for i, m in enumerate(messages):
        if not isinstance(m, dict):
            return Err(400, f"messages.{i}: Input should be an object")
        role = m.get("role")
        if role == "system":
            return Err(
                400,
                f'messages: Unexpected role "system". The Messages API accepts a top-level `system` parameter, '
                f'not "system" as an input message role.',
            )
        if role not in ("user", "assistant"):
            return Err(400, f"messages.{i}.role: Input should be 'user' or 'assistant'")
        last = i == len(messages) - 1
        blocks, err = _anthropic_blocks(m.get("content"), f"messages.{i}.content",
                                        allow_empty_text=last and role == "assistant")
        if err:
            return err
        assert blocks is not None  # `_anthropic_blocks` returns blocks or an error
        # Consecutive turns of the same role are combined by the API.
        if normalized and normalized[-1]["role"] == role:
            normalized[-1]["content"] = normalized[-1]["content"] + blocks
        else:
            normalized.append({"role": role, "content": list(blocks)})

    if normalized[0]["role"] != "user":
        return Err(400, 'messages: first message must use the "user" role')

    pending: set = set()
    for m in normalized:
        blocks = m["content"]
        if m["role"] == "assistant":
            if pending:
                return Err(400, _unanswered(pending))
            pending = {b["id"] for b in blocks if b["type"] == "tool_use"}
            continue
        seen_other = False
        answered = set()
        for b in blocks:
            if b["type"] != "tool_result":
                seen_other = True
                continue
            if seen_other:
                return Err(400, "tool_result blocks must come first in the user message content")
            if b["tool_use_id"] not in pending:
                return Err(
                    400,
                    f"unexpected `tool_use_id` found in `tool_result` blocks: {b['tool_use_id']}. Each "
                    "`tool_result` block must have a corresponding `tool_use` block in the previous message.",
                )
            answered.add(b["tool_use_id"])
        pending -= answered
        if pending:
            return Err(400, _unanswered(pending))
    if pending:
        return Err(400, _unanswered(pending))
    return None


def _unanswered(pending: set) -> str:
    return (
        f"`tool_use` ids were found without `tool_result` blocks immediately after: {', '.join(sorted(pending))}. "
        "Each `tool_use` block must have a corresponding `tool_result` block in the next message."
    )


def _anthropic_tools(tools) -> Optional[Err]:
    if tools is None:
        return None
    if not isinstance(tools, list) or not tools:
        return Err(400, "tools: Input should be a non-empty array")
    names = set()
    for i, tool in enumerate(tools):
        if not isinstance(tool, dict):
            return Err(400, f"tools.{i}: Input should be an object")
        name = tool.get("name")
        if not isinstance(name, str) or not ANTHROPIC_TOOL_NAME.match(name):
            return Err(400, f"tools.{i}.custom.name: String should match pattern '^[a-zA-Z0-9_-]{{1,128}}$'")
        if name in names:
            return Err(400, f"tools: Tool names must be unique. Found duplicate: {name}")
        names.add(name)
        schema = tool.get("input_schema")
        if not isinstance(schema, dict) or schema.get("type") != "object":
            return Err(400, f"tools.{i}.custom.input_schema.type: Field required (must be 'object')")
    return None
