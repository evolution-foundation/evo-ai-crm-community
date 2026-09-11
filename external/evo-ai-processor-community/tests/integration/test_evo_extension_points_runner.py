"""Call-site shape tests mirroring the three hooks wired in
``StandardRunner.run_agent``.

The full runner cannot be exercised in a unit test (it requires
``google.adk``, a DB session, an LLM client). These tests reproduce the
exact call-shape used by the runner so that a future change to the
runner's hook arguments would be caught by re-reading both files
together. Treat as regression guard, not as runner end-to-end coverage.
"""

from __future__ import annotations

from contextlib import asynccontextmanager

import pytest

from src import evo_extension_points
from src.evo_extension_points import (
    ExecutionMetrics,
    capability_gate,
    runtime_context,
    usage_reporter,
)


@pytest.fixture(autouse=True)
def _reset_all():
    for key in evo_extension_points.KNOWN_KEYS:
        evo_extension_points.reset(key)
    yield
    for key in evo_extension_points.KNOWN_KEYS:
        evo_extension_points.reset(key)


def _mirror_runner_hooks(metadata: dict | None) -> dict:
    """Mirror the three hook call sites in standard_runner.run_agent."""
    capability = (metadata or {}).get("capability")
    if capability and not capability_gate.is_enabled(capability, context=metadata):
        return {
            "error": "capability_denied",
            "capability": capability,
            "message_history": [],
        }

    context_id = runtime_context.current_context_id(metadata)

    try:
        usage_reporter.report_execution(
            ExecutionMetrics(
                execution_id="adk-session-1",
                prompt_tokens=10,
                candidate_tokens=20,
                total_tokens=30,
                cost=0.0,
            )
        )
        reported = True
    except Exception:
        reported = False

    return {"context_id": context_id, "reported": reported}


class TestDefaults:
    def test_defaults_do_not_block_execution(self):
        result = _mirror_runner_hooks({"capability": "vision"})
        assert "error" not in result
        assert result == {"context_id": None, "reported": True}

    def test_no_metadata_is_safe(self):
        result = _mirror_runner_hooks(None)
        assert "error" not in result
        assert result["context_id"] is None
        assert result["reported"] is True


class TestCapabilityDenialIsStructured:
    def test_denial_returns_structured_error_not_fake_response(self):
        class DenyGate:
            def is_enabled(self, capability, *, context=None):
                return False

        evo_extension_points.replace("capability_gate", DenyGate())
        result = _mirror_runner_hooks({"capability": "blocked"})
        assert result["error"] == "capability_denied"
        assert result["capability"] == "blocked"
        assert "final_response" not in result


class TestRuntimeContextOverride:
    def test_resolves_id_from_metadata_mapping(self):
        class IdFromMetadata:
            def current_context_id(self, source):
                if isinstance(source, dict):
                    return source.get("operational_context")
                return None

            def with_context(self, context_id, fn):
                return fn()

            @asynccontextmanager
            async def bind_context(self, context_id):
                yield

        evo_extension_points.replace("runtime_context", IdFromMetadata())
        result = _mirror_runner_hooks(
            {"capability": "vision", "operational_context": "ctx-77"}
        )
        assert result["context_id"] == "ctx-77"


class TestUsageReporterOverride:
    def test_receives_full_metrics(self):
        seen = []

        class Reporter:
            def report_execution(self, metrics):
                seen.append(metrics)

        evo_extension_points.replace("usage_reporter", Reporter())
        _mirror_runner_hooks({})
        assert len(seen) == 1
        assert seen[0].execution_id == "adk-session-1"
        assert seen[0].total_tokens == 30

    def test_misbehaving_reporter_is_caught(self):
        class BoomReporter:
            def report_execution(self, metrics):
                raise RuntimeError("boom")

        evo_extension_points.replace("usage_reporter", BoomReporter())
        result = _mirror_runner_hooks({})
        assert result["reported"] is False
