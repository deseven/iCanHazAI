"""Per-provider behaviour of the mock. Everything provider-specific lives here as data."""

from dataclasses import dataclass
from typing import Optional


@dataclass(frozen=True)
class Provider:
    name: str
    wire: str  # "openai" | "anthropic"
    base_path: str  # path below /<name>, mirroring the real API's base URL
    auth: str  # "bearer" | "x-api-key" | "none"
    models_need_auth: bool
    thinking_field: Optional[str]  # delta field carrying reasoning text; None = not streamed
    usage_style: str  # "final" | "separate" | "timings"
    tool_style: str  # "streamed" | "whole"
    error_style: str  # "openai" | "openrouter" | "ollama" | "llamacpp" | "anthropic"
    validates_model: bool = True

    @property
    def prefix(self) -> str:
        return f"/{self.name}"

    @property
    def chat_path(self) -> str:
        tail = "/messages" if self.wire == "anthropic" else "/chat/completions"
        return f"{self.prefix}{self.base_path}{tail}"

    @property
    def models_path(self) -> str:
        return f"{self.prefix}{self.base_path}/models"


PROVIDERS = {
    p.name: p
    for p in [
        # DeepSeek: usage rides in the final chunk together with finish_reason.
        Provider("deepseek", "openai", "", "bearer", True, "reasoning_content", "final", "streamed", "openai"),
        # OpenAI chat completions never stream reasoning text.
        Provider("openai", "openai", "/v1", "bearer", True, None, "separate", "streamed", "openai"),
        Provider("anthropic", "anthropic", "/v1", "x-api-key", True, None, "final", "streamed", "anthropic"),
        # OpenRouter: /models is public; reasoning arrives as `reasoning`.
        Provider("openrouter", "openai", "/api/v1", "bearer", False, "reasoning", "separate", "streamed", "openrouter"),
        # Ollama: no auth locally; tool calls arrive whole in a single delta.
        Provider("ollama", "openai", "/v1", "none", False, "reasoning", "separate", "whole", "ollama"),
        # llama.cpp serves one model and ignores the requested name; usage chunk carries `timings`.
        Provider(
            "llama-cpp", "openai", "/v1", "none", False, "reasoning_content", "timings", "streamed", "llamacpp",
            validates_model=False,
        ),
    ]
}

LITELLM_PATH = "/litellm/model_prices_and_context_window.json"

# Error type per HTTP status, shared by the OpenAI-style and Anthropic error bodies.
ERROR_TYPES = {
    400: "invalid_request_error",
    401: "authentication_error",
    402: "invalid_request_error",
    403: "permission_error",
    404: "not_found_error",
    413: "request_too_large",
    422: "invalid_request_error",
    429: "rate_limit_error",
    500: "api_error",
    502: "api_error",
    503: "api_error",
    529: "overloaded_error",
}


def error_body(provider: Provider, status: int, message: str, error_type: Optional[str] = None) -> dict:
    etype = error_type or ERROR_TYPES.get(status, "api_error")
    style = provider.error_style
    if style == "anthropic":
        return {"type": "error", "error": {"type": etype, "message": message}, "request_id": "req_mock"}
    if style == "openrouter":
        return {"error": {"code": status, "message": message}}
    if style == "llamacpp":
        return {"error": {"code": status, "message": message, "type": etype}}
    if style == "ollama":
        return {"error": {"message": message, "type": "api_error", "param": None, "code": None}}
    return {"error": {"message": message, "type": etype, "param": None, "code": None}}
