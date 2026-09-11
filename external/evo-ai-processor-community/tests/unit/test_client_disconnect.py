"""
CRM-236: the processor kept running an agent long after the caller hung up.

From the incident log:
    04:12:47  bot-runtime -> processor
    04:13:17  bot-runtime gives up (timeout), socket closed
    04:18:26  processor: "Agent execution completed successfully"

Five minutes of model calls nobody could receive — burning the same quota whose
exhaustion caused the timeout. These tests pin the race between the work and
the disconnect signal.
"""

import asyncio

import pytest

from src.utils.client_disconnect import (
    CANCEL_ON_DISCONNECT_ENV,
    DISCONNECT_POLL_SECONDS_ENV,
    ClientGoneAway,
    cancel_on_disconnect_enabled,
    disconnect_poll_seconds,
    run_unless_client_disconnects,
)


class AsgiRequest:
    """Stand-in for a real starlette Request: exposes an ASGI `receive`.

    This is the path that actually runs in production. Polling
    `is_disconnected()` silently never fires under uvicorn once the body has
    been read (`pause_reading()` takes the socket off the selector), which is
    how the first version of the fix passed its unit tests and still let the
    agent run 27s past the client abort on the live stack.
    """

    def __init__(self, disconnect_after_seconds=None, raises=False):
        self.disconnect_after_seconds = disconnect_after_seconds
        self.raises = raises
        self.receive_calls = 0

    async def receive(self):
        self.receive_calls += 1
        if self.raises:
            raise RuntimeError("ASGI receive is unusable")
        if self.disconnect_after_seconds is None:
            await asyncio.sleep(3600)  # a client that never leaves
        await asyncio.sleep(self.disconnect_after_seconds)
        return {"type": "http.disconnect"}


class FakeRequest:
    """Minimal stand-in for starlette's Request.is_disconnected()."""

    def __init__(self, disconnect_after=None, raises=False):
        self.disconnect_after = disconnect_after
        self.raises = raises
        self.polls = 0

    async def is_disconnected(self):
        self.polls += 1
        if self.raises:
            raise RuntimeError("receive channel is gone")
        if self.disconnect_after is None:
            return False
        return self.polls > self.disconnect_after


@pytest.fixture(autouse=True)
def fast_polling(monkeypatch):
    """Keep the suite quick; the floor in the module is 0.1s."""
    monkeypatch.setenv(DISCONNECT_POLL_SECONDS_ENV, "0.01")


@pytest.mark.asyncio
async def test_work_that_finishes_first_returns_its_result():
    async def work():
        await asyncio.sleep(0.01)
        return {"final_response": "moved the card"}

    result = await run_unless_client_disconnects(FakeRequest(), work())
    assert result == {"final_response": "moved the card"}


@pytest.mark.asyncio
async def test_the_agent_is_cancelled_when_the_caller_hangs_up():
    """The regression itself: without cancellation this coroutine runs to
    completion and `cancelled` stays False."""
    cancelled = asyncio.Event()

    async def long_running_agent():
        try:
            await asyncio.sleep(30)  # the five-minute tail, in miniature
            return "nobody will ever read this"
        except asyncio.CancelledError:
            cancelled.set()
            raise

    request = FakeRequest(disconnect_after=1)

    with pytest.raises(ClientGoneAway):
        await run_unless_client_disconnects(request, long_running_agent())

    assert cancelled.is_set(), "the agent kept running after the caller left"


@pytest.mark.asyncio
async def test_the_work_wins_a_tie():
    """If the answer already exists, throwing it away helps nobody."""

    async def instant():
        return "done"

    # Client is already gone, but the work needs no await point to finish.
    result = await run_unless_client_disconnects(FakeRequest(disconnect_after=0), instant())
    assert result == "done"


@pytest.mark.asyncio
async def test_the_work_own_exception_propagates_unchanged():
    """Callers keep their existing error handling (including the CRM-236
    provider classification, which must still see the original exception)."""

    class ProviderBlewUp(Exception):
        pass

    async def failing():
        raise ProviderBlewUp("429 RESOURCE_EXHAUSTED")

    with pytest.raises(ProviderBlewUp):
        await run_unless_client_disconnects(FakeRequest(), failing())


@pytest.mark.asyncio
async def test_unreadable_connection_state_never_cancels_the_work():
    """Failing to READ the state says nothing about whether the client is
    there. Being wrong here would abort healthy turns, so the guard must fail
    towards letting the work finish."""

    async def work():
        await asyncio.sleep(0.05)
        return "completed anyway"

    result = await run_unless_client_disconnects(FakeRequest(raises=True), work())
    assert result == "completed anyway"


@pytest.mark.asyncio
async def test_operator_can_switch_the_behaviour_off(monkeypatch):
    monkeypatch.setenv(CANCEL_ON_DISCONNECT_ENV, "false")
    assert cancel_on_disconnect_enabled() is False

    finished = asyncio.Event()

    async def work():
        await asyncio.sleep(0.05)
        finished.set()
        return "old behaviour"

    request = FakeRequest(disconnect_after=0)
    result = await run_unless_client_disconnects(request, work())

    assert result == "old behaviour"
    assert finished.is_set()
    assert request.polls == 0, "polling should not happen when disabled"


@pytest.mark.asyncio
async def test_the_watcher_never_outlives_the_request():
    """A watcher left running per request is a slow leak under load."""
    request = FakeRequest()

    async def work():
        return "ok"

    before = len(asyncio.all_tasks())
    await run_unless_client_disconnects(request, work())
    await asyncio.sleep(0.02)  # let the cancellation settle
    assert len(asyncio.all_tasks()) <= before


# --- the ASGI path, which is what production actually uses -------------------

@pytest.mark.asyncio
async def test_asgi_disconnect_event_cancels_the_agent():
    """The live-stack regression: this is the object shape uvicorn hands us."""
    cancelled = asyncio.Event()

    async def long_running_agent():
        try:
            await asyncio.sleep(30)
            return "nobody will ever read this"
        except asyncio.CancelledError:
            cancelled.set()
            raise

    request = AsgiRequest(disconnect_after_seconds=0.02)

    with pytest.raises(ClientGoneAway):
        await run_unless_client_disconnects(request, long_running_agent())

    assert cancelled.is_set()
    assert request.receive_calls == 1


@pytest.mark.asyncio
async def test_receive_is_preferred_over_polling():
    """A real Request has BOTH. Picking is_disconnected() is the bug."""

    class BothRequest(AsgiRequest):
        def __init__(self):
            super().__init__(disconnect_after_seconds=0.02)
            self.polls = 0

        async def is_disconnected(self):
            self.polls += 1
            return False  # what uvicorn really answers: never True

    request = BothRequest()

    async def work():
        await asyncio.sleep(30)

    with pytest.raises(ClientGoneAway):
        await run_unless_client_disconnects(request, work())

    assert request.receive_calls == 1
    assert request.polls == 0, "polling was used and it does not work under uvicorn"


@pytest.mark.asyncio
async def test_a_broken_receive_falls_back_to_polling():
    """Degrade to the old mechanism rather than losing detection entirely."""

    class BrokenReceive(FakeRequest):
        async def receive(self):
            raise RuntimeError("ASGI receive is unusable")

    request = BrokenReceive(disconnect_after=1)

    async def work():
        await asyncio.sleep(30)

    with pytest.raises(ClientGoneAway):
        await run_unless_client_disconnects(request, work())

    assert request.polls >= 1


@pytest.mark.asyncio
async def test_a_client_that_stays_never_triggers_cancellation():
    """The watcher must not mistake silence for a disconnect."""

    async def work():
        await asyncio.sleep(0.02)
        return "answered normally"

    result = await run_unless_client_disconnects(AsgiRequest(), work())
    assert result == "answered normally"


def test_defaults_are_on_and_the_poll_interval_has_a_floor(monkeypatch):
    monkeypatch.delenv(CANCEL_ON_DISCONNECT_ENV, raising=False)
    assert cancel_on_disconnect_enabled() is True

    # A typo must not turn the watcher into a busy loop.
    monkeypatch.setenv(DISCONNECT_POLL_SECONDS_ENV, "0")
    assert disconnect_poll_seconds() == 0.1

    monkeypatch.setenv(DISCONNECT_POLL_SECONDS_ENV, "not-a-number")
    assert disconnect_poll_seconds() == 1.0
