"""Scenario step validation.

Steps (all are JSON objects with a `type`):

  text       {text}                        content delta
  thinking   {text}                        reasoning delta (not available on `openai`)
  tool_call  {name, arguments?, id?, split?}   arguments: object or JSON string; split = number of fragments
  usage      {input?, output?, cached?}    token usage (input = non-cached input tokens); sent at the end
  finish     {reason}                      stop | tool_calls | length (Anthropic: end_turn | tool_use | max_tokens)
  open       {}                            send the response headers (and the stream preamble) now
  gate       {name}                        pause until /__mock/gates/<name>/release
  delay      {ms}                          fixed delay
  keepalive  {}                            SSE comment / ping event (a blank line on Ollama's NDJSON)
  sse_error  {message, error_type?}        provider error inside a 200 stream; ends the stream
  http_error {status, message?, error_type?}   non-2xx instead of a stream; must be the first step
  drop       {}                            reset the connection (the client sees a network error)
  close      {}                            close the connection cleanly mid-stream (a truncated stream)
  hold       {}                            send nothing more; wait for the client to disconnect

`usage` and `finish` apply when the steps run out. Without `finish` the stream ends with `stop`
(`tool_calls` when a tool_call step ran); without `usage` the usage is derived from the text length.

On Ollama's native API (`/ollama/api/chat`) a tool call arrives whole with object arguments and no id
(unless the step names one), `thinking` becomes `message.thinking`, and a tool-calling response ends with
`done_reason: stop`. The scenario queue is shared with the OpenAI routes under `/ollama/v1`.
"""

from providers import Provider


class ScenarioError(ValueError):
    pass


REQUIRED = {
    "text": ("text",),
    "thinking": ("text",),
    "tool_call": ("name",),
    "usage": (),
    "finish": ("reason",),
    "open": (),
    "gate": ("name",),
    "delay": ("ms",),
    "keepalive": (),
    "sse_error": ("message",),
    "http_error": ("status",),
    "drop": (),
    "close": (),
    "hold": (),
}


def validate_steps(provider: Provider, steps) -> None:
    if not isinstance(steps, list):
        raise ScenarioError("`steps` must be an array")
    for i, step in enumerate(steps):
        if not isinstance(step, dict) or step.get("type") not in REQUIRED:
            raise ScenarioError(f"step {i}: unknown or missing `type`")
        kind = step["type"]
        for field in REQUIRED[kind]:
            if field not in step:
                raise ScenarioError(f"step {i} ({kind}): missing `{field}`")
        if kind == "thinking" and provider.wire == "openai" and provider.thinking_field is None:
            raise ScenarioError(f"step {i}: {provider.name} does not stream reasoning text")
        if kind == "http_error" and i != 0:
            raise ScenarioError(f"step {i}: `http_error` must be the first step")
