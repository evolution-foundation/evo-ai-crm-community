"""
Artifact service providers package.

This package provides a registry-based system for managing different
artifact service providers with automatic fallback and priority selection.
"""

from .registry import (
    get_registry,
    create_artifact_service,
    ArtifactProviderRegistry,
)
from .base_provider import (
    BaseArtifactProvider,
    ProviderConfig,
)

# Import providers conditionally to avoid import errors
try:
    from .minio_provider import MinIOArtifactProvider, MinIOProviderConfig

    MINIO_AVAILABLE = True
except ImportError:
    MinIOArtifactProvider = None
    MinIOProviderConfig = None
    MINIO_AVAILABLE = False

try:
    from .in_memory_provider import InMemoryArtifactProvider, InMemoryProviderConfig

    IN_MEMORY_AVAILABLE = True
except ImportError:
    InMemoryArtifactProvider = None
    InMemoryProviderConfig = None
    IN_MEMORY_AVAILABLE = False

__all__ = [
    "get_registry",
    "create_artifact_service",
    "ArtifactProviderRegistry",
    "BaseArtifactProvider",
    "ProviderConfig",
]

# Add MinIO exports if available
if MINIO_AVAILABLE:
    __all__.extend(["MinIOArtifactProvider", "MinIOProviderConfig"])

# Add in-memory exports if available
if IN_MEMORY_AVAILABLE:
    __all__.extend(["InMemoryArtifactProvider", "InMemoryProviderConfig"])
