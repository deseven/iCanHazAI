"""Model listings in each provider's documented shape (see dev-docs/), plus a LiteLLM excerpt."""

import copy
from typing import Optional

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


def _ollama_model(model_id: str) -> dict:
    return {"id": model_id, "object": "model", "created": 1727912233, "owned_by": "library"}


OLLAMA_MODELS = [_ollama_model("llama3.2:latest"), _ollama_model("qwen3-vl:8b"), _ollama_model("gpt-oss:20b")]

LLAMA_CPP_MODELS = [
    {
        "id": "qwen3-8b", "object": "model", "created": 1735142223, "owned_by": "llamacpp",
        "architecture": {"input_modalities": ["text"], "output_modalities": ["text"]},
        "meta": {"vocab_type": 2, "n_vocab": 151936, "n_ctx_train": 40960, "n_embd": 4096,
                 "n_params": 8190735360, "size": 5027783488},
    }
]

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
}


def models_for(channel: str, config: dict) -> list:
    override = config.get("models")
    return copy.deepcopy(override if override is not None else DEFAULT_MODELS[channel])


def model_ids(channel: str, config: dict) -> set:
    return {m["id"] for m in models_for(channel, config)}


def listing(channel: str, config: dict, query: dict) -> dict:
    """The documented /models response for a provider, honouring the pagination its API supports."""
    models = models_for(channel, config)
    page_size = config.get("page_size")

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
