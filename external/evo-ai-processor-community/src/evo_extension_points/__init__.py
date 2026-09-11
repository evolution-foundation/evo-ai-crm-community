"""Public extension contract of evo-ai-processor-community.

See ``EXTENSION_POINTS.md`` at the repository root for the full contract.
Each extension point is versioned independently via its own ``VERSION``
attribute; there is no aggregate version constant.
"""

from __future__ import annotations

import sys as _sys

from . import capability_gate, runtime_context, usage_reporter
from .registry import KNOWN_KEYS, impl_for, replace, reset
from .usage_reporter import ExecutionMetrics

# Public contract alias: EXTENSION_POINTS.md documents `import evo_extension_points`
# (top-level), and external consumers (e.g. the enterprise overlay package) import
# it that way. Internally this module is packaged under `src/` (pyproject
# packages=["src"], PYTHONPATH=/app), so it loads as `src.evo_extension_points`.
# Without this alias the two names resolve to TWO separate module instances → a
# consumer's `replace()` would target a registry the runtime never reads (silent
# no-op). Aliasing in sys.modules makes both names the SAME module object, so the
# registry singleton is shared regardless of import path or import order.
_sys.modules.setdefault("evo_extension_points", _sys.modules[__name__])

__all__ = [
    "ExecutionMetrics",
    "KNOWN_KEYS",
    "capability_gate",
    "impl_for",
    "replace",
    "reset",
    "runtime_context",
    "usage_reporter",
]
