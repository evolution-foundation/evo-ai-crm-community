"""Unit tests for OpenRouter model normalization — EVO-1684.

When an agent's API key has ``provider="openrouter"`` but the persisted
``agent.model`` lacks the ``openrouter/`` prefix, LiteLLM routes the request
to the underlying vendor (OpenAI/Anthropic/etc.) and the OpenRouter key gets
rejected. ``normalize_model_for_provider`` injects the prefix while
preserving the vendor segment, idempotently, and ``get_api_key`` exposes the
provider value to the caller that builds the ``LiteLlm`` model.
"""

from __future__ import annotations

import uuid
from types import SimpleNamespace
from unittest.mock import patch

import pytest

from src.utils.llm_model_routing import normalize_model_for_provider


# --- AC7: model normalization matrix ---------------------------------------


@pytest.mark.parametrize(
    ("provider", "model_in", "model_out", "expect_openrouter_kwargs"),
    [
        # Case 1: bare model, OpenRouter — default vendor to openai.
        ("openrouter", "gpt-4.1", "openrouter/openai/gpt-4.1", True),
        # Case 2: vendor-prefixed (the re-save scenario) — preserve vendor.
        ("openrouter", "openai/gpt-4.1", "openrouter/openai/gpt-4.1", True),
        # Case 3: already prefixed — idempotent.
        (
            "openrouter",
            "openrouter/openai/gpt-4.1",
            "openrouter/openai/gpt-4.1",
            True,
        ),
        # Case 4: non-OpenAI vendor via OpenRouter.
        (
            "openrouter",
            "anthropic/claude-3-5-sonnet",
            "openrouter/anthropic/claude-3-5-sonnet",
            True,
        ),
        # Case 5: OpenAI provider, bare model — untouched.
        ("openai", "gpt-4.1", "gpt-4.1", False),
        # Case 6: OpenAI provider, vendor-prefixed — untouched.
        ("openai", "openai/gpt-4.1", "openai/gpt-4.1", False),
        # Case 7: Gemini provider — untouched (GeminiWithApiKey path handles).
        (
            "gemini",
            "gemini/gemini-2.0-flash-exp",
            "gemini/gemini-2.0-flash-exp",
            False,
        ),
        # Case 8: no provider (config-supplied raw key) — untouched.
        (None, "gpt-4.1", "gpt-4.1", False),
    ],
)
def test_normalize_model_for_provider(
    provider, model_in, model_out, expect_openrouter_kwargs
):
    normalized, extra = normalize_model_for_provider(model_in, provider)
    assert normalized == model_out
    if expect_openrouter_kwargs:
        assert extra == {"api_base": "https://openrouter.ai/api/v1"}
    else:
        assert extra == {}


def test_normalize_is_idempotent_under_repeated_application():
    """Guards AC3: a re-save loop must not stack ``openrouter/`` prefixes."""
    model = "openai/gpt-4.1"
    for _ in range(5):
        model, _ = normalize_model_for_provider(model, "openrouter")
    assert model == "openrouter/openai/gpt-4.1"


# --- Perplexity: Responses ids are routed, legacy chat ids are not ---------

_TOOLS_WHITELIST = {"allowed_openai_params": ["tools"]}


@pytest.mark.parametrize(
    ("model_in", "model_out", "extra_out"),
    [
        # Doubled vendor: the current Sonar. Without the marker the remainder
        # collides with the legacy `perplexity/sonar` entry.
        (
            "perplexity/perplexity/sonar",
            "perplexity/responses/perplexity/sonar",
            _TOOLS_WHITELIST,
        ),
        # Presets are the other shape the Responses catalogue uses.
        (
            "perplexity/preset/pro-search",
            "perplexity/responses/preset/pro-search",
            _TOOLS_WHITELIST,
        ),
        (
            "perplexity/preset/deep-research",
            "perplexity/responses/preset/deep-research",
            _TOOLS_WHITELIST,
        ),
        # Models Perplexity fronts from other vendors follow the same shape.
        (
            "perplexity/anthropic/claude-sonnet-4-5",
            "perplexity/responses/anthropic/claude-sonnet-4-5",
            _TOOLS_WHITELIST,
        ),
        # Already marked — idempotent.
        (
            "perplexity/responses/perplexity/sonar",
            "perplexity/responses/perplexity/sonar",
            _TOOLS_WHITELIST,
        ),
        # Single segment is a retired Chat Completions id. An agent still on one
        # keeps the route it was created with; nothing rewrites its model.
        ("perplexity/sonar", "perplexity/sonar", {}),
        ("perplexity/sonar-reasoning-pro", "perplexity/sonar-reasoning-pro", {}),
    ],
)
def test_normalize_perplexity_models(model_in, model_out, extra_out):
    assert normalize_model_for_provider(model_in, "perplexity") == (
        model_out,
        extra_out,
    )


def test_perplexity_model_on_openrouter_key_stays_on_openrouter():
    """The provider still wins: an OpenRouter key must not reach Perplexity."""
    normalized, extra = normalize_model_for_provider("perplexity/sonar", "openrouter")
    assert normalized == "openrouter/perplexity/sonar"
    assert extra == {"api_base": "https://openrouter.ai/api/v1"}


# --- AC8: get_api_key returns (api_key, provider) --------------------------

# The agent_utils module pulls in google-adk / langgraph / MCP through its
# package init chain; the get_api_key suite below skips gracefully when those
# aren't installed locally (CI runs them in the full container env).
try:
    from src.services.adk.agents.agent_utils import get_api_key  # noqa: E402

    _agent_utils_available = True
    _agent_utils_skip_reason = ""
except Exception as _exc:  # pragma: no cover — env-dependent
    get_api_key = None  # type: ignore[assignment]
    _agent_utils_available = False
    _agent_utils_skip_reason = f"ADK runtime deps not importable: {_exc!r}"

_skip_if_no_adk = pytest.mark.skipif(
    not _agent_utils_available, reason=_agent_utils_skip_reason
)


@_skip_if_no_adk
@pytest.mark.asyncio
async def test_get_api_key_returns_provider_when_stored_key_referenced():
    key_id = uuid.uuid4()
    agent = SimpleNamespace(
        name="agent-or",
        api_key_id=key_id,
        config={},
    )

    api_key_record = SimpleNamespace(provider="openrouter")

    class _Query:
        def filter(self, *_a, **_kw):
            return self

        def first(self):
            return api_key_record

    class _Session:
        def query(self, _model):
            return _Query()

    with patch(
        "src.services.adk.agents.agent_utils.get_decrypted_api_key",
        return_value="sk-or-v1-fake",
    ):
        api_key, provider = await get_api_key(_Session(), agent)

    assert api_key == "sk-or-v1-fake"
    assert provider == "openrouter"


@_skip_if_no_adk
@pytest.mark.asyncio
async def test_get_api_key_returns_none_provider_when_config_only():
    """Config-supplied raw key (no ``api_key_id``) carries no provider metadata."""
    agent = SimpleNamespace(
        name="agent-config",
        api_key_id=None,
        config={"api_key": "raw-key-value"},
    )

    class _Session:
        def query(self, _model):  # pragma: no cover — must not be called
            raise AssertionError("DB should not be hit when api_key_id is missing")

    api_key, provider = await get_api_key(_Session(), agent)
    assert api_key == "raw-key-value"
    assert provider is None
