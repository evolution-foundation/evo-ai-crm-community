"""RuntimeContext extension point.

Community default: ``current_context_id`` returns ``None``;
``with_context`` yields the callable's result without binding any state
(single-scope mode).
"""

from __future__ import annotations

from contextlib import asynccontextmanager
from typing import Any, AsyncIterator, Callable, Protocol, TypeVar, runtime_checkable

from . import registry

VERSION: str = "1.0.0"

T = TypeVar("T")


@runtime_checkable
class RuntimeContext(Protocol):
    def current_context_id(self, source: Any) -> str | None: ...

    def with_context(self, context_id: str, fn: Callable[[], T]) -> T: ...

    def bind_context(self, context_id: str) -> AsyncIterator[None]: ...


class _DefaultRuntimeContext:
    def current_context_id(self, source: Any) -> str | None:
        return None

    def with_context(self, context_id: str, fn: Callable[[], T]) -> T:
        return fn()

    @asynccontextmanager
    async def bind_context(self, context_id: str) -> AsyncIterator[None]:
        yield


_DEFAULT = _DefaultRuntimeContext()
registry._register_protocol("runtime_context", RuntimeContext)


def current_context_id(source: Any = None) -> str | None:
    impl = registry.impl_for("runtime_context") or _DEFAULT
    return impl.current_context_id(source)


def with_context(context_id: str, fn: Callable[[], T]) -> T:
    impl = registry.impl_for("runtime_context") or _DEFAULT
    return impl.with_context(context_id, fn)


def bind_context(context_id: str) -> AsyncIterator[None]:
    impl = registry.impl_for("runtime_context") or _DEFAULT
    return impl.bind_context(context_id)
