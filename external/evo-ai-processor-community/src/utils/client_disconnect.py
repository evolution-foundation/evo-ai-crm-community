"""
Stop running an agent once nobody is waiting for the answer.

CRM-236: bot-runtime closes the A2A connection at its own ceiling and the
processor kept working for another five minutes, burning the same quota whose
exhaustion caused the timeout. `run_unless_client_disconnects` races the work
against the ASGI disconnect signal and cancels it when the client is gone.
"""

import asyncio
import os
from typing import Any, Awaitable, Optional

from src.utils.logger import setup_logger

logger = setup_logger(__name__)

CANCEL_ON_DISCONNECT_ENV = "A2A_CANCEL_ON_DISCONNECT"
DISCONNECT_POLL_SECONDS_ENV = "A2A_DISCONNECT_POLL_SECONDS"

_DEFAULT_POLL_SECONDS = 1.0


class ClientGoneAway(Exception):
    """Raised when the caller hung up before the work finished."""


def _flag_enabled(raw: Optional[str], default: bool) -> bool:
    if raw is None or raw.strip() == "":
        return default
    return raw.strip().lower() in ("1", "true", "yes", "on")


def cancel_on_disconnect_enabled() -> bool:
    """On by default; an operator can restore the old behaviour."""
    return _flag_enabled(os.getenv(CANCEL_ON_DISCONNECT_ENV), True)


def disconnect_poll_seconds() -> float:
    """Polling interval, floored so a typo cannot busy-loop the event loop."""
    raw = os.getenv(DISCONNECT_POLL_SECONDS_ENV)
    if not raw:
        return _DEFAULT_POLL_SECONDS
    try:
        value = float(raw)
    except ValueError:
        logger.warning(
            f"invalid {DISCONNECT_POLL_SECONDS_ENV}={raw!r}; "
            f"using {_DEFAULT_POLL_SECONDS}s"
        )
        return _DEFAULT_POLL_SECONDS
    return max(0.1, value)


async def _watch_via_receive(receive: Any) -> bool:
    """Await the ASGI `http.disconnect` message. Preferred detection path.

    Polling `is_disconnected()` does not work: once the body is read uvicorn
    calls `transport.pause_reading()`, the socket leaves the selector, the peer's
    FIN is never noticed and it answers False forever. Awaiting `receive()`
    triggers `resume_reading()` and the disconnect arrives as an event. Safe with
    respect to the body — the handler has already consumed it.
    """
    while True:
        message = await receive()
        if message.get("type") == "http.disconnect":
            return True
        # Anything else (a late/duplicated http.request) is not our business.


async def _watch_via_polling(request: Any, poll_seconds: float) -> bool:
    """Fallback for request objects that expose no ASGI `receive`.

    Never returns True on its own error: failing to *read* the state says
    nothing about whether the client is there, and being wrong in that
    direction would abort healthy turns.
    """
    consecutive_errors = 0
    while True:
        try:
            if await request.is_disconnected():
                return True
            consecutive_errors = 0
        except Exception as exc:
            consecutive_errors += 1
            if consecutive_errors == 1:
                logger.warning(f"could not read client connection state: {exc}")
            if consecutive_errors >= 5:
                logger.warning("giving up on disconnect detection for this request")
                return False
        await asyncio.sleep(poll_seconds)


async def _watch_for_disconnect(request: Any, poll_seconds: float) -> bool:
    """True once the client is gone; False if detection had to give up."""
    receive = getattr(request, "receive", None)
    if callable(receive):
        try:
            return await _watch_via_receive(receive)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            logger.warning(
                f"disconnect detection via receive() failed ({exc}); "
                "falling back to polling"
            )
    if hasattr(request, "is_disconnected"):
        return await _watch_via_polling(request, poll_seconds)
    logger.warning("request exposes no way to detect a disconnect")
    return False


async def run_unless_client_disconnects(
    request: Any,
    coro: Awaitable[Any],
    *,
    label: str = "agent execution",
) -> Any:
    """Await `coro`, cancelling it if the client disconnects first.

    Raises ClientGoneAway after cancelling. The work's own exceptions propagate
    unchanged, so callers keep their existing error handling.
    """
    task = asyncio.ensure_future(coro)

    if not cancel_on_disconnect_enabled():
        return await task

    watcher = asyncio.ensure_future(
        _watch_for_disconnect(request, disconnect_poll_seconds())
    )

    try:
        done, _ = await asyncio.wait(
            {task, watcher}, return_when=asyncio.FIRST_COMPLETED
        )

        # The work finishing wins even if both completed on the same tick:
        # we have a real answer, so there is nothing to gain by discarding it.
        if task in done:
            return task.result()

        # The watcher gave up (it could not read the state) rather than
        # detecting a disconnect — keep waiting for the work.
        if not watcher.result():
            return await task

        logger.warning(
            f"[CRM-236] client disconnected before {label} finished; cancelling it"
        )
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass
        except Exception as exc:
            # The work failed on its way down. It is being discarded anyway, so
            # this is a log line, not an error to raise over ClientGoneAway.
            logger.warning(f"[CRM-236] cancelled {label} raised on teardown: {exc}")
        raise ClientGoneAway(f"client disconnected before {label} finished")
    finally:
        if not watcher.done():
            watcher.cancel()
