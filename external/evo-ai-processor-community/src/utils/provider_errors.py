"""
Classify LLM-provider failures so the operator sees WHY a turn failed.

The runner funnels every exception into `InternalServerError(str(e))`, so a
quota exhaustion and a bug of ours answered identically. This reads the cause
chain and returns what to send instead. Conservative on purpose: no match means
None and the caller keeps its 500. No provider SDK is imported — matching is on
class name, status attribute and text.
"""

import re
from dataclasses import dataclass
from typing import Any, List, Optional

from src.utils.logger import setup_logger

logger = setup_logger(__name__)

# How deep to walk __cause__/__context__. The runner wraps once
# (`raise InternalServerError(str(e)) from e`) and the SDKs may wrap once or
# twice more; 6 is comfortably beyond any real chain and bounds a cycle.
_MAX_CAUSE_DEPTH = 6


@dataclass(frozen=True)
class ProviderFailure:
    """A provider-side condition worth reporting verbatim to the operator."""

    kind: str  # rate_limit | unavailable | model_not_found | auth | context_length
    http_status: int
    # -3201x, not the bottom of the reserved -32000..-32099 range: a2a_types.py
    # already owns -32001..-32005 and a2a_routes.py emits them, so a quota error
    # went out as "Task not found". -32006..-32009 left free for that catalogue.
    jsonrpc_code: int
    message: str
    detail: str


# Secrets travel inside provider error strings more often than one would like:
# litellm echoes the request URL (`?key=AIza...`), and some SDKs include the
# Authorization header in the repr. `detail` is returned over the API, so it is
# redacted before it leaves this module.
_SECRET_PATTERNS = [
    # The optional quote BEFORE the separator matters: provider errors carry the
    # key both as a query string (`?key=AIza…`) and as JSON (`"api_key": "…"`),
    # and without it the closing quote of the JSON key blocks the match.
    re.compile(
        r"(?i)\b(api[_-]?key|key|token|access[_-]?token)[\"']?\s*[=:]\s*[\"']?([^\s\"'&,}]+)"
    ),
    re.compile(r"(?i)\bbearer\s+([A-Za-z0-9\-._~+/]+=*)"),
    re.compile(r"\bAIza[0-9A-Za-z\-_]{10,}"),
    re.compile(r"\bsk-[A-Za-z0-9\-_]{10,}"),
]


def redact_secrets(text: str) -> str:
    """Strip anything that looks like a credential out of provider text."""
    if not text:
        return ""
    redacted = text
    for pattern in _SECRET_PATTERNS:
        redacted = pattern.sub(
            lambda m: m.group(0).replace(m.group(m.lastindex or 0), "[REDACTED]", 1),
            redacted,
        )
    return redacted


def _status_code_of(exc: BaseException) -> Optional[int]:
    """Best-effort HTTP status carried by an SDK exception."""
    for attribute in ("status_code", "http_status", "code"):
        value = getattr(exc, attribute, None)
        if isinstance(value, bool):
            continue
        if isinstance(value, int) and 100 <= value <= 599:
            return value
        # google-genai puts the numeric status in a string field
        if isinstance(value, str) and value.isdigit():
            number = int(value)
            if 100 <= number <= 599:
                return number
    response = getattr(exc, "response", None)
    status = getattr(response, "status_code", None)
    if isinstance(status, int) and 100 <= status <= 599:
        return status
    return None


def _cause_chain(exc: BaseException) -> List[BaseException]:
    """`exc` plus its __cause__/__context__ ancestors, de-duplicated."""
    chain: List[BaseException] = []
    seen = set()
    current: Optional[BaseException] = exc
    while current is not None and len(chain) < _MAX_CAUSE_DEPTH:
        if id(current) in seen:
            break
        seen.add(id(current))
        chain.append(current)
        current = current.__cause__ or current.__context__
    return chain


# Matched against the exception's class name AND its text, lowercased.
# Anchored on wording that only appears in provider errors — a bare "429" is
# NOT enough, since it also matches ids and token counts in unrelated messages.
_RATE_LIMIT_MARKERS = (
    "ratelimiterror",
    "rate_limit",
    "rate limit",
    "resource_exhausted",
    "resource exhausted",
    "resourceexhausted",
    "too many requests",
    "quota exceeded",
    "exceeded your current quota",
    "insufficient_quota",
)

# NOTE: no bare "timeout" and no "internalservererror" marker here. Our own
# wrapper is *named* InternalServerError and wraps every failure, so matching on
# it would classify genuine bugs in our code as provider outages. Likewise a
# bare "timeout" matches a database timeout just as well as a provider one.
_UNAVAILABLE_MARKERS = (
    "serviceunavailable",
    "service_unavailable",
    "service unavailable",
    "overloaded",
    "high demand",
    "apiconnectionerror",
    "apitimeouterror",
    "deadline_exceeded",
    "deadline exceeded",
)

_AUTH_MARKERS = (
    "authenticationerror",
    "permission_denied",
    "permissiondenied",
    "unauthenticated",
    "api key not valid",
    "invalid api key",
    "invalid_api_key",
    "api_key_invalid",
)

_CONTEXT_MARKERS = (
    "contextwindowexceeded",
    "context_length_exceeded",
    "maximum context length",
    "request payload size exceeds",
)

# A configured model the provider no longer serves. Gemini answers "models/… is not
# found for API version …, or is not supported for generateContent"; OpenAI answers
# "The model `…` does not exist or you do not have access to it". Without this the
# 404 fell through to a generic 500 and the same agent failed on EVERY turn with no
# hint that its model was simply gone — the recurring silent failure of CRM-424. The
# catalogue no longer OFFERS retired models (core-service models_fetcher), but an
# agent configured before the retirement still points at one.
#
# Only verbatim provider wording belongs here. A bare "does not exist" matches our
# own KeyErrors just as well, and _provider_anchored accepts any text carrying a
# model name — so the loose variant reported OUR bugs as a provider fault, the exact
# inversion this module exists to prevent. Everything vaguer is left to the 404
# status check at the bottom of classify_provider_error.
_MODEL_MARKERS = (
    "not found for api version",
    "is not supported for generatecontent",
    "does not exist or you do not have access",
    "model_not_found",
)


def _matches(haystack: str, markers) -> bool:
    return any(marker in haystack for marker in markers)


# Evidence that an exception came from an LLM provider at all. Without it the
# runner's raise_for_status() against our own services (evo-kb-service, the
# memory service) carried their 5xx/401 into the chain and was reported as a
# provider outage. An anchor is required rather than internal hosts blacklisted:
# a blacklist rots, and forgetting one entry restores the inversion in silence.
_PROVIDER_MODULES = (
    "litellm",
    "openai",
    "anthropic",
    "google.genai",
    "google.generativeai",
    "google.api_core",
    "vertexai",
    "cohere",
    "mistralai",
    "groq",
    "boto3",
    "botocore",
)

_PROVIDER_CLASS_MARKERS = (
    "litellm",
    "openai",
    "anthropic",
    "vertexai",
    "gemini",
    "bedrock",
    "cohere",
)

# Text fingerprints. Deliberately specific: provider host names and SDK prefixes,
# never a bare vendor word like "google", which appears in unrelated URLs.
_PROVIDER_TEXT_MARKERS = (
    "litellm",
    "vertexaiexception",
    "geminiexception",
    "generativelanguage.googleapis.com",
    "aiplatform.googleapis.com",
    "api.openai.com",
    "api.anthropic.com",
    "api.mistral.ai",
    "api.cohere.ai",
    "bedrock-runtime",
    "resource_exhausted",
    "gemini-",
    "gpt-",
    "claude-",
)


# Wording only an LLM provider produces, so it anchors on its own. The ambiguous
# markers ("rate limit", "too many requests", a bare 429/503) stay out: an
# internal service produces those too, and they need separate evidence.
_SELF_ANCHORING_MARKERS = (
    "resource_exhausted",
    "resource exhausted",
    "resourceexhausted",
    "quota exceeded",
    "exceeded your current quota",
    "insufficient_quota",
    "api key not valid",
    "invalid api key",
    "invalid_api_key",
    "api_key_invalid",
    "model is overloaded",
    "overloaded",
    "high demand",
    "maximum context length",
    "context_length_exceeded",
    "contextwindowexceeded",
    "request payload size exceeds",
    "ratelimiterror",
    "authenticationerror",
    "apiconnectionerror",
    "apitimeouterror",
    "is not found for api version",
    "is not supported for generatecontent",
)


def _provider_anchored(exc: BaseException) -> bool:
    """Is there positive evidence that this exception came from an LLM provider?"""
    module = (getattr(type(exc), "__module__", "") or "").lower()
    if any(marker in module for marker in _PROVIDER_MODULES):
        return True

    name = type(exc).__name__.lower()
    if any(marker in name for marker in _PROVIDER_CLASS_MARKERS):
        return True

    haystack = f"{name} {exc}".lower()
    if any(marker in haystack for marker in _SELF_ANCHORING_MARKERS):
        return True

    return any(marker in haystack for marker in _PROVIDER_TEXT_MARKERS)


def classify_provider_error(exc: BaseException) -> Optional[ProviderFailure]:
    """Recognise a provider-side failure, or return None to keep the 500.

    A link is only considered when it is provider-anchored (see
    _provider_anchored). Within an anchored link, status codes win over text: an
    SDK that sets `status_code = 429` is stating the condition, whereas text
    matching is inference.
    """
    if exc is None:
        return None

    for link in _cause_chain(exc):
        # Without this, an httpx error from one of OUR services (evo-kb-service,
        # the memory service, EvoAuth) carries a 5xx/401 into the chain and gets
        # reported as a provider outage. See _provider_anchored.
        if not _provider_anchored(link):
            continue

        haystack = f"{type(link).__name__} {link}".lower()
        status = _status_code_of(link)

        if status == 429 or _matches(haystack, _RATE_LIMIT_MARKERS):
            return _build(
                "rate_limit",
                429,
                -32010,
                "The model provider refused the request: rate limit or quota exhausted.",
                link,
            )

        if status in (502, 503, 504) or _matches(haystack, _UNAVAILABLE_MARKERS):
            return _build(
                "unavailable",
                503,
                -32011,
                "The model provider is unavailable or overloaded.",
                link,
            )

        # Verbatim provider wording for a model that is gone. Ahead of auth because
        # none of these phrases can mean a credential problem.
        if _matches(haystack, _MODEL_MARKERS):
            return _build(
                "model_not_found",
                502,
                -32014,
                "The configured model is unavailable — the provider has renamed or "
                "deprecated it. Pick a current model in the agent settings.",
                link,
            )

        if status in (401, 403) or _matches(haystack, _AUTH_MARKERS):
            return _build(
                "auth",
                502,
                -32012,
                "The model provider rejected our credentials.",
                link,
            )

        if _matches(haystack, _CONTEXT_MARKERS):
            return _build(
                "context_length",
                413,
                -32013,
                "The request exceeded the model's context window.",
                link,
            )

        # Last resort: a 404 the branches above could not explain. The weakest
        # signal in the module — the same status covers a wrong api_base and a
        # deleted non-model resource — so it only speaks once nothing quotable
        # matched, and it says so instead of asserting the model is dead.
        if status == 404:
            return _build(
                "model_not_found",
                502,
                -32014,
                "The provider answered 404: the model configured for this agent is "
                "most likely gone. Check the model, and the base URL if this key "
                "points at a custom endpoint.",
                link,
            )

    return None


def _build(
    kind: str, http_status: int, jsonrpc_code: int, message: str, link: BaseException
) -> ProviderFailure:
    detail = redact_secrets(f"{type(link).__name__}: {link}")
    # Provider errors are verbose (full request echoes); keep the response bounded.
    if len(detail) > 600:
        detail = detail[:600] + "…"
    return ProviderFailure(
        kind=kind,
        http_status=http_status,
        jsonrpc_code=jsonrpc_code,
        message=message,
        detail=detail,
    )


def log_provider_failure(failure: ProviderFailure, agent_id: Any) -> None:
    """One line the operator can grep for without reading the whole trace."""
    logger.error(
        f"[CRM-236] provider failure kind={failure.kind} "
        f"http_status={failure.http_status} agent_id={agent_id} :: {failure.detail}"
    )
