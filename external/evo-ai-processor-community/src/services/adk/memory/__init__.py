"""
Memory service module for managing agent session memories.

This module now only provides the MemoryLimitExceeded exception and MemoryRetentionMixin
for backward compatibility. All memory operations are handled via HTTP through the
knowledge microservice.
"""

from .memory_retention_mixin import MemoryRetentionMixin, MemoryLimitExceeded

__all__ = [
    "MemoryRetentionMixin",
    "MemoryLimitExceeded",
]
