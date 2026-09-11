"""
Artifact service module for managing agent artifacts.

This module provides a factory pattern for creating different types of
artifact services (MinIO, in-memory, etc.) with automatic fallback.
"""

from .artifact_factory import ArtifactServiceFactory, get_artifact_service

# Import MinIO service conditionally to avoid import errors
try:
    from .minio_artifact_service import MinIOArtifactService

    MINIO_AVAILABLE = True
except ImportError:
    MinIOArtifactService = None
    MINIO_AVAILABLE = False

# Import the new provider system
from .providers import (
    get_registry,
    create_artifact_service as create_service_from_registry,
    BaseArtifactProvider,
    ProviderConfig,
)

__all__ = [
    "ArtifactServiceFactory",
    "get_artifact_service",
    # New provider system
    "get_registry",
    "create_service_from_registry",
    "BaseArtifactProvider",
    "ProviderConfig",
]

# Add MinIO exports if available
if MINIO_AVAILABLE:
    __all__.extend(["MinIOArtifactService"])
