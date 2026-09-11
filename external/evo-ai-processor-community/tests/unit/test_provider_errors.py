"""
CRM-236: a provider refusing us for quota reasons must not look like a bug in
our code. Before this, `standard_runner` wrapped EVERY failure in
`InternalServerError(str(e))` and the A2A route answered a flat
`500 / -32603 / INTERNAL_ERROR` — so a 429 and a NameError were byte-identical
from outside, and the only way to tell them apart was reading container logs.
"""

import pytest

from src.core.exceptions import InternalServerError
from src.utils.provider_errors import (
    classify_provider_error,
    redact_secrets,
)
from src.utils.response import map_status_to_error_code


# --- the incident, reproduced -------------------------------------------------

# Verbatim shape of what litellm raised during the outage that opened CRM-236.
GEMINI_QUOTA_ERROR = (
    "litellm.RateLimitError: VertexAIException - 429 RESOURCE_EXHAUSTED. "
    "Quota exceeded for metric "
    "generativelanguage.googleapis.com/generate_content_free_tier_requests, "
    "limit: 20, model: gemini-2.5-flash"
)


def test_quota_exhaustion_is_reported_as_rate_limit_not_as_our_bug():
    # Wrapped exactly like the runner wraps it.
    wrapped = InternalServerError(GEMINI_QUOTA_ERROR)
    wrapped.__cause__ = Exception(GEMINI_QUOTA_ERROR)

    failure = classify_provider_error(wrapped)

    assert failure is not None, "the operator would still be hunting a phantom bug"
    assert failure.kind == "rate_limit"
    assert failure.http_status == 429
    assert failure.jsonrpc_code == -32010


def test_the_429_reaches_the_envelope_as_rate_limit_exceeded():
    """The status is only useful if the response `code` follows it.

    `map_status_to_error_code` had no 429 entry, so it fell through to
    INTERNAL_ERROR and the envelope kept saying "our fault".
    """
    assert map_status_to_error_code(429) == "RATE_LIMIT_EXCEEDED"
    assert map_status_to_error_code(499) == "CLIENT_CLOSED_REQUEST"
    assert map_status_to_error_code(413) == "PAYLOAD_TOO_LARGE"


def test_high_demand_503_is_reported_as_unavailable():
    failure = classify_provider_error(
        Exception("The model is overloaded. Please try again later.")
    )
    assert failure is not None
    assert failure.kind == "unavailable"
    assert failure.http_status == 503


def test_status_code_wins_over_text_WITHIN_a_provider_exception():
    """An SDK that states 429 is stating it; text matching is only inference.

    Rewritten after the CRM-236 review. The original version asserted that ANY
    exception carrying `status_code = 429` classified as a rate limit, which is
    precisely the defect: httpx errors from our own services carry statuses too.
    The status still wins over text — but only once the exception is known to
    come from a provider.
    """

    class SdkError(Exception):
        __module__ = "litellm.exceptions"
        status_code = 429

    failure = classify_provider_error(SdkError("something went sideways"))
    assert failure is not None and failure.kind == "rate_limit"


def test_a_bare_status_code_on_an_unknown_exception_classifies_nothing():
    """The counterpart: no provider anchor, no classification."""

    class MysteryError(Exception):
        status_code = 429

    assert classify_provider_error(MysteryError("something went sideways")) is None


def test_rejected_credentials_are_not_an_internal_error():
    failure = classify_provider_error(Exception("API key not valid. Please pass a valid API key."))
    assert failure is not None
    assert failure.kind == "auth"
    assert failure.http_status == 502  # ours to fix, but upstream-caused


def test_context_window_overflow_is_recognised():
    failure = classify_provider_error(
        Exception("This model's maximum context length is 8192 tokens")
    )
    assert failure is not None and failure.kind == "context_length"


# --- CRM-424: a retired/obsolete model is actionable, not a recurring 500 ------

def test_gemini_retired_model_is_reported_as_model_not_found():
    # Verbatim shape of what the Gemini API returns for a model that was removed.
    err = (
        "litellm.NotFoundError: geminiException - models/gemini-2.5-flash-preview-05-20 "
        "is not found for API version v1beta, or is not supported for generateContent."
    )
    wrapped = InternalServerError(err)
    wrapped.__cause__ = Exception(err)

    failure = classify_provider_error(wrapped)

    assert failure is not None, "a dead model must not read as a bug in our code"
    assert failure.kind == "model_not_found"
    assert failure.jsonrpc_code == -32014
    assert "deprecated" in failure.message.lower() or "renamed" in failure.message.lower()


def test_openai_missing_model_is_model_not_found():
    # Verbatim: OpenAI always appends the access clause, and it is that clause —
    # not a bare "does not exist" — that makes the marker safe to match on.
    failure = classify_provider_error(
        Exception(
            "litellm.NotFoundError: The model `gpt-foo` does not exist or you do not "
            "have access to it."
        )
    )
    assert failure is not None and failure.kind == "model_not_found"


def test_a_bare_provider_404_still_classifies_once_nothing_else_explains_it():
    """Some SDKs carry the status and nothing quotable in the text."""

    class GeminiError(Exception):
        status_code = 404

    failure = classify_provider_error(GeminiError("model gemini-2.0-pro not available"))
    assert failure is not None and failure.kind == "model_not_found"


def test_the_model_error_does_not_answer_404_on_a_route_where_404_means_agent():
    """`POST /a2a/{agent_id}` already answers 404 for an agent that does not exist,
    and map_status_to_error_code turns any 404 into NOT_FOUND. Returning the
    provider's 404 verbatim would make a dead model indistinguishable from a dead
    agent — the same confusion that pushed `auth` to 502 instead of 401."""
    failure = classify_provider_error(
        Exception("litellm.NotFoundError: The model `gpt-foo` does not exist or you "
                  "do not have access to it.")
    )
    assert failure is not None
    assert failure.http_status == 502
    assert map_status_to_error_code(failure.http_status) != "NOT_FOUND"


# --- a 404 must not swallow the diagnosis the text already carries -------------

def test_a_404_carrying_credential_wording_is_still_auth():
    """The status is the weaker signal when the two disagree. While the bare-404
    check ran first, a revoked key sent the operator to change the agent's model."""

    class GeminiError(Exception):
        status_code = 404

    failure = classify_provider_error(
        GeminiError("API key not valid. Please pass a valid API key.")
    )
    assert failure is not None and failure.kind == "auth"


def test_a_context_overflow_that_also_says_does_not_exist_is_context_length():
    failure = classify_provider_error(
        Exception(
            "litellm: maximum context length is 8192 tokens; tool `x` does not exist"
        )
    )
    assert failure is not None and failure.kind == "context_length"


# --- the part that must NOT fire ----------------------------------------------

def test_a_genuine_bug_in_our_code_stays_a_500():
    """The whole point is discrimination. If everything classifies as a
    provider fault, we have only moved the lie."""
    assert classify_provider_error(NameError("name 'foo' is not defined")) is None
    assert classify_provider_error(KeyError("contact_id")) is None
    assert classify_provider_error(ValueError("invalid literal for int()")) is None


def test_our_own_bug_is_not_a_dead_model_just_because_it_names_one():
    """_provider_anchored accepts any text carrying a model name, so the moment a
    marker as loose as "does not exist" was added, our own lookups classified as a
    provider fault. The bug reads as OUR 500 again only while the markers stay
    verbatim."""
    assert classify_provider_error(KeyError("gpt-4.1-mini does not exist")) is None
    assert classify_provider_error(
        Exception("agent config for gemini-2.5-flash does not exist in the database")
    ) is None
    assert classify_provider_error(
        Exception("litellm.NotFoundError: No such File object: file-abc for gpt-4o")
    ) is None


def test_our_own_wrapper_name_does_not_read_as_a_provider_outage():
    """`InternalServerError` is OUR class and wraps every failure.

    An earlier draft of this module listed "internalservererror" as an
    unavailability marker, which would have classified every bug we ever write
    as a provider outage — the exact inversion of the bug being fixed.
    """
    assert classify_provider_error(InternalServerError("division by zero")) is None


def test_a_database_timeout_is_not_blamed_on_the_provider():
    """A bare "timeout" marker matched our own infrastructure just as well."""
    assert classify_provider_error(Exception("psycopg2 statement timeout")) is None


def test_a_number_that_merely_looks_like_a_status_is_ignored():
    """Ids and token counts contain 429 too."""
    assert classify_provider_error(Exception("contact 429 not found in pipeline")) is None


# --- credentials must never travel in the response ----------------------------

@pytest.mark.parametrize(
    "text,secret",
    [
        ("POST https://api.example.com/v1?key=AIzaSyD-EXAMPLE-KEY-1234567 failed", "AIzaSyD"),
        ("headers: {'Authorization': 'Bearer sk-proj-abcdef1234567890'}", "sk-proj-abcdef"),
        ('{"api_key": "super-secret-value-here"}', "super-secret-value-here"),
    ],
)
def test_credentials_are_redacted_before_leaving(text, secret):
    assert secret not in redact_secrets(text)
    assert "[REDACTED]" in redact_secrets(text)


def test_the_detail_returned_to_the_caller_is_redacted_and_bounded():
    failure = classify_provider_error(
        Exception("429 RESOURCE_EXHAUSTED calling https://x/v1?key=AIzaSyD-EXAMPLE-KEY-1234567 " + "x" * 2000)
    )
    assert failure is not None
    assert "AIzaSyD" not in failure.detail
    assert len(failure.detail) <= 601


def test_cause_chain_is_walked_but_bounded_by_a_cycle():
    """`raise InternalServerError(str(e)) from e` is the runner's pattern, and
    a self-referencing chain must not hang the classifier."""
    inner = Exception("quota exceeded")
    outer = InternalServerError("wrapped")
    outer.__cause__ = inner
    inner.__context__ = outer  # cycle

    failure = classify_provider_error(outer)
    assert failure is not None and failure.kind == "rate_limit"


# --- CRM-236 review, finding 1: our own infrastructure is not the provider ----
#
# The first version trusted `status_code` on ANY link of the cause chain, with no
# provider anchor. The runner calls raise_for_status() against internal services
# (standard_runner.py:222 memory, :311 evo-kb-service), so their httpx errors
# entered the chain and were classified: a knowledge-base outage was reported as
# "The model provider is unavailable", and a wrong internal token as "The model
# provider rejected our credentials" — the exact inversion of the bug this module
# fixes.

def _internal_http_error(status: int, url: str = "http://evo-kb-service:8080/search"):
    import httpx

    request = httpx.Request("POST", url)
    response = httpx.Response(status, request=request)
    return httpx.HTTPStatusError(f"Server error '{status}'", request=request, response=response)


def _as_the_runner_wraps_it(exc: BaseException) -> BaseException:
    inner = InternalServerError(str(exc))
    inner.__cause__ = exc
    outer = InternalServerError(str(inner))
    outer.__cause__ = inner
    return outer


@pytest.mark.parametrize(
    "status,what",
    [
        (503, "evo-kb-service is down"),
        (502, "bad gateway from an internal service"),
        (401, "KNOWLEDGE_SERVICE_API_TOKEN is wrong"),
        (403, "internal service refused us"),
        (429, "internal service rate-limited us"),
    ],
)
def test_our_own_service_failing_is_not_reported_as_a_provider_outage(status, what):
    assert classify_provider_error(_as_the_runner_wraps_it(_internal_http_error(status))) is None, what


def test_an_internal_auth_failure_is_not_the_provider_rejecting_our_key():
    exc = Exception(
        "EvoAuth: HTTP error for POST /api/v1/auth/validate: 401 - "
        '{"success":false,"error":{"code":"INVALID_TOKEN"}}'
    )
    assert classify_provider_error(_as_the_runner_wraps_it(exc)) is None


# --- the anchored cases must still classify ----------------------------------

def test_a_provider_sdk_status_still_classifies_without_any_text_marker():
    """The anchor must not cost us the case status matching exists for."""

    class LiteLLMError(Exception):
        __module__ = "litellm.exceptions"
        status_code = 429

    failure = classify_provider_error(_as_the_runner_wraps_it(LiteLLMError("boom")))
    assert failure is not None and failure.kind == "rate_limit"


@pytest.mark.parametrize(
    "text,kind",
    [
        (GEMINI_QUOTA_ERROR, "rate_limit"),
        ("litellm.AuthenticationError: geminiException - API key not valid.", "auth"),
        ("litellm: The model gemini-2.5-flash is overloaded. Please try again later.", "unavailable"),
    ],
)
def test_real_provider_errors_survive_the_anchor(text, kind):
    failure = classify_provider_error(_as_the_runner_wraps_it(Exception(text)))
    assert failure is not None and failure.kind == kind


# --- CRM-236 review, finding 4: no collision with the repo's A2A catalogue ----

def test_the_jsonrpc_codes_do_not_collide_with_the_a2a_catalogue():
    """src/schemas/a2a_types.py owns -32001..-32005 and a2a_routes.py emits them.

    Reasoning about the reserved RANGE was not enough: an exhausted quota went on
    the wire as "Task not found" to any conforming A2A client.
    """
    from src.schemas import a2a_types

    taken = {
        cls.model_fields["code"].default
        for name, cls in vars(a2a_types).items()
        if isinstance(cls, type)
        and hasattr(cls, "model_fields")
        and "code" in getattr(cls, "model_fields", {})
        and isinstance(cls.model_fields["code"].default, int)
    }

    ours = set()
    for text, _kind in [
        (GEMINI_QUOTA_ERROR, "rate_limit"),
        ("litellm: model is overloaded", "unavailable"),
        ("litellm.AuthenticationError: API key not valid", "auth"),
        ("litellm: This model's maximum context length is 8192 tokens", "context_length"),
    ]:
        failure = classify_provider_error(Exception(text))
        assert failure is not None
        ours.add(failure.jsonrpc_code)

    assert ours, "no codes collected — the fixtures stopped classifying"
    assert not (ours & taken), f"collides with the A2A catalogue: {sorted(ours & taken)}"
