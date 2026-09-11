"""In-memory override registry shared by the three extension points.

The Registration API is itself part of the public contract — see
``EXTENSION_POINTS.md`` at the repository root for the full specification.
"""

from __future__ import annotations

import threading
from typing import Any, Final

KNOWN_KEYS: Final[frozenset[str]] = frozenset(
    {"capability_gate", "runtime_context", "usage_reporter"}
)

_PROTOCOLS: dict[str, type] = {}
_registry: dict[str, Any] = {}
_lock = threading.RLock()


def _register_protocol(name: str, protocol: type) -> None:
    if name not in KNOWN_KEYS:
        raise KeyError(f"unknown extension point: {name!r}")
    _PROTOCOLS[name] = protocol


def replace(name: str, impl: object) -> None:
    if name not in KNOWN_KEYS:
        raise KeyError(f"unknown extension point: {name!r}")
    if impl is None:
        raise TypeError(
            f"impl for {name!r} must not be None; use reset({name!r}) instead"
        )
    protocol = _PROTOCOLS.get(name)
    if protocol is not None and not isinstance(impl, protocol):
        raise TypeError(
            f"impl for {name!r} does not satisfy {protocol.__name__}"
        )
    with _lock:
        _registry[name] = impl


def reset(name: str) -> None:
    if name not in KNOWN_KEYS:
        raise KeyError(f"unknown extension point: {name!r}")
    with _lock:
        _registry.pop(name, None)


def impl_for(name: str) -> Any | None:
    return _registry.get(name)
