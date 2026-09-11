"""LLM model identifier normalization for provider routing — EVO-1684.

Lives outside ``src.services`` so it can be imported (and unit-tested) without
pulling in the ADK / google-adk / langgraph dependency chain.
"""

from __future__ import annotations

from typing import Optional, Tuple


OPENROUTER_API_BASE = "https://openrouter.ai/api/v1"

PERPLEXITY_PREFIX = "perplexity/"
RESPONSES_MARKER = "responses/"


def _route_perplexity_through_responses(model: str) -> Tuple[str, dict]:
    """Route a Perplexity Responses-API model to ``/v1/responses``.

    Perplexity's catalogue splits by shape: a single segment is a retired Chat
    Completions id, a sub-path is a current one, and only the latter accepts
    tools. The ``responses/`` marker keeps provider detection from reducing
    ``perplexity/perplexity/sonar`` to the legacy chat entry of the same name,
    and ``allowed_openai_params`` gets ``tools`` past the chat config LiteLLM
    validates against before it bridges.
    """
    remainder = model[len(PERPLEXITY_PREFIX) :]
    extra_kwargs = {"allowed_openai_params": ["tools"]}

    if remainder.startswith(RESPONSES_MARKER):
        return model, extra_kwargs

    if "/" not in remainder:
        return model, {}

    return f"{PERPLEXITY_PREFIX}{RESPONSES_MARKER}{remainder}", extra_kwargs


def normalize_model_for_provider(
    model: str, provider: Optional[str]
) -> Tuple[str, dict]:
    """Normalize a model identifier for the configured LLM provider.

    For ``provider="openrouter"``, prepend ``openrouter/`` so LiteLLM routes
    the call to OpenRouter instead of the underlying vendor (otherwise an
    OpenRouter API key gets sent to OpenAI/Anthropic/etc. and is rejected —
    see EVO-1684). The vendor segment is preserved verbatim; when the model
    has no vendor at all we default to ``openai`` (the most common path via
    OpenRouter). Idempotent for already-prefixed values.

    Perplexity is routed by the model id rather than the provider, because the
    vendor is already part of the id — see
    :func:`_route_perplexity_through_responses`.

    Returns ``(normalized_model, extra_litellm_kwargs)``.
    """
    if provider != "openrouter":
        if model and model.startswith(PERPLEXITY_PREFIX):
            return _route_perplexity_through_responses(model)
        return model, {}

    extra_kwargs = {"api_base": OPENROUTER_API_BASE}

    if not model:
        return model, extra_kwargs

    if model.startswith("openrouter/"):
        return model, extra_kwargs

    if "/" in model:
        return f"openrouter/{model}", extra_kwargs

    # Bare model name (e.g. "gpt-4.1") — assume OpenAI vendor on OpenRouter.
    return f"openrouter/openai/{model}", extra_kwargs
