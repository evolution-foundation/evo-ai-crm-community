"""Unit tests for ``generic_exception_handler`` — EVO-972 review CRITICAL #4.

In production we don't want to leak internal class names (e.g.
``SQLAlchemyIntegrityError``, ``httpx.ReadTimeout``) into the HTTP error
body. The handler only attaches ``details.error_class`` when
``settings.DEBUG`` is true.
"""

from __future__ import annotations

import json

import pytest
from fastapi import FastAPI, Request
from fastapi.testclient import TestClient

from src.config.settings import settings
from src.core.exception_handlers import generic_exception_handler


def _app() -> FastAPI:
    app = FastAPI()

    @app.get("/boom")
    async def boom():
        raise RuntimeError("kaboom")

    # FastAPI only dispatches `Exception` handlers when they're registered
    # explicitly on the application instance.
    app.add_exception_handler(Exception, generic_exception_handler)
    return app


@pytest.fixture
def _no_debug(monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setattr(settings, "DEBUG", False)
    yield


@pytest.fixture
def _debug(monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setattr(settings, "DEBUG", True)
    yield


class TestGenericExceptionHandler:
    def test_production_response_omits_error_class(self, _no_debug) -> None:
        client = TestClient(_app(), raise_server_exceptions=False)

        response = client.get("/boom")

        assert response.status_code == 500
        body = response.json()
        assert body["success"] is False
        assert body["error"]["code"] == "INTERNAL_ERROR"
        # No information disclosure: class name MUST NOT leak in prod.
        assert body["error"].get("details") is None

    def test_debug_response_includes_qualified_error_class(self, _debug) -> None:
        client = TestClient(_app(), raise_server_exceptions=False)

        response = client.get("/boom")

        assert response.status_code == 500
        body = response.json()
        # Builtins keep their short name; anything else gets `module.Class`.
        assert body["error"]["details"]["error_class"] == "RuntimeError"
