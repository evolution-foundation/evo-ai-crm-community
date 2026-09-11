"""CapabilityGate extension point.

Community default: every capability is enabled. A consumer overrides via
``evo_extension_points.replace("capability_gate", impl)`` where ``impl``
is any object whose attributes satisfy the ``CapabilityGate`` Protocol.
"""

from __future__ import annotations

from typing import Any, Protocol, runtime_checkable

from . import registry

VERSION: str = "1.0.0"


@runtime_checkable
class CapabilityGate(Protocol):
    def is_enabled(
        self, capability: str, *, context: dict[str, Any] | None = None
    ) -> bool: ...


class _DefaultCapabilityGate:
    def is_enabled(
        self, capability: str, *, context: dict[str, Any] | None = None
    ) -> bool:
        return True


_DEFAULT = _DefaultCapabilityGate()
registry._register_protocol("capability_gate", CapabilityGate)


def is_enabled(capability: str, *, context: dict[str, Any] | None = None) -> bool:
    impl = registry.impl_for("capability_gate") or _DEFAULT
    return impl.is_enabled(capability, context=context)
