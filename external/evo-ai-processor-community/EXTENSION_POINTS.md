# Extension Points

Each extension point below is versioned independently under SemVer; see
the [Compatibility Promise](#compatibility-promise) and the per-EP
`Version` lines. The document itself is not versioned — there is no
single aggregate "contract version".

This document is the public contract between `evo-ai-processor-community`
and any external consumer that wants to plug into agent execution
without forking or patching community source. The authoritative
architectural decision behind this contract is **ADR13 — Extension
Points Versioning Strategy**; the rules below are self-contained.

The community release is fully usable on its own. Every extension point
ships with a working default; a consumer can **replace** the default
implementation of one or more of them without modifying files in `src/`
or `migrations/`.

If you are about to change any of the three extension points below, read
the [Compatibility Promise](#compatibility-promise) first.

---

## Compatibility Promise

Each extension point is versioned independently and treated as a public
API, with the same backward-compatibility rules as the HTTP endpoints
exposed by this service:

- **Backward compatibility is forever.** Once shipped at a given major,
  the name, arguments, return shape and observable behavior of an
  extension point do not change silently.
- **Breaking changes require a major bump** of the affected extension
  point and of the community release that ships it.
- **Deprecation window is at least one minor release.** The old shape
  keeps working alongside the new one, and the deprecated path emits a
  `DeprecationWarning` via `warnings.warn`.
- **Additive changes are minor bumps.** New extension point, or new
  optional capability on an existing one.
- **Bug fixes that preserve the contract are patch bumps.**

Bumping one extension point does not bump the others.

---

## Registration API

**Version:** `1.0.0`

The registration mechanism is itself part of the public contract. Every
override goes through one function:

```python
def replace(name: str, impl: object) -> None: ...
```

**Accepted `name` values (v1.0.0):** `"capability_gate"`,
`"runtime_context"`, `"usage_reporter"`. Adding a new accepted name is
a minor bump; removing or renaming an accepted name is a major bump.

**`impl` contract:** any object whose attributes satisfy the
`typing.Protocol` declared for that extension point. The implementation
is structurally type-checked at registration time; passing an object
that does not satisfy the Protocol raises `TypeError` synchronously.

**Idempotency / replacement order:** `replace` is last-write-wins. Each
call replaces the previously registered implementation atomically. The
returned value is `None`; callers that need the previous implementation
should capture it before calling `replace`.

**When it may be called:** any time before the first call site that
exercises the extension point. The recommended placement is application
boot (a single `install_extension_points()` function called from the
FastAPI lifespan, before the first request is served). Calling
`replace` after the EP has been exercised is allowed and atomic, but
in-flight calls observe the previous implementation.

**Thread / async safety:** `replace` is safe to call from any thread
and from inside an async coroutine. Reads of the active implementation
are lock-free.

**Failure modes:**
- Unknown `name` → `KeyError`.
- `impl` does not satisfy the Protocol → `TypeError`.
- `impl` is `None` → `TypeError` (use a distinct reset helper, not
  `replace`).

A complementary helper, `evo_extension_points.reset(name: str) -> None`,
restores the community default for a given extension point. Calling
`reset` with an unknown name raises `KeyError`.

---

## Extension points

All three are exposed under the `evo_extension_points` package,
implemented by `src/evo_extension_points/` (shipped in a complementary
story). Contracts are declared as `typing.Protocol` so that consumers
get static type checking without inheritance. Each extension point
exposes its own version as `<extension_point>.VERSION` (e.g.
`evo_extension_points.capability_gate.VERSION == "1.0.0"`); there is
no aggregate `EXTENSION_POINTS_VERSION` constant — version each EP
independently.

### 1. `capability_gate`

**Version:** `1.0.0`
**Default:** always returns `True`; the community release does not
filter capabilities.

```python
from typing import Protocol

class CapabilityGate(Protocol):
    def is_enabled(self, capability: str, *, context: dict | None = None) -> bool: ...
```

Default access:

```python
from evo_extension_points import capability_gate

capability_gate.is_enabled("vision", context={"model": "gpt-4o"})  # => True
```

Override:

```python
import evo_extension_points

class MyCapabilityGate:
    def is_enabled(self, capability: str, *, context: dict | None = None) -> bool:
        return my_consumer.capabilities.enabled(capability, context=context)

evo_extension_points.replace("capability_gate", MyCapabilityGate())
```

**Breaking-change policy:** renaming `is_enabled`, adding a required
positional argument, or changing the return type from `bool` is a major
bump. Adding a new key to `context` or a new accepted `capability`
string is a minor bump.

### 2. `runtime_context`

**Version:** `1.0.0`
**Default:** `current_context_id` returns `None`; `with_context` yields
the callable's result without binding any state (single-scope mode).

```python
from typing import Protocol, Callable, TypeVar

T = TypeVar("T")

class RuntimeContext(Protocol):
    def current_context_id(self, request) -> str | None: ...
    def with_context(self, context_id: str, fn: Callable[[], T]) -> T: ...
```

`request` is the framework-native request object (FastAPI / Starlette
`Request`). The default implementation reads no headers and binds no
state; consumers wire their own resolution from a neutral header such as
`X-Operational-Context`.

Override:

```python
import evo_extension_points
from my_consumer import current_context

class MyRuntimeContext:
    def current_context_id(self, request) -> str | None:
        return request.headers.get("X-Operational-Context")

    def with_context(self, context_id, fn):
        with current_context.bound(context_id):
            return fn()

evo_extension_points.replace("runtime_context", MyRuntimeContext())
```

**Breaking-change policy:** renaming `current_context_id` /
`with_context`, or changing the return type of `current_context_id`
from `str | None`, is a major bump. Adding sibling helpers is a minor
bump.

### 3. `usage_reporter`

**Version:** `1.0.0`
**Default:** no-op. The community release always persists each
execution into `evo_agent_processor_execution_metrics` locally and
then calls `report_execution` once with the same data, regardless of
which implementation is installed; the default implementation discards
the call. An external consumer registers a non-default implementation
to mirror the local table into external observability.

```python
from dataclasses import dataclass
from typing import Protocol

@dataclass(frozen=True)
class ExecutionMetrics:
    execution_id: str
    prompt_tokens: int
    candidate_tokens: int
    total_tokens: int
    cost: float

class UsageReporter(Protocol):
    def report_execution(self, metrics: ExecutionMetrics) -> None: ...
```

`execution_id` is the neutral identifier of the agent execution emitted
by the processor; consumers correlate it back to their own systems.
`cost` is the monetary value (`float`) already computed by the processor
in its base currency.

**Call site and threading model:** the processor invokes
`report_execution` inline at the end of the agent execution
coroutine, on the FastAPI event loop. The override therefore runs on
the event loop; a blocking implementation will block other requests
served by the same worker. Consumers MUST keep the call non-blocking:
either return immediately and enqueue the work elsewhere
(`asyncio.create_task`, a background queue, a sidecar), or offload
synchronous work via `asyncio.to_thread`. The Protocol is declared
synchronous at v1.0.0; converting it to `async def` is a major bump.

Exceptions raised by `report_execution` are caught and logged at
`WARNING` by the processor and do not abort the agent execution or
the parent HTTP response — the local persistence into
`evo_agent_processor_execution_metrics` is already committed by then.

Override:

```python
import evo_extension_points
from evo_extension_points import ExecutionMetrics

class MyUsageReporter:
    def report_execution(self, metrics: ExecutionMetrics) -> None:
        my_consumer.metrics.publish(
            execution_id=metrics.execution_id,
            tokens=metrics.total_tokens,
            cost=metrics.cost,
        )

evo_extension_points.replace("usage_reporter", MyUsageReporter())
```

**Breaking-change policy:** renaming `report_execution`, removing or
retyping a field of `ExecutionMetrics`, or changing the call from
synchronous to asynchronous semantics is a major bump. Adding new
optional fields to `ExecutionMetrics` (with a sane default) is a minor
bump.

---

## How to use as a consumer

A consumer wires its replacements once, from its own bootstrap module,
and never patches files inside `evo-ai-processor-community`:

```python
import evo_extension_points
from evo_extension_points import ExecutionMetrics

class MyCapabilityGate:
    def is_enabled(self, capability: str, *, context: dict | None = None) -> bool:
        return my_consumer.capabilities.enabled(capability, context=context)

class MyRuntimeContext:
    def current_context_id(self, request) -> str | None:
        return request.headers.get("X-Operational-Context")

    def with_context(self, context_id, fn):
        with my_consumer.current_context.bound(context_id):
            return fn()

class MyUsageReporter:
    def report_execution(self, metrics: ExecutionMetrics) -> None:
        my_consumer.metrics.publish(
            execution_id=metrics.execution_id,
            tokens=metrics.total_tokens,
            cost=metrics.cost,
        )

def install_extension_points() -> None:
    evo_extension_points.replace("capability_gate", MyCapabilityGate())
    evo_extension_points.replace("runtime_context", MyRuntimeContext())
    evo_extension_points.replace("usage_reporter", MyUsageReporter())
```

A consumer is expected to declare the community version range it
supports in its own package metadata (`pyproject.toml`). A future CI
workflow (`extension-points-contract`) will run a neutral consumer
stub against every community PR and fail the build on a contract
break; until that workflow lands, contract regressions are caught by
manual review of changes to this file and the
`src/evo_extension_points/` implementation.

---

## Cross-references

- Companion contract on the CRM side:
  [evo-ai-crm-community/EXTENSION_POINTS.md](https://github.com/evolution-foundation/evo-ai-crm-community/blob/main/EXTENSION_POINTS.md).
- Companion contract on the auth-service side:
  [evo-auth-service-community/EXTENSION_POINTS.md](https://github.com/evolution-foundation/evo-auth-service-community/blob/main/EXTENSION_POINTS.md).
- The architectural decision that motivates this contract is **ADR13 —
  Extension Points Versioning Strategy**.

---

## Versioning history

Each line below tracks one independently versioned surface. The
document itself is unversioned.

- Registration API `1.0.0` — Initial: `replace(name, impl)` +
  `reset(name)`.
- `capability_gate` `1.0.0` — Initial contract.
- `runtime_context` `1.0.0` — Initial contract.
- `usage_reporter` `1.0.0` — Initial contract.
