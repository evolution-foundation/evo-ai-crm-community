"""UsageReporter extension point.

Community default: no-op. The processor always persists each execution
into ``evo_agent_processor_execution_metrics`` locally and then calls
``report_execution`` with the same data; the default discards the call.
A consumer registers a non-default implementation to mirror the local
table into external observability.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol, runtime_checkable

from . import registry

VERSION: str = "1.0.0"


@dataclass(frozen=True)
class ExecutionMetrics:
    execution_id: str
    prompt_tokens: int
    candidate_tokens: int
    total_tokens: int
    cost: float


@runtime_checkable
class UsageReporter(Protocol):
    def report_execution(self, metrics: ExecutionMetrics) -> None: ...


class _DefaultUsageReporter:
    def report_execution(self, metrics: ExecutionMetrics) -> None:
        return None


_DEFAULT = _DefaultUsageReporter()
registry._register_protocol("usage_reporter", UsageReporter)


def report_execution(metrics: ExecutionMetrics) -> None:
    impl = registry.impl_for("usage_reporter") or _DEFAULT
    impl.report_execution(metrics)
