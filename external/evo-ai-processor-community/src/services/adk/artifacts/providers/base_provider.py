"""
Base provider class for artifact services.

This module defines the base classes for artifact service providers,
following the same pattern as memory services.
"""

from abc import ABC, abstractmethod
from typing import Optional, Dict, Any
import os

from google.adk.artifacts.base_artifact_service import BaseArtifactService


class ProviderConfig(ABC):
    """Base configuration class for artifact service providers."""

    def __init__(self, enabled: bool = True):
        self.enabled = enabled

    @abstractmethod
    def is_configured(self) -> bool:
        """Check if the provider is configured with required settings."""
        pass

    @abstractmethod
    def validate(self) -> bool:
        """Validate the provider configuration."""
        pass

    def get_config_status(self) -> Dict[str, Any]:
        """Get the configuration status."""
        return {
            "enabled": self.enabled,
            "configured": self.is_configured(),
            "valid": self.validate() if self.is_configured() else False,
        }


class BaseArtifactProvider(ABC):
    """Base class for artifact service providers."""

    def __init__(self, name: str, config: ProviderConfig, priority: int = 100):
        self.name = name
        self.config = config
        self.priority = priority  # Lower = higher priority

    @abstractmethod
    def is_available(self) -> bool:
        """Check if the provider is available (dependencies, connectivity)."""
        pass

    @abstractmethod
    def create_service(self, bucket_name: str) -> BaseArtifactService:
        """Create an artifact service instance."""
        pass

    def can_create_service(self) -> bool:
        """Check if the provider can create a service."""
        return (
            self.config.enabled
            and self.config.is_configured()
            and self.config.validate()
            and self.is_available()
        )

    def try_create_service(
        self, bucket_name: str = "default-artifacts"
    ) -> Optional[BaseArtifactService]:
        """Try to create a service, returning None if it fails."""
        try:
            if self.can_create_service():
                return self.create_service(bucket_name)
        except Exception:
            pass
        return None

    def get_status(self) -> Dict[str, Any]:
        """Get the provider status."""
        status = self.config.get_config_status()
        status.update(
            {
                "provider": self.name,
                "priority": self.priority,
                "available": False,
                "can_create": False,
            }
        )

        try:
            status["available"] = self.is_available()
            status["can_create"] = self.can_create_service()
        except Exception as e:
            status["error"] = str(e)

        return status
