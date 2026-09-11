"""Unit tests for SafeJSONResponse — EVO-972.

The processor regresses on set-typed fields emitted by third-party Pydantic
models (Google ADK events carry `artifact_delta` and similar Set[...] fields).
Stock JSONResponse raises ``TypeError: Object of type set is not JSON
serializable`` and the route 500s. SafeJSONResponse pre-encodes every payload
through FastAPI's ``jsonable_encoder`` with custom set/frozenset handlers, so
the whole processor API stays set-safe by construction.
"""

from __future__ import annotations

import json

import pytest

from src.utils.json_encoder import SafeJSONResponse, _encode_set_as_list


def _render_payload(payload):
    """Render a payload the same way Starlette does and parse the bytes back."""
    response = SafeJSONResponse(content=payload)
    return json.loads(response.body)


class TestSafeJSONResponseSetHandling:
    def test_top_level_set_is_rendered_as_list(self) -> None:
        body = _render_payload({"tags": {"a", "b", "c"}})
        assert sorted(body["tags"]) == ["a", "b", "c"]

    def test_frozenset_is_rendered_as_list(self) -> None:
        body = _render_payload({"tags": frozenset({"x", "y"})})
        assert sorted(body["tags"]) == ["x", "y"]

    def test_nested_set_in_dict_in_list(self) -> None:
        payload = {
            "events": [
                {"artifact_delta": {"alpha", "beta"}},
                {"artifact_delta": set()},
            ]
        }
        body = _render_payload(payload)
        assert sorted(body["events"][0]["artifact_delta"]) == ["alpha", "beta"]
        assert body["events"][1]["artifact_delta"] == []

    def test_set_inside_list_inside_list(self) -> None:
        # Regression guard for the review #5 edge case: nested lists with
        # sets at the leaf. jsonable_encoder walks into nested lists, so this
        # must hold for SafeJSONResponse even when process_dict is bypassed.
        payload = {"rows": [[{"tags": {"a", "b"}}]]}
        body = _render_payload(payload)
        assert sorted(body["rows"][0][0]["tags"]) == ["a", "b"]

    def test_mixed_set_and_non_set_payload_preserves_other_values(self) -> None:
        payload = {"id": 42, "tags": {"a"}, "active": True}
        body = _render_payload(payload)
        assert body["id"] == 42
        assert body["active"] is True
        assert body["tags"] == ["a"]


class TestEncodeSetAsList:
    def test_sorts_homogeneous_strings(self) -> None:
        assert _encode_set_as_list({"c", "a", "b"}) == ["a", "b", "c"]

    def test_falls_back_to_list_when_unsortable(self) -> None:
        # Mixed types trigger TypeError under `sorted(..., key=None)` because
        # comparisons across types fail. The composite key in
        # `_encode_set_as_list` tolerates that by keying on (type name, str(value)).
        out = _encode_set_as_list({1, "a", (1, 2)})
        assert isinstance(out, list)
        assert len(out) == 3

    def test_empty_set_returns_empty_list(self) -> None:
        assert _encode_set_as_list(set()) == []


class TestSafeJSONResponseStatusCode:
    def test_honors_custom_status_code(self) -> None:
        response = SafeJSONResponse(status_code=503, content={"tags": {"a"}})
        assert response.status_code == 503
        assert sorted(json.loads(response.body)["tags"]) == ["a"]
