"""An artifact service implementation using MinIO Python client."""

import logging
from typing import Optional, Any
from io import BytesIO
from datetime import timedelta
import re

from minio import Minio
from minio.error import S3Error
from google.genai import types
from typing_extensions import override

from google.adk.artifacts.base_artifact_service import BaseArtifactService
from google.adk.artifacts.base_artifact_service import ArtifactVersion

logger = logging.getLogger("google_adk." + __name__)


class MinIOArtifactService(BaseArtifactService):
    """An artifact service implementation using MinIO Python client."""

    def __init__(
        self,
        bucket_name: str,
        endpoint: str,
        access_key: str,
        secret_key: str,
        secure: bool = True,
        region: str = "us-east-1",
        **kwargs,
    ):
        """Initializes the MinIOArtifactService.

        Args:
            bucket_name: The name of the bucket to use.
            endpoint: The MinIO/S3-compatible endpoint (without protocol).
            access_key: The access key for authentication.
            secret_key: The secret key for authentication.
            secure: Whether to use HTTPS. Defaults to True.
            region: The region name. Defaults to 'us-east-1'.
            **kwargs: Additional keyword arguments (for compatibility).
        """
        self.bucket_name = bucket_name

        # Initialize MinIO client
        self.client = Minio(
            endpoint,
            access_key=access_key,
            secret_key=secret_key,
            secure=secure,
            region=region,
        )

        # Ensure bucket exists
        self._ensure_bucket_exists()

    def _ensure_bucket_exists(self) -> None:
        """Ensures the bucket exists and is accessible."""
        try:
            if not self.client.bucket_exists(self.bucket_name):
                logger.warning(f"Bucket '{self.bucket_name}' does not exist")
                # Optionally try to create the bucket
                try:
                    self.client.make_bucket(self.bucket_name)
                    logger.info(f"Created bucket '{self.bucket_name}'")
                except S3Error as e:
                    logger.warning(f"Could not create bucket '{self.bucket_name}': {e}")
            else:
                logger.info(f"Bucket '{self.bucket_name}' is accessible")
        except S3Error as e:
            logger.warning(f"Error checking bucket '{self.bucket_name}': {e}")

    def _file_has_user_namespace(self, filename: str) -> bool:
        """Checks if the filename has a user namespace.

        Args:
            filename: The filename to check.

        Returns:
            True if the filename has a user namespace (starts with "user:"),
            False otherwise.
        """
        return filename.startswith("user:")

    def _get_object_key(
        self,
        app_name: str,
        user_id: str,
        session_id: str,
        filename: str,
        version: int | str,
    ) -> str:
        """Constructs the object key in MinIO.

        Args:
            app_name: The name of the application.
            user_id: The ID of the user.
            session_id: The ID of the session.
            filename: The name of the artifact file.
            version: The version of the artifact.

        Returns:
            The constructed object key in MinIO.
        """
        # Split filename into name and extension
        if "." in filename:
            name, extension = filename.rsplit(".", 1)
            versioned_filename = f"{name}_v{version}.{extension}"
        else:
            versioned_filename = f"{filename}_v{version}"

        if self._file_has_user_namespace(filename):
            return f"{app_name}/{user_id}/user/{versioned_filename}"
        return f"{app_name}/{user_id}/{session_id}/{versioned_filename}"

    @override
    async def save_artifact(
        self,
        *,
        app_name: str,
        user_id: str,
        filename: str,
        artifact: types.Part,
        session_id: Optional[str] = None,
        custom_metadata: Optional[dict[str, Any]] = None,
    ) -> int:
        """Saves an artifact to MinIO storage.

        Args:
            app_name: The name of the application.
            user_id: The ID of the user.
            filename: The name of the artifact file.
            artifact: The artifact to save.
            session_id: The ID of the session (ignored for user-namespaced files).
            custom_metadata: Optional custom metadata to store with the artifact.

        Returns:
            The version number of the saved artifact.

        Raises:
            S3Error: If there's an error saving to MinIO.
        """
        logger.info(
            f"Starting save_artifact: app_name={app_name}, user_id={user_id}, session_id={session_id}, filename={filename}"
        )

        versions = await self.list_versions(
            app_name=app_name,
            user_id=user_id,
            session_id=session_id,
            filename=filename,
        )
        version = 0 if not versions else max(versions) + 1
        logger.info(f"Determined version: {version}")

        object_key = self._get_object_key(
            app_name, user_id, session_id or "", filename, version
        )
        logger.info(f"Object key: {object_key}")

        try:
            # Convert data to BytesIO for MinIO
            data_stream = BytesIO(artifact.inline_data.data)
            data_length = len(artifact.inline_data.data)
            logger.info(
                f"Data length: {data_length} bytes, content_type: {artifact.inline_data.mime_type}"
            )

            self.client.put_object(
                bucket_name=self.bucket_name,
                object_name=object_key,
                data=data_stream,
                length=data_length,
                content_type=artifact.inline_data.mime_type,
            )
            logger.info(f"Successfully saved artifact to MinIO: {object_key}")

            return version
        except S3Error as e:
            logger.error(f"Failed to save artifact {object_key}: {e}")
            raise
        except Exception as e:
            logger.error(f"Unexpected error saving artifact {object_key}: {e}")
            raise

    @override
    async def load_artifact(
        self,
        *,
        app_name: str,
        user_id: str,
        filename: str,
        session_id: Optional[str] = None,
        version: Optional[int] = None,
    ) -> Optional[types.Part]:
        """Loads an artifact from MinIO storage.

        Args:
            app_name: The name of the application.
            user_id: The ID of the user.
            filename: The name of the artifact file.
            session_id: The ID of the session (ignored for user-namespaced files).
            version: The version of the artifact. If None, loads the latest version.

        Returns:
            The artifact or None if not found.
        """
        if version is None:
            versions = await self.list_versions(
                app_name=app_name,
                user_id=user_id,
                session_id=session_id,
                filename=filename,
            )
            if not versions:
                return None
            version = max(versions)

        object_key = self._get_object_key(
            app_name, user_id, session_id or "", filename, version
        )

        try:
            # Get content type from object metadata first
            stat = self.client.stat_object(self.bucket_name, object_key)
            mime_type = stat.content_type or "application/octet-stream"

            # For binary files (audio, image, video), return a presigned URL to avoid LiteLLM issues
            binary_mime_prefixes = [
                "audio/",
                "image/",
                "video/",
                "application/octet-stream",
            ]
            is_binary_file = any(
                mime_type.startswith(prefix) for prefix in binary_mime_prefixes
            )

            if is_binary_file:
                # Generate presigned URL for binary files
                presigned_url = await self.generate_presigned_url(
                    app_name=app_name,
                    user_id=user_id,
                    session_id=session_id,
                    filename=filename,
                    version=version,
                    expires=timedelta(hours=1),
                )
                # Return URL as text content for LiteLLM compatibility
                artifact = types.Part(text=f"Artifact URL: {presigned_url}")
                logger.info(f"Loaded binary artifact as URL: {object_key}")
                return artifact
            else:
                # For text files, return the actual content
                response = self.client.get_object(self.bucket_name, object_key)
                artifact_bytes = response.read()

                if not artifact_bytes:
                    return None

                # Create Part using inline_data Blob for text content
                blob = types.Blob(mime_type=mime_type, data=artifact_bytes)
                artifact = types.Part(inline_data=blob)
                logger.info(f"Loaded text artifact as bytes: {object_key}")
                return artifact

        except S3Error as e:
            if e.code == "NoSuchKey":
                logger.info(f"Artifact not found: {object_key}")
                return None
            logger.error(f"Failed to load artifact {object_key}: {e}")
            raise
        finally:
            # Always close the response if it was opened
            if "response" in locals():
                response.close()
                response.release_conn()

    @override
    async def list_artifact_keys(
        self, *, app_name: str, user_id: str, session_id: Optional[str] = None
    ) -> list[str]:
        """Lists all artifact filenames within a session.

        Args:
            app_name: The name of the application.
            user_id: The ID of the user.
            session_id: The ID of the session (optional).

        Returns:
            A list of all artifact filenames within the session.
        """
        filenames = set()

        # Pattern to match versioned files and extract base filename
        version_pattern = re.compile(r"^(.+)_v\d+(\..+)?$")

        # List session-scoped artifacts if session_id is provided
        if session_id:
            session_prefix = f"{app_name}/{user_id}/{session_id}/"
            session_objects = self.client.list_objects(
                self.bucket_name, prefix=session_prefix, recursive=False
            )
            for obj in session_objects:
                # Extract filename from object path
                filename = obj.object_name.split("/")[-1]

                # Try to extract base filename from versioned filename
                match = version_pattern.match(filename)
                if match:
                    base_name = match.group(1)
                    extension = match.group(2) or ""
                    original_filename = f"{base_name}{extension}"
                    filenames.add(original_filename)
                else:
                    # If no version pattern, use filename as-is
                    filenames.add(filename)

        user_namespace_prefix = f"{app_name}/{user_id}/user/"
        user_namespace_objects = self.client.list_objects(
            self.bucket_name, prefix=user_namespace_prefix, recursive=False
        )
        for obj in user_namespace_objects:
            # Extract filename from object path
            filename = obj.object_name.split("/")[-1]

            # Try to extract base filename from versioned filename
            match = version_pattern.match(filename)
            if match:
                base_name = match.group(1)
                extension = match.group(2) or ""
                original_filename = f"{base_name}{extension}"
                filenames.add(original_filename)
            else:
                # If no version pattern, use filename as-is
                filenames.add(filename)

        return sorted(list(filenames))

    @override
    async def delete_artifact(
        self, *, app_name: str, user_id: str, filename: str, session_id: Optional[str] = None
    ) -> None:
        """Deletes all versions of an artifact.

        Args:
            app_name: The name of the application.
            user_id: The ID of the user.
            filename: The name of the artifact file.
            session_id: The ID of the session (ignored for user-namespaced files).
        """
        versions = await self.list_versions(
            app_name=app_name,
            user_id=user_id,
            session_id=session_id,
            filename=filename,
        )
        for version in versions:
            object_key = self._get_object_key(
                app_name, user_id, session_id or "", filename, version
            )
            self.client.remove_object(self.bucket_name, object_key)
        return

    @override
    async def list_versions(
        self, *, app_name: str, user_id: str, filename: str, session_id: Optional[str] = None
    ) -> list[int]:
        """Lists all versions of an artifact.

        Args:
            app_name: The name of the application.
            user_id: The ID of the user.
            filename: The name of the artifact file.
            session_id: The ID of the session (ignored for user-namespaced files).

        Returns:
            A list of all available versions of the artifact.
        """
        # Extract base filename without extension for pattern matching
        if "." in filename:
            base_name, extension = filename.rsplit(".", 1)
            pattern = f"{base_name}_v(\\d+)\\.{extension}$"
        else:
            base_name = filename
            pattern = f"{base_name}_v(\\d+)$"

        # Get the directory prefix where files would be stored
        if self._file_has_user_namespace(filename):
            prefix = f"{app_name}/{user_id}/user/"
        else:
            if session_id is None:
                raise ValueError("Session ID must be provided for session-scoped artifacts.")
            prefix = f"{app_name}/{user_id}/{session_id}/"

        # List all objects in the directory
        objects = self.client.list_objects(
            self.bucket_name, prefix=prefix, recursive=False
        )

        versions = []
        regex = re.compile(pattern)

        for obj in objects:
            # Extract just the filename from the full object path
            object_filename = obj.object_name.split("/")[-1]
            match = regex.match(object_filename)
            if match:
                version = int(match.group(1))
                versions.append(version)

        return sorted(versions)

    @override
    async def get_artifact_version(
        self,
        *,
        app_name: str,
        user_id: str,
        filename: str,
        session_id: Optional[str] = None,
        version: Optional[int] = None,
    ) -> Optional[ArtifactVersion]:
        """Gets metadata for a specific version of an artifact.

        Args:
            app_name: The name of the application.
            user_id: The ID of the user.
            filename: The name of the artifact file.
            session_id: The ID of the session (ignored for user-namespaced files).
            version: The version of the artifact. If None, gets the latest version.

        Returns:
            ArtifactVersion metadata or None if not found.
        """
        if version is None:
            versions = await self.list_versions(
                app_name=app_name,
                user_id=user_id,
                session_id=session_id,
                filename=filename,
            )
            if not versions:
                return None
            version = max(versions)

        object_key = self._get_object_key(
            app_name, user_id, session_id or "", filename, version
        )

        try:
            stat = self.client.stat_object(self.bucket_name, object_key)

            # Construct canonical URI
            if self._file_has_user_namespace(filename):
                canonical_uri = f"s3://{self.bucket_name}/{app_name}/{user_id}/user/{filename}_v{version}"
            else:
                canonical_uri = f"s3://{self.bucket_name}/{app_name}/{user_id}/{session_id}/{filename}_v{version}"

            return ArtifactVersion(
                version=version,
                canonical_uri=canonical_uri,
                create_time=stat.last_modified.timestamp() if stat.last_modified else None,
                mime_type=stat.content_type or "application/octet-stream",
                custom_metadata=stat.metadata if stat.metadata else {},
            )
        except S3Error as e:
            if e.code == "NoSuchKey":
                logger.info(f"Artifact version not found: {object_key}")
                return None
            logger.error(f"Failed to get artifact version {object_key}: {e}")
            raise

    @override
    async def list_artifact_versions(
        self,
        *,
        app_name: str,
        user_id: str,
        filename: str,
        session_id: Optional[str] = None,
    ) -> list[ArtifactVersion]:
        """Lists all versions and their metadata of an artifact.

        Args:
            app_name: The name of the application.
            user_id: The ID of the user.
            filename: The name of the artifact file.
            session_id: The ID of the session (ignored for user-namespaced files).

        Returns:
            A list of ArtifactVersion metadata for all available versions.
        """
        versions = await self.list_versions(
            app_name=app_name,
            user_id=user_id,
            session_id=session_id,
            filename=filename,
        )

        artifact_versions = []
        for version in versions:
            artifact_version = await self.get_artifact_version(
                app_name=app_name,
                user_id=user_id,
                filename=filename,
                session_id=session_id,
                version=version,
            )
            if artifact_version:
                artifact_versions.append(artifact_version)

        artifact_versions.sort(key=lambda x: x.version)
        return artifact_versions

    async def generate_presigned_url(
        self,
        *,
        app_name: str,
        user_id: str,
        session_id: str,
        filename: str,
        version: int,
        expires: timedelta = timedelta(hours=1),
    ) -> str:
        """Generates a presigned URL for an artifact.

        Args:
            app_name: The name of the application.
            user_id: The ID of the user.
            session_id: The ID of the session.
            filename: The name of the artifact file.
            version: The version of the artifact.
            expires: The expiration time for the presigned URL. Defaults to 1 hour.

        Returns:
            The presigned URL for the artifact.
        """
        object_key = self._get_object_key(
            app_name, user_id, session_id, filename, version
        )
        return self.client.presigned_get_object(
            self.bucket_name, object_key, expires=expires
        )
