"""Tests for the public extension point package (EVO-1382).

Validates the contract published in EXTENSION_POINTS.md at v1.0.0:
Registration API failure modes, per-EP defaults and override path,
per-EP VERSION constants and the absence of an aggregate version.
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


# ----------------------------- Registration API -----------------------------


class TestReplace:
    def test_unknown_name_raises_keyerror(self):
        with pytest.raises(KeyError):
            evo_extension_points.replace("not_a_thing", object())

    def test_none_impl_raises_typeerror(self):
        with pytest.raises(TypeError):
            evo_extension_points.replace("capability_gate", None)

    def test_impl_not_satisfying_protocol_raises_typeerror(self):
        class WrongShape:
            def something_else(self):
                return True

        with pytest.raises(TypeError):
            evo_extension_points.replace("capability_gate", WrongShape())

    def test_returns_none(self):
        class Gate:
            def is_enabled(self, capability, *, context=None):
                return True

        assert evo_extension_points.replace("capability_gate", Gate()) is None

    def test_last_write_wins(self):
        class GateA:
            def is_enabled(self, capability, *, context=None):
                return False

        class GateB:
            def is_enabled(self, capability, *, context=None):
                return True

        a = GateA()
        b = GateB()
        evo_extension_points.replace("capability_gate", a)
        evo_extension_points.replace("capability_gate", b)
        assert evo_extension_points.impl_for("capability_gate") is b


class TestReset:
    def test_unknown_name_raises_keyerror(self):
        with pytest.raises(KeyError):
            evo_extension_points.reset("not_a_thing")

    def test_clears_only_named_extension_point(self):
        class Gate:
            def is_enabled(self, capability, *, context=None):
                return False

        class Reporter:
            def report_execution(self, metrics):
                pass

        evo_extension_points.replace("capability_gate", Gate())
        evo_extension_points.replace("usage_reporter", Reporter())
        evo_extension_points.reset("capability_gate")
        assert evo_extension_points.impl_for("capability_gate") is None
        assert evo_extension_points.impl_for("usage_reporter") is not None


class TestNoAggregateVersion:
    def test_no_aggregate_constant(self):
        assert not hasattr(evo_extension_points, "EXTENSION_POINTS_VERSION")

    def test_per_ep_versions(self):
        assert capability_gate.VERSION == "1.0.0"
        assert runtime_context.VERSION == "1.0.0"
        assert usage_reporter.VERSION == "1.0.0"


# ----------------------------- CapabilityGate -----------------------------


class TestCapabilityGate:
    def test_default_returns_true_for_any_capability(self):
        assert capability_gate.is_enabled("vision") is True
        assert capability_gate.is_enabled("anything", context={"k": "v"}) is True

    def test_override_is_called(self):
        class Custom:
            def __init__(self):
                self.calls = []

            def is_enabled(self, capability, *, context=None):
                self.calls.append((capability, context))
                return capability == "ok"

        custom = Custom()
        evo_extension_points.replace("capability_gate", custom)
        assert capability_gate.is_enabled("ok", context={"k": "v"}) is True
        assert capability_gate.is_enabled("other") is False
        assert custom.calls == [("ok", {"k": "v"}), ("other", None)]


# ----------------------------- RuntimeContext -----------------------------


class TestRuntimeContext:
    def test_default_current_context_id_returns_none(self):
        assert runtime_context.current_context_id() is None
        assert runtime_context.current_context_id({"X": "abc"}) is None

    def test_default_with_context_yields_fn_result(self):
        called = []

        def work():
            called.append("ran")
            return "payload"

        result = runtime_context.with_context("ctx-1", work)
        assert result == "payload"
        assert called == ["ran"]

    def test_override_resolves_from_mapping(self):
        class Custom:
            def current_context_id(self, source):
                if isinstance(source, dict):
                    return source.get("X-Operational-Context")
                return None

            def with_context(self, context_id, fn):
                return f"{context_id}:{fn()}"

            @asynccontextmanager
            async def bind_context(self, context_id):
                yield

        evo_extension_points.replace("runtime_context", Custom())
        assert (
            runtime_context.current_context_id({"X-Operational-Context": "abc"})
            == "abc"
        )
        assert runtime_context.with_context("ctx-2", lambda: "done") == "ctx-2:done"


# ----------------------------- UsageReporter -----------------------------


class TestUsageReporter:
    def test_default_is_noop(self):
        metrics = ExecutionMetrics(
            execution_id="exec-1",
            prompt_tokens=10,
            candidate_tokens=20,
            total_tokens=30,
            cost=0.0,
        )
        assert usage_reporter.report_execution(metrics) is None

    def test_override_receives_metrics(self):
        seen = []

        class Reporter:
            def report_execution(self, metrics):
                seen.append(metrics)

        evo_extension_points.replace("usage_reporter", Reporter())
        metrics = ExecutionMetrics(
            execution_id="exec-42",
            prompt_tokens=100,
            candidate_tokens=200,
            total_tokens=300,
            cost=1.23,
        )
        usage_reporter.report_execution(metrics)
        assert seen == [metrics]


class TestExecutionMetricsDataclass:
    def test_is_frozen(self):
        metrics = ExecutionMetrics(
            execution_id="exec-1",
            prompt_tokens=1,
            candidate_tokens=1,
            total_tokens=2,
            cost=0.0,
        )
        with pytest.raises(AttributeError):
            metrics.cost = 9.99  # type: ignore[misc]
