"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: artifact_factory.py                                                   │
│ Developed by: Davidson Gomes                                                 │
│ Creation date: January 21, 2025                                              │
│ Contact: contato@evolution-api.com                                           │
├──────────────────────────────────────────────────────────────────────────────┤
│ @copyright © Evolution API 2025. All rights reserved.                        │
│ Licensed under the Apache License, Version 2.0                               │
│                                                                              │
│ You may not use this file except in compliance with the License.             │
│ You may obtain a copy of the License at                                      │
│                                                                              │
│    http://www.apache.org/licenses/LICENSE-2.0                                │
│                                                                              │
│ Unless required by applicable law or agreed to in writing, software          │
│ distributed under the License is distributed on an "AS IS" BASIS,            │
│ WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.     │
│ See the License for the specific language governing permissions and          │
│ limitations under the License.                                               │
├──────────────────────────────────────────────────────────────────────────────┤
│ @important                                                                   │
│ For any future changes to the code in this file, it is recommended to        │
│ include, together with the modification, the information of the developer    │
│ who changed it and the date of modification.                                 │
└──────────────────────────────────────────────────────────────────────────────┘
"""

import os
from typing import Dict, Any, Optional

from google.adk.artifacts.base_artifact_service import BaseArtifactService
from .providers import get_registry, create_artifact_service
from src.utils.logger import setup_logger

logger = setup_logger(__name__)


class ArtifactServiceFactory:
    """Factory for creating artifact service instances.

    This factory uses a provider registry system for better modularity and testability.
    Providers are automatically registered and prioritized based on configuration.

    Supported service types:
    - "auto": Automatic selection based on availability and priority
    - "minio": MinIO-compatible services (Backblaze B2, etc.)
    - "in_memory": In-memory storage (fallback)
    """

    @staticmethod
    def create_artifact_service(
        service_type: str = "auto", bucket_name: Optional[str] = None
    ) -> BaseArtifactService:
        """Create an artifact service instance based on the specified type.

        Args:
            service_type: Type of artifact service to create.
                         Options: "auto", "minio", "in_memory"
                         "auto" will automatically select the best available provider
            bucket_name: Name of the bucket/container to use. If None, uses default from config.

        Returns:
            BaseArtifactService: The created artifact service instance

        Raises:
            ValueError: If an unsupported service type is specified
            RuntimeError: If the specified service type cannot be created
        """
        # Validate service type
        valid_types = {"auto", "minio", "in_memory"}
        if service_type.lower() not in valid_types:
            raise ValueError(
                f"Unsupported artifact service type: {service_type}. "
                f"Valid options: {', '.join(valid_types)}"
            )

        # Get bucket name from config if not provided
        if bucket_name is None:
            bucket_name = os.getenv("ARTIFACT_FILES_BUCKET", "files")

        try:
            # Use the provider registry to create the service
            if service_type.lower() == "auto":
                service = create_artifact_service(bucket_name=bucket_name)
            else:
                service = create_artifact_service(service_type.lower(), bucket_name)

            if service is None:
                raise RuntimeError(
                    f"Failed to create artifact service '{service_type}'"
                )

            logger.info(
                f"Artifact service created successfully: {service.__class__.__name__} (bucket: {bucket_name})"
            )
            return service

        except Exception as e:
            logger.error(f"Failed to create artifact service '{service_type}': {e}")
            raise RuntimeError(
                f"Failed to create artifact service '{service_type}': {e}"
            )

    @staticmethod
    def get_provider_status() -> Dict[str, Dict[str, Any]]:
        """Get the status of all registered artifact service providers.

        Returns:
            Dict containing status information for each provider including:
            - enabled: Whether the provider is enabled
            - priority: Provider priority (lower = higher priority)
            - configured: Whether the provider is properly configured
            - valid: Whether the provider configuration is valid
            - available: Whether the provider is available (dependencies, connectivity)
            - can_create: Whether the provider can create a service
        """
        registry = get_registry()
        return registry.get_provider_status()

    @staticmethod
    def list_available_providers() -> Dict[str, Dict[str, Any]]:
        """List all available providers that can create services.

        Returns:
            Dict containing information about available providers
        """
        registry = get_registry()
        available_providers = registry.get_available_providers()

        result = {}
        for provider in available_providers:
            result[provider.name] = {
                "priority": provider.priority,
                "config_type": provider.config.__class__.__name__,
                "can_create": provider.can_create_service(),
            }

        return result

    @staticmethod
    def test_provider(
        provider_name: str, bucket_name: str = "test-artifacts"
    ) -> Dict[str, Any]:
        """Test a specific provider and return detailed status.

        Args:
            provider_name: Name of the provider to test
            bucket_name: Bucket name to use for testing

        Returns:
            Dict containing test results
        """
        registry = get_registry()
        provider = registry.get_provider(provider_name)

        if not provider:
            return {
                "provider": provider_name,
                "exists": False,
                "error": f"Provider '{provider_name}' not found",
            }

        result = {
            "provider": provider_name,
            "exists": True,
            "enabled": provider.config.enabled,
            "priority": provider.priority,
            "configured": False,
            "valid": False,
            "available": False,
            "can_create": False,
            "service_created": False,
            "bucket_name": bucket_name,
            "error": None,
        }

        try:
            result["configured"] = provider.config.is_configured()
            result["valid"] = provider.config.validate()
            result["available"] = provider.is_available()
            result["can_create"] = provider.can_create_service()

            # Try to create a service
            if result["can_create"]:
                service = provider.try_create_service(bucket_name)
                if service:
                    result["service_created"] = True
                    result["service_type"] = service.__class__.__name__
                else:
                    result["error"] = "Service creation returned None"

        except Exception as e:
            result["error"] = str(e)

        return result


def get_artifact_service(
    service_type: str = "auto", bucket_name: Optional[str] = None
) -> BaseArtifactService:
    """Get an artifact service instance.

    This is a convenience function that delegates to the factory.

    Args:
        service_type: Type of artifact service to create
        bucket_name: Name of the bucket/container to use

    Returns:
        BaseArtifactService: The artifact service instance
    """
    service = ArtifactServiceFactory.create_artifact_service(service_type, bucket_name)

    # Log which artifact service is being used
    logger.info(f"Artifact service type: {type(service).__name__}")
    logger.info(f"Artifact service module: {type(service).__module__}")

    return service
