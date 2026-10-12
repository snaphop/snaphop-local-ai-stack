"""Shrink a requested output cap so it fits the served vLLM context window.

vLLM treats max_tokens as space reserved inside --max-model-len. A client that
sends a long prompt plus a large cap (OpenCode uses limit.output, 16384) is
rejected even when the prompt alone would fit. This pre-call hook asks the
local engine for a real token count and lowers only the output cap.
"""

from __future__ import annotations

import logging
import os
from typing import Any

try:
    from litellm.integrations.custom_logger import CustomLogger
except Exception:  # host checks do not install the gateway image
    CustomLogger = object  # type: ignore[misc,assignment]

log = logging.getLogger("context_window")

_OUTPUT_KEYS = ("max_tokens", "max_completion_tokens")
_DEFAULT_CONTEXT = 32768
_DEFAULT_MARGIN = 64


def requested_output(data: dict[str, Any]) -> int | None:
    """Largest positive output cap on the request, if the client set one."""
    found: list[int] = []
    for key in _OUTPUT_KEYS:
        value = data.get(key)
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            continue
        if value > 0 and float(value) == int(value):
            found.append(int(value))
    if not found:
        return None
    return max(found)


def apply_output_cap(data: dict[str, Any], cap: int) -> None:
    """Lower output caps that are above cap. Leave smaller caps alone."""
    for key in _OUTPUT_KEYS:
        value = data.get(key)
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            continue
        if value > cap:
            data[key] = cap


def clamped_output_tokens(
    requested: int | None,
    prompt_tokens: int | None,
    max_model_len: int,
    margin: int = _DEFAULT_MARGIN,
) -> int | None:
    """Return a smaller output cap when the request does not fit.

    None means forward the request unchanged: the cap already fits, the sizes
    are unknown, or the prompt itself fills the window. A full prompt is left
    for vLLM to reject.
    """
    if (
        requested is None
        or prompt_tokens is None
        or requested < 1
        or max_model_len < 1
        or prompt_tokens < 0
        or prompt_tokens >= max_model_len
    ):
        return None
    room = max_model_len - prompt_tokens - max(margin, 0)
    if room < 1:
        room = max_model_len - prompt_tokens
    if requested > room:
        return room
    return None


def served_context_limit(reported: object, configured: int) -> int:
    """Use the tighter of the tokenizer report and the configured window.

    The tokenize response is the engine's served length. The configured value
    is --max-model-len. Taking the minimum still clamps correctly if one of
    them is the model's native 262144 instead of the served 32768.
    """
    limits: list[int] = []
    if isinstance(reported, int) and not isinstance(reported, bool) and reported > 0:
        limits.append(reported)
    if configured > 0:
        limits.append(configured)
    if not limits:
        return _DEFAULT_CONTEXT
    return min(limits)


def prompt_token_count(body: object) -> int | None:
    if not isinstance(body, dict):
        return None
    count = body.get("count")
    if isinstance(count, int) and not isinstance(count, bool) and count >= 0:
        return count
    tokens = body.get("tokens")
    if isinstance(tokens, list):
        return len(tokens)
    return None


def tokenize_payload(data: dict[str, Any], model: str) -> dict[str, Any] | None:
    """Body for vLLM POST /tokenize. Copies prompt fields only."""
    payload: dict[str, Any] = {}
    if model:
        payload["model"] = model
    messages = data.get("messages")
    if isinstance(messages, list) and messages:
        payload["messages"] = messages
        payload["add_generation_prompt"] = True
        tools = data.get("tools")
        if isinstance(tools, list) and tools:
            payload["tools"] = tools
        kwargs = data.get("chat_template_kwargs")
        if isinstance(kwargs, dict) and kwargs:
            payload["chat_template_kwargs"] = kwargs
        return payload
    prompt = data.get("prompt")
    if isinstance(prompt, str) and prompt:
        payload["prompt"] = prompt
        return payload
    return None


def _positive_int(raw: str | None, default: int) -> int:
    if raw is None or not raw.strip():
        return default
    try:
        value = int(raw)
    except ValueError:
        return default
    if value < 0:
        return default
    return value


def configured_context_limit() -> int:
    value = _positive_int(os.environ.get("VLLM_MAX_MODEL_LEN"), _DEFAULT_CONTEXT)
    return value if value > 0 else _DEFAULT_CONTEXT


def configured_margin() -> int:
    return _positive_int(os.environ.get("CONTEXT_WINDOW_MARGIN"), _DEFAULT_MARGIN)


class ContextWindowGuard(CustomLogger):
    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
        if not isinstance(data, dict):
            return data
        requested = requested_output(data)
        payload = tokenize_payload(data, os.environ.get("VLLM_MODEL", "").strip())
        if requested is None or payload is None:
            return data
        counted = await _tokenize(payload)
        if counted is None:
            return data
        prompt_tokens, reported = counted
        limit = served_context_limit(reported, configured_context_limit())
        cap = clamped_output_tokens(requested, prompt_tokens, limit, configured_margin())
        if cap is None:
            return data
        apply_output_cap(data, cap)
        log.info(
            "clamped output tokens from %s to %s (prompt_tokens=%s max_model_len=%s)",
            requested,
            cap,
            prompt_tokens,
            limit,
        )
        return data


async def _tokenize(payload: dict[str, Any]) -> tuple[int, object] | None:
    import httpx

    url = os.environ.get("VLLM_TOKENIZE_URL", "http://vllm:8000/tokenize")
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            response = await client.post(url, json=payload)
            response.raise_for_status()
            body = response.json()
    except Exception as exc:
        log.warning("context-window tokenize failed (%s); leaving max_tokens unchanged", type(exc).__name__)
        return None
    count = prompt_token_count(body)
    if count is None:
        log.warning("context-window tokenize returned no count; leaving max_tokens unchanged")
        return None
    reported = body.get("max_model_len") if isinstance(body, dict) else None
    return count, reported


proxy_handler_instance = ContextWindowGuard()
