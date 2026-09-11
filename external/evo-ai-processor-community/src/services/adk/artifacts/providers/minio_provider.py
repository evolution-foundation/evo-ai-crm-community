"""
MinIO artifact service provider.

This provider uses the MinIO Python client directly for S3-compatible services,
offering better performance and direct integration with MinIO and other S3-compatible services.
"""

import os
from typing import Optional

from .base_provider import BaseArtifactProvider, ProviderConfig
from google.adk.artifacts.base_artifact_service import BaseArtifactService
from src.utils.logger import setup_logger

logger = setup_logger(__name__)


class MinIOProviderConfig(ProviderConfig):
    """Configuration for MinIO artifact service provider."""

    def __init__(self):
        # Check if MinIO service is explicitly enabled
        enabled = os.getenv("ARTIFACT_SERVICE_TYPE", "auto").lower() in [
            "minio",
            "s3",  # Accept s3 as alias for minio (backward compatibility)
            "auto",
        ]
        super().__init__(enabled=enabled)

        # MinIO configuration
        self.endpoint = os.getenv("ARTIFACT_ENDPOINT")
        self.access_key = os.getenv("ARTIFACT_ACCESS_KEY")
        self.secret_key = os.getenv("ARTIFACT_SECRET_KEY")
        self.secure = os.getenv("ARTIFACT_SECURE", "true").lower() == "true"
        self.region = os.getenv("ARTIFACT_REGION", "us-east-1")
        self.default_bucket = os.getenv("ARTIFACT_FILES_BUCKET", "files")

    def is_configured(self) -> bool:
        """Check if MinIO is configured with required settings."""
        return bool(self.endpoint and self.access_key and self.secret_key)

    def validate(self) -> bool:
        """Validate MinIO configuration."""
        if not self.is_configured():
            return False

        # Validate endpoint format (MinIO client expects no protocol)
        if self.endpoint.startswith(("http://", "https://")):
            return False  # MinIO client doesn't want protocol in endpoint

        # Validate credentials are not empty
        if not self.access_key.strip() or not self.secret_key.strip():
            return False

        # Validate endpoint has domain format
        if "." not in self.endpoint and ":" not in self.endpoint:
            return False

        return True


class MinIOArtifactProvider(BaseArtifactProvider):
    """MinIO artifact service provider using MinIO Python client."""

    def __init__(self):
        config = MinIOProviderConfig()
        super().__init__(
            name="minio", config=config, priority=10
        )  # Higher priority than S3/boto3

    def is_available(self) -> bool:
        """Check if MinIO client is available."""
        try:
            # Check if MinIO client is available
            from minio import Minio

            logger.info("MinIO client imported successfully")

            # If configured, validate the configuration
            if self.config.is_configured() and self.config.validate():
                logger.info(
                    f"MinIO provider configured with endpoint: {self.config.endpoint}"
                )
                return True
            elif self.config.is_configured():
                logger.warning("MinIO provider is configured but validation failed")
                return False
            else:
                logger.info("MinIO client available but not configured")
                return False

        except ImportError:
            logger.warning("MinIO client not available - minio package not installed")
            return False
        except Exception as e:
            logger.warning(f"MinIO service not available: {e}")
            return False

    def create_service(self, bucket_name: str) -> BaseArtifactService:
        """Create a MinIO artifact service instance."""
        from src.services.adk.artifacts.minio_artifact_service import (
            MinIOArtifactService,
        )

        logger.info(
            f"Creating MinIOArtifactService with bucket: {bucket_name}, endpoint: {self.config.endpoint}"
        )

        return MinIOArtifactService(
            bucket_name=bucket_name,
            endpoint=self.config.endpoint,
            access_key=self.config.access_key,
            secret_key=self.config.secret_key,
            secure=self.config.secure,
            region=self.config.region,
        )
