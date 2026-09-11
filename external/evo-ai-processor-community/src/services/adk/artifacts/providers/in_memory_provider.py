"""
In-memory artifact service provider.

This provider creates an in-memory artifact service, which is useful
for development, testing, and as a fallback when other services are unavailable.
"""

import os

from .base_provider import BaseArtifactProvider, ProviderConfig
from google.adk.artifacts.base_artifact_service import BaseArtifactService
from src.utils.logger import setup_logger

logger = setup_logger(__name__)


class InMemoryProviderConfig(ProviderConfig):
    """Configuration for in-memory artifact service provider."""

    def __init__(self):
        # Always enabled as fallback
        super().__init__(enabled=True)

    def is_configured(self) -> bool:
        """In-memory service is always configured."""
        return True

    def validate(self) -> bool:
        """In-memory service configuration is always valid."""
        return True


class InMemoryArtifactProvider(BaseArtifactProvider):
    """In-memory artifact service provider."""

    def __init__(self):
        config = InMemoryProviderConfig()
        super().__init__(
            name="in_memory", config=config, priority=1000
        )  # Lowest priority (fallback)

    def is_available(self) -> bool:
        """In-memory service is always available."""
        try:
            # Check if the in-memory service is available
            from google.adk.artifacts.in_memory_artifact_service import (
                InMemoryArtifactService,
            )

            return True
        except ImportError:
            logger.warning("InMemoryArtifactService not available")
            return False

    def create_service(self, bucket_name: str) -> BaseArtifactService:
        """Create an in-memory artifact service instance."""
        from google.adk.artifacts.in_memory_artifact_service import (
            InMemoryArtifactService,
        )

        logger.info(
            f"Creating InMemoryArtifactService (bucket name ignored: {bucket_name})"
        )
        return InMemoryArtifactService()
