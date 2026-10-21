"""Model listings in each provider's documented shape (see dev-docs/), plus a LiteLLM excerpt."""

import copy
from typing import Optional

from multidict import MultiMapping

DEEPSEEK_MODELS = [
    {
        "id": "deepseek-flash", "object": "model", "owned_by": "deepseek", "name": "DeepSeek-V4.1-Flash",
        "context_window": 1048576, "max_output_tokens": 393216,
        "input_modalities": ["text", "image"], "output_modalities": ["text"],
        "effort": {"supported_levels": ["low", "high", "max"], "default_level": "high"},
        "api_capabilities": {"anthropic_messages": {"system_prompt_update": "in-history"}},
    },
    {
        "id": "deepseek-v4-pro", "object": "model", "owned_by": "deepseek", "name": "DeepSeek-V4-Pro",
        "context_window": 1048576, "max_output_tokens": 393216,
        "input_modalities": ["text"], "output_modalities": ["text"],
        "effort": {"supported_levels": ["low", "high", "max"], "default_level": "high"},
        "api_capabilities": {"anthropic_messages": {"system_prompt_update": "leading-only"}},
    },
]


def _openai_model(model_id: str, owner: str = "openai", shutdown: Optional[str] = None) -> dict:
    return {"id": model_id, "object": "model", "created": 1686935002, "owned_by": owner, "shutdown_date": shutdown}


# The real list is mostly noise (embeddings, audio, snapshots, retired models); the app filters it
# using the LiteLLM excerpt below. Visible after filtering: gpt-4o, gpt-4o-mini, gpt-5.
OPENAI_MODELS = [
    _openai_model("gpt-5"),
    _openai_model("gpt-5-2025-08-07"),
    _openai_model("gpt-4o"),
    _openai_model("gpt-4o-mini"),
    _openai_model("gpt-5-codex"),
    _openai_model("gpt-4o-audio-preview"),
    _openai_model("text-embedding-3-small"),
    _openai_model("whisper-1", owner="openai-internal"),
    _openai_model("gpt-3.5-turbo-0301", shutdown="2024-09-13"),
]


def _capability(supported: bool, **nested) -> dict:
    return {"supported": supported, **nested}


def _anthropic_model(model_id, name, created, max_input, max_tokens, *, image=True, efforts=(), types=None,
                     lifecycle="active") -> dict:
    thinking: dict = {"supported": bool(types)}
    if types is not None:
        thinking["types"] = {t: _capability(t in types) for t in ("adaptive", "enabled", "disabled")}
        thinking["enabled"] = _capability("enabled" in types)
    return {
        "id": model_id, "type": "model", "display_name": name, "created_at": created, "lifecycle": lifecycle,
        "deprecated_at": None, "retires_at": None, "line": None,
        "max_input_tokens": max_input, "max_tokens": max_tokens, "allowed_fallback_models": [],
        "capabilities": {
            "batch": _capability(True), "citations": _capability(True), "code_execution": _capability(True),
            "image_input": _capability(image),
            "effort": {"supported": bool(efforts), **{e: _capability(True) for e in efforts}},
            "thinking": thinking,
        },
    }


# Newest first, as the real API returns them.
ANTHROPIC_MODELS = [
    _anthropic_model("claude-opus-5-5", "Claude Opus 5.5", "2026-01-15T00:00:00Z", 200000, 64000,
                     efforts=("low", "medium", "high", "max"), types=("adaptive", "enabled", "disabled")),
    _anthropic_model("claude-sonnet-5-5", "Claude Sonnet 5.5", "2026-01-10T00:00:00Z", 200000, 64000,
                     efforts=("low", "medium", "high"), types=("adaptive", "enabled", "disabled")),
    _anthropic_model("claude-haiku-5-5", "Claude Haiku 5.5", "2026-01-05T00:00:00Z", 200000, 16000,
                     types=("enabled", "disabled")),
    _anthropic_model("claude-text-only", "Claude Text Only", "2025-06-01T00:00:00Z", 100000, 4096, image=False),
    _anthropic_model("claude-retired-1", "Claude Retired", "2024-01-01T00:00:00Z", 100000, 4096,
                     lifecycle="retired"),
]


def _openrouter_model(model_id, name, context, *, images=False, max_completion=None, efforts=None,
                      default_effort=None, mandatory=False, params=("tools", "temperature")) -> dict:
    model = {
        "id": model_id, "canonical_slug": model_id, "name": name, "created": 1767225600,
        "context_length": context,
        "architecture": {
            "input_modalities": ["text", "image"] if images else ["text"], "output_modalities": ["text"],
            "modality": "text+image->text" if images else "text->text", "tokenizer": "Other",
            "instruct_type": None,
        },
        "pricing": {"prompt": "0.000001", "completion": "0.000002", "image": "0", "request": "0"},
        "top_provider": {"context_length": context, "max_completion_tokens": max_completion, "is_moderated": False},
        "per_request_limits": None,
        "supported_parameters": list(params) + (["reasoning"] if efforts else []),
        "default_parameters": None, "supported_voices": None, "expiration_date": None, "knowledge_cutoff": None,
        "links": {"details": f"/api/v1/models/{model_id}/endpoints"},
    }
    if efforts:
        model["reasoning"] = {"supported_efforts": list(efforts), "default_effort": default_effort,
                              "mandatory": mandatory}
    return model


OPENROUTER_MODELS = [
    _openrouter_model("anthropic/claude-sonnet-5-5", "Anthropic: Claude Sonnet 5.5", 200000, images=True,
                      max_completion=64000, efforts=("low", "medium", "high"), default_effort="medium"),
    _openrouter_model("openai/gpt-5", "OpenAI: GPT-5", 400000, images=True, max_completion=128000,
                      efforts=("minimal", "low", "medium", "high"), default_effort="medium", mandatory=True),
    _openrouter_model("deepseek/deepseek-flash", "DeepSeek: Flash", 1048576, max_completion=393216,
                      efforts=("low", "high", "max"), default_effort="high"),
    _openrouter_model("meta-llama/llama-3.3-70b-instruct:free", "Meta: Llama 3.3 70B Instruct (free)", 131072),
    _openrouter_model("foo/bar", "Foo: Bar", 32000, max_completion=8192),
]


def _ollama_model(name: str, *, capabilities, arch: str, context_train: int, thinking=None, parameters: str = "",
                  parameter_size: str = "8.0B") -> dict:
    """One Ollama model in the shape of `GET /api/tags`, plus a private `show` entry that `POST /api/show` serves.
    The OpenAI layer's `/v1/models` is derived from `name`."""
    details = {"format": "gguf", "family": arch, "families": [arch], "parameter_size": parameter_size,
               "quantization_level": "Q4_K_M"}
    show = {
        "capabilities": list(capabilities), "parameters": parameters, "license": "Mock license",
        "modified_at": "2026-10-01T12:00:00Z", "details": {"parent_model": "", **details},
        "model_info": {"general.architecture": arch, f"{arch}.context_length": context_train,
                       f"{arch}.embedding_length": 4096},
    }
    if thinking is not None:
        show["thinking"] = thinking
    return {"name": name, "model": name, "modified_at": "2026-10-01T12:00:00Z", "size": 4_920_000_000,
            "digest": "c6eb396dbd5992bbe3f5cdb947e8bbc0ee413d7c17e2beaae69f5d569cf982eb", "details": details,
            "show": show}


# Together they cover every way the app can learn a model's context: a Modelfile `num_ctx` (qwen3-vl),
# a loaded model reported by /api/ps (gpt-oss, see OLLAMA_LOADED) and neither (llama3.2).
OLLAMA_MODELS = [
    _ollama_model("llama3.2:latest", capabilities=("completion", "tools"), arch="llama", context_train=131072,
                  parameter_size="3.2B"),
    _ollama_model("qwen3-vl:8b", capabilities=("completion", "vision", "tools", "thinking"), arch="qwen3vl",
                  context_train=262144, thinking={"values": [False, True], "default": True},
                  parameters="temperature 0.7\nnum_ctx 8192"),
    _ollama_model("gpt-oss:20b", capabilities=("completion", "tools", "thinking"), arch="gptoss",
                  context_train=131072, thinking={"values": ["low", "medium", "high"], "default": "medium"},
                  parameter_size="20.9B"),
    # Installed, but not a chat model.
    _ollama_model("nomic-embed-text:latest", capabilities=("embedding",), arch="nomic-bert", context_train=2048,
                  parameter_size="137M"),
]

# `GET /api/ps`: what is loaded right now and the context it runs with (override with the `loaded` config).
OLLAMA_LOADED = [{"name": "gpt-oss:20b", "context_length": 32768}]


def _llama_cpp_model(model_id: str, *, n_ctx: int, n_ctx_train: int, vision: bool = False) -> dict:
    return {
        "id": model_id, "object": "model", "created": 1735142223, "owned_by": "llamacpp",
        "architecture": {"input_modalities": ["text", "image"] if vision else ["text"],
                         "output_modalities": ["text"]},
        "meta": {"vocab_type": 2, "n_vocab": 151936, "n_ctx": n_ctx, "n_ctx_train": n_ctx_train, "n_embd": 4096,
                 "n_params": 8190735360, "size": 5027783488},
    }


LLAMA_CPP_MODELS = [_llama_cpp_model("qwen3-8b", n_ctx=32768, n_ctx_train=40960)]

# What a router lists: no `meta` unless the model is loaded, and a `status` on each entry.
LLAMA_CPP_ROUTER_MODELS = [
    {**_llama_cpp_model("qwen3-8b", n_ctx=8192, n_ctx_train=40960), "status": {"value": "loaded", "args": []}},
    {
        "id": "gemma-3-4b-it", "object": "model", "created": 1735142223, "owned_by": "llamacpp",
        "architecture": {"input_modalities": ["text", "image"], "output_modalities": ["text"]},
        "status": {"value": "unloaded"},
    },
]

LLAMA_CPP_CHAT_TEMPLATE = "{%- if enable_thinking is defined and enable_thinking %}<think>{%- endif %}{{ messages }}"

LLAMA_CPP_TEMPLATE_CAPS = {
    "supports_tools": True, "supports_tool_calls": True, "supports_parallel_tool_calls": True,
    "supports_system_role": True, "supports_preserve_reasoning": False, "supports_reasoning_effort": False,
    "supports_string_content": True, "supports_typed_content": False, "supports_object_arguments": True,
}

DEFAULT_MODELS = {
    "deepseek": DEEPSEEK_MODELS,
    "openai": OPENAI_MODELS,
    "anthropic": ANTHROPIC_MODELS,
    "openrouter": OPENROUTER_MODELS,
    "ollama": OLLAMA_MODELS,
    "llama-cpp": LLAMA_CPP_MODELS,
}

# What the app reads from LiteLLM: OpenAI entries decide which ids are chat models; custom providers look
# their model names up here for capabilities (anything unknown gets safe defaults).
LITELLM = {
    "sample_spec": {"litellm_provider": "one of https://docs.litellm.ai/docs/providers", "mode": "one of"},
    "gpt-5": {"litellm_provider": "openai", "mode": "chat",
              "supported_endpoints": ["/v1/chat/completions", "/v1/responses"], "supports_vision": True,
              "max_input_tokens": 272000, "max_output_tokens": 128000, "supports_reasoning": True,
              "supports_minimal_reasoning_effort": True},
    "gpt-5-2025-08-07": {"litellm_provider": "openai", "mode": "chat",
                         "supported_endpoints": ["/v1/chat/completions"], "max_input_tokens": 272000,
                         "supports_reasoning": True},
    "gpt-4o": {"litellm_provider": "openai", "mode": "chat", "supports_vision": True,
               "max_input_tokens": 128000, "max_output_tokens": 16384},
    "gpt-4o-mini": {"litellm_provider": "openai", "mode": "chat", "supports_vision": True,
                    "max_input_tokens": 128000, "max_output_tokens": 16384},
    "gpt-5-codex": {"litellm_provider": "openai", "mode": "responses",
                    "supported_endpoints": ["/v1/responses"], "max_input_tokens": 400000},
    "gpt-4o-audio-preview": {"litellm_provider": "openai", "mode": "chat", "max_input_tokens": 128000},
    "gpt-oss:20b": {"litellm_provider": "ollama", "mode": "chat", "max_input_tokens": 131072,
                    "supports_reasoning": True},
    "qwen3-vl:8b": {"litellm_provider": "ollama", "mode": "chat", "supports_vision": True,
                    "max_input_tokens": 262144},
    "nomic-embed-text:latest": {"litellm_provider": "ollama", "mode": "embedding", "max_input_tokens": 8192},
}


def models_for(channel: str, config: dict) -> list:
    override = config.get("models")
    if override is None and channel == "llama-cpp" and config.get("router"):
        return copy.deepcopy(LLAMA_CPP_ROUTER_MODELS)
    return copy.deepcopy(override if override is not None else DEFAULT_MODELS[channel])


def model_id(model: dict) -> str:
    """Ollama's native listing calls the id `name`."""
    return model.get("id") or model.get("name") or ""


def model_ids(channel: str, config: dict) -> set:
    return {model_id(m) for m in models_for(channel, config)}


def ollama_tags(config: dict) -> dict:
    """`GET /api/tags`: the models without the private `show` entry."""
    return {"models": [{k: v for k, v in m.items() if k != "show"} for m in models_for("ollama", config)]}


def ollama_show(config: dict, name: str) -> Optional[dict]:
    """`POST /api/show` for a model, or None when it doesn't exist."""
    model = next((m for m in models_for("ollama", config) if model_id(m) == name), None)
    return copy.deepcopy(model["show"]) if model is not None else None


def ollama_ps(config: dict) -> dict:
    """`GET /api/ps`: the loaded models, each with the context it runs with."""
    loaded = config.get("loaded")
    entries = OLLAMA_LOADED if loaded is None else loaded
    return {"models": [
        {"name": e["name"], "model": e["name"], "size": 6_591_830_464, "digest": "c6eb396d",
         "details": {"parent_model": "", "format": "gguf", "family": "mock", "families": ["mock"],
                     "parameter_size": "8.0B", "quantization_level": "Q4_K_M"},
         "expires_at": "2099-01-01T00:00:00Z", "size_vram": 5_333_539_264, "context_length": e["context_length"]}
        for e in entries
    ]}


def llama_cpp_props(config: dict, model: Optional[str] = None) -> dict:
    """`GET /props`. `config["props"]` is merged over the defaults; with `?model=` (router mode) so is
    `config["props_by_model"][model]`, and `n_ctx` follows that model's loaded `meta`."""
    models = models_for("llama-cpp", config)
    first = models[0] if models else {}
    chosen = next((m for m in models if model_id(m) == model), None) if model else first
    meta = (chosen or {}).get("meta") or {}
    architecture = (chosen or {}).get("architecture") or {}
    props = {
        "default_generation_settings": {
            "params": {"temperature": 0.8, "top_k": 40, "top_p": 0.95},
            "n_ctx": meta.get("n_ctx", 4096),
        },
        "total_slots": 1,
        "model_alias": model_id(chosen or {}),
        "model_path": f"../models/{model_id(chosen or {})}.gguf",
        "modalities": {"vision": "image" in architecture.get("input_modalities", []), "video": False,
                       "audio": "audio" in architecture.get("input_modalities", [])},
        "chat_template": LLAMA_CPP_CHAT_TEMPLATE,
        "chat_template_caps": dict(LLAMA_CPP_TEMPLATE_CAPS),
        "bos_token": "<s>", "eos_token": "</s>", "build_info": "b6000-mock", "is_sleeping": False,
        "endpoint_slots": True, "endpoint_props": False, "endpoint_metrics": False,
    }
    for override in (config.get("props"), (config.get("props_by_model") or {}).get(model or "")):
        if override:
            props = _merge(props, override)
    return props


def _merge(base: dict, override: dict) -> dict:
    merged = dict(base)
    for key, value in override.items():
        merged[key] = _merge(merged[key], value) if isinstance(value, dict) and isinstance(merged.get(key), dict) \
            else value
    return merged


def listing(channel: str, config: dict, query: MultiMapping[str]) -> dict:
    """The documented /models response for a provider, honouring the pagination its API supports."""
    models = models_for(channel, config)
    page_size = config.get("page_size")

    if channel == "ollama":
        # The OpenAI layer: the same models, as `id`/`created`/`owned_by` and nothing more.
        return {"object": "list", "data": [
            {"id": model_id(m), "object": "model", "created": 1727912233, "owned_by": "library"} for m in models]}

    if channel == "anthropic":
        # Retired models only appear when asked for explicitly.
        if "retired" not in query.getall("lifecycle", []):
            models = [m for m in models if m.get("lifecycle") != "retired"]
        limit = max(1, min(int(query.get("limit", 20)), page_size or 1000))
        start = 0
        if after := query.get("after_id"):
            ids = [m["id"] for m in models]
            start = ids.index(after) + 1 if after in ids else len(ids)
        page = models[start:start + limit]
        return {
            "data": page,
            "first_id": page[0]["id"] if page else None,
            "last_id": page[-1]["id"] if page else None,
            "has_more": start + limit < len(models),
        }

    if channel == "openrouter":
        if q := query.get("q"):
            needle = q.lower()
            models = [m for m in models if needle in m["id"].lower() or needle in m["name"].lower()]
        total = len(models)
        offset = int(query.get("offset", 0))
        limit = min(int(query.get("limit", 500)), 1000, page_size or 1000)
        return {"total_count": total, "data": models[offset:offset + limit]}

    return {"object": "list", "data": models}
