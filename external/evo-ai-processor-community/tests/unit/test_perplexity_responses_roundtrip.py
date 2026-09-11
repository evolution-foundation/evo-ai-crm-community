"""The Perplexity axis serving an agent that carries tools.

The routing matrix in ``test_litellm_model_normalization`` only proves what
string comes out. What actually broke was a full turn: Perplexity's Chat
Completions config declares no ``tools`` support, and ``load_memory`` alone
injects two, so every agent with any tool died on the first round trip.

So these drive the real path — ``LlmAgentBuilder`` builds the agent, the ADK
Runner runs it, LiteLLM serialises the request — and stub only the socket. They
fail if the builder stops forwarding the routing kwargs, if LiteLLM changes how
it bridges to the Responses API, or if the two id shapes stop agreeing.
"""

from __future__ import annotations

import json
import uuid

import httpx
import litellm
import pytest
from google.adk.memory import InMemoryMemoryService
from google.adk.runners import Runner
from google.adk.sessions import InMemorySessionService
from google.genai import types

from src.models.models import Agent
from src.services.adk.agents import llm_agent_builder
from src.services.adk.agents.llm_agent_builder import LlmAgentBuilder


SONAR = "perplexity/perplexity/sonar"
PRESET = "perplexity/preset/pro-search"
LEGACY_CHAT_MODEL = "perplexity/sonar"

RESPONSES_URL = "https://api.perplexity.ai/v1/responses"


def _text_response(text: str) -> dict:
    return {
        "id": "resp_1",
        "object": "response",
        "created_at": 1,
        "model": "perplexity/sonar",
        "status": "completed",
        "parallel_tool_calls": False,
        "tool_choice": "auto",
        "tools": [],
        "usage": {"input_tokens": 9, "output_tokens": 4, "total_tokens": 13},
        "output": [
            {
                "type": "message",
                "id": "msg_1",
                "status": "completed",
                "role": "assistant",
                "content": [{"type": "output_text", "text": text, "annotations": []}],
            }
        ],
    }


def _tool_call_response(name: str, args: dict) -> dict:
    response = _text_response("")
    response["output"] = [
        {
            "type": "function_call",
            "id": "fc_1",
            "call_id": "call_1",
            "name": name,
            "arguments": json.dumps(args),
            "status": "completed",
        }
    ]
    return response


def _failed_response(message: str) -> dict:
    response = _text_response("")
    response["status"] = "failed"
    response["output"] = []
    response["error"] = {"code": "server_error", "message": message}
    return response


@pytest.fixture(autouse=True)
def silence_litellm_logging_worker(monkeypatch):
    """LiteLLM reports every call from a background task bound to the live loop.

    pytest-asyncio closes that loop when the test ends, so the task outlives it
    and the run reports "Task was destroyed but it is pending" against whatever
    test came next. Nothing here asserts on the report, so drop it at the door.
    """

    def _drop(async_coroutine):
        async_coroutine.close()

    monkeypatch.setattr(
        "litellm.litellm_core_utils.logging_worker.GLOBAL_LOGGING_WORKER"
        ".ensure_initialized_and_enqueue",
        _drop,
    )


@pytest.fixture
def perplexity(monkeypatch):
    """Stand in for the vendor at the socket, recording every request sent."""

    class _Stub:
        def __init__(self):
            self.requests: list[httpx.Request] = []
            self.replies = [_text_response("pong")]

        def answers(self, *replies: dict) -> None:
            self.replies = list(replies)

        @property
        def bodies(self) -> list[dict]:
            return [json.loads(r.content or b"{}") for r in self.requests]

        @property
        def urls(self) -> list[str]:
            return [str(r.url) for r in self.requests]

        def reply_for(self, turn: int) -> dict:
            return self.replies[min(turn, len(self.replies) - 1)]

    stub = _Stub()

    async def _send(_self, request: httpx.Request, **_kwargs) -> httpx.Response:
        stub.requests.append(request)
        return httpx.Response(
            200, json=stub.reply_for(len(stub.requests) - 1), request=request
        )

    monkeypatch.setattr(httpx.AsyncClient, "send", _send)
    return stub


def _agent(model: str) -> Agent:
    agent = Agent()
    agent.id = uuid.uuid4()
    agent.name = "sonar_agent"
    agent.type = "llm"
    agent.model = model
    agent.api_key_id = None
    agent.instruction = "Answer briefly."
    agent.role = "support"
    agent.goal = "answer the customer"
    agent.description = "agent under test"
    # `load_memory` is the cheapest way to reach the failure the axis had: it
    # injects load_memory and compress_memory, so the agent carries tools
    # without any being configured by hand.
    agent.config = {"api_key": "pplx-stub-key", "load_memory": True}
    return agent


async def _run(model: str, prompt: str = "what was my last order?"):
    """Build the agent the way the service does, then run one turn through it."""
    root, _ = await LlmAgentBuilder(db=None).build_llm_agent(_agent(model))

    session_service = InMemorySessionService()
    await session_service.create_session(app_name="test", user_id="u1", session_id="s1")
    runner = Runner(
        agent=root,
        app_name="test",
        session_service=session_service,
        memory_service=InMemoryMemoryService(),
    )

    final = None
    async for event in runner.run_async(
        user_id="u1",
        session_id="s1",
        new_message=types.Content(role="user", parts=[types.Part(text=prompt)]),
    ):
        if event.is_final_response() and event.content and event.content.parts:
            final = event.content.parts[0].text
    return root, final


@pytest.mark.asyncio
@pytest.mark.parametrize("model", [SONAR, PRESET])
async def test_agent_with_tools_completes_a_full_turn(perplexity, model):
    perplexity.answers(
        _tool_call_response("load_memory", {"query": "last order"}),
        _text_response("your last order was 4711"),
    )

    root, final = await _run(model)

    assert [t.name for t in root.tools] == ["load_memory", "compress_memory"]
    assert perplexity.urls == [RESPONSES_URL, RESPONSES_URL]

    first, second = perplexity.bodies
    assert [t["name"] for t in first["tools"]] == ["load_memory", "compress_memory"]
    assert perplexity.requests[0].headers["Authorization"] == "Bearer pplx-stub-key"
    # The model asked for the tool and the runner ran it: the second turn carries
    # the result back, which is the half a single-call test never reaches.
    assert any(item.get("type") == "function_call_output" for item in second["input"])
    assert final == "your last order was 4711"


@pytest.mark.asyncio
async def test_a_preset_travels_as_a_preset_not_as_a_model(perplexity):
    """Presets are most of the axis, and LiteLLM sends them in their own field."""
    await _run(PRESET)

    body = perplexity.bodies[0]
    assert body["preset"] == "pro-search"
    assert "model" not in body


@pytest.mark.asyncio
async def test_sonar_keeps_the_vendor_segment_the_api_expects(perplexity):
    await _run(SONAR)

    assert perplexity.bodies[0]["model"] == "perplexity/sonar"


@pytest.mark.asyncio
async def test_a_failed_response_raises_even_though_http_said_200(perplexity):
    """Perplexity reports refusals in the body, with a 200 on the wire."""
    perplexity.answers(_failed_response("upstream refused"))

    with pytest.raises(litellm.exceptions.APIError, match="upstream refused"):
        await _run(SONAR)


@pytest.mark.asyncio
@pytest.mark.parametrize("model", [SONAR, PRESET])
async def test_without_the_routing_the_same_turn_is_rejected(
    perplexity, monkeypatch, model
):
    """The failure this routing exists for, so the tests above cannot pass idly."""
    monkeypatch.setattr(
        llm_agent_builder, "normalize_model_for_provider", lambda m, _p: (m, {})
    )

    with pytest.raises(litellm.exceptions.UnsupportedParamsError):
        await _run(model)

    assert perplexity.requests == []


@pytest.mark.asyncio
async def test_a_legacy_chat_id_is_left_on_chat_completions(perplexity):
    """An agent still on a retired id is not moved to another endpoint.

    It fails, and that is the point: the axis is broken for tools either way, and
    silently re-pointing someone's model at a different endpoint is the larger
    harm. What must not happen is the request going to /v1/responses.
    """
    with pytest.raises(litellm.exceptions.UnsupportedParamsError):
        await _run(LEGACY_CHAT_MODEL)

    assert RESPONSES_URL not in perplexity.urls
