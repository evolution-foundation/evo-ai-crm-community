"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Nickolas Oliveira                                                   │
│ @file: json_encoder.py                                                       │
│ Creation date: April 23, 2026                                                │
├──────────────────────────────────────────────────────────────────────────────┤
│ Stock Starlette `JSONResponse` uses `json.dumps` directly, which raises      │
│ TypeError on Python `set` / `frozenset` — those leak in via third-party      │
│ Pydantic models (e.g. Google ADK `event.model_dump()` where a field is       │
│ typed as `Set[...]`). `SafeJSONResponse` pre-encodes the payload through     │
│ FastAPI's `jsonable_encoder` with a custom handler that converts sets to     │
│ lists before the standard render. Every response helper in `response.py`     │
│ routes through this class, so the whole processor API is set-safe by        │
│ construction rather than by defensive cleanup at every call site.            │
└──────────────────────────────────────────────────────────────────────────────┘
"""

from typing import Any

from fastapi.encoders import jsonable_encoder
from fastapi.responses import JSONResponse


def _encode_set_as_list(value) -> list:
    try:
        return sorted(value, key=lambda item: (type(item).__name__, str(item)))
    except TypeError:
        return list(value)


class SafeJSONResponse(JSONResponse):
    def render(self, content: Any) -> bytes:
        encoded = jsonable_encoder(
            content,
            custom_encoder={
                set: _encode_set_as_list,
                frozenset: _encode_set_as_list,
            },
        )
        return super().render(encoded)
