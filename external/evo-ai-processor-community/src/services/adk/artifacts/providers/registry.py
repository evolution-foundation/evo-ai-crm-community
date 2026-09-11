"""
Registry for artifact service providers.

This module manages the registration and selection of artifact service providers,
providing automatic fallback and priority-based selection.
"""

from typing import List, Dict, Any, Optional
import os

from .base_provider import BaseArtifactProvider
from src.utils.logger import setup_logger

logger = setup_logger(__name__)


class ArtifactProviderRegistry:
    """Registry for managing artifact service providers."""

    def __init__(self):
        self._providers: List[BaseArtifactProvider] = []
        self._initialize_providers()

    def _initialize_providers(self):
        """Initialize and register all available providers."""
        # Register MinIO provider (highest priority for S3-compatible services)
        try:
            from .minio_provider import MinIOArtifactProvider

            self.register_provider(MinIOArtifactProvider())
        except Exception as e:
            logger.warning(f"Failed to register MinIO artifact provider: {e}")

        # Register in-memory provider (fallback)
        try:
            from .in_memory_provider import InMemoryArtifactProvider

            self.register_provider(InMemoryArtifactProvider())
        except Exception as e:
            logger.warning(f"Failed to register in-memory artifact provider: {e}")

        # Sort providers by priority (lower = higher priority)
        self._providers.sort(key=lambda p: p.priority)

    def register_provider(self, provider: BaseArtifactProvider):
        """Register a new artifact service provider."""
        self._providers.append(provider)
        logger.debug(
            f"Registered artifact provider: {provider.name} (priority: {provider.priority})"
        )

    def get_provider(self, name: str) -> Optional[BaseArtifactProvider]:
        """Get a provider by name."""
        for provider in self._providers:
            if provider.name == name:
                return provider
        return None

    def get_available_providers(self) -> List[BaseArtifactProvider]:
        """Get all providers that can create services."""
        available = []
        for provider in self._providers:
            try:
                if provider.can_create_service():
                    available.append(provider)
            except Exception as e:
                logger.debug(f"Provider {provider.name} not available: {e}")
        return available

    def get_best_provider(self) -> Optional[BaseArtifactProvider]:
        """Get the best available provider based on priority."""
        available_providers = self.get_available_providers()
        if available_providers:
            # Return the first one (highest priority)
            return available_providers[0]
        return None

    def get_provider_by_type(self, service_type: str) -> Optional[BaseArtifactProvider]:
        """Get a specific provider by service type."""
        provider = self.get_provider(service_type)
        if provider and provider.can_create_service():
            return provider
        return None

    def get_provider_status(self) -> Dict[str, Dict[str, Any]]:
        """Get status information for all providers."""
        status = {}
        for provider in self._providers:
            status[provider.name] = provider.get_status()
        return status

    def create_service(
        self, service_type: str = "auto", bucket_name: str = "artifacts"
    ) -> Optional[Any]:
        """Create an artifact service using the registry."""
        if service_type == "auto":
            provider = self.get_best_provider()
            if provider:
                logger.info(f"Auto-selected artifact provider: {provider.name}")
                return provider.create_service(bucket_name)
        else:
            provider = self.get_provider_by_type(service_type)
            if provider:
                logger.info(f"Using specified artifact provider: {provider.name}")
                return provider.create_service(bucket_name)
            else:
                logger.warning(f"Artifact provider '{service_type}' not available")

        # Fallback: try to get any available provider
        fallback_provider = self.get_best_provider()
        if fallback_provider:
            logger.warning(
                f"Falling back to artifact provider: {fallback_provider.name}"
            )
            return fallback_provider.create_service(bucket_name)

        logger.error("No artifact providers available")
        return None


# Global registry instance
_registry: Optional[ArtifactProviderRegistry] = None


def get_registry() -> ArtifactProviderRegistry:
    """Get the global artifact provider registry."""
    global _registry
    if _registry is None:
        _registry = ArtifactProviderRegistry()
    return _registry


def create_artifact_service(service_type: str = "auto", bucket_name: str = "artifacts"):
    """Create an artifact service using the provider registry."""
    registry = get_registry()
    return registry.create_service(service_type, bucket_name)
