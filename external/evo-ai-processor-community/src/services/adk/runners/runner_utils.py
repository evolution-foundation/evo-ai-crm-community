"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: runner_utils.py                                                       │
│ Developed by: Davidson Gomes                                                 │
│ Creation date: May 17, 2025                                                  │
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

from google.adk.runners import Runner
from google.adk.runners import InMemoryRunner
from google.genai.types import Content, Part, Blob
from google.adk.sessions import DatabaseSessionService
from google.adk.memory.base_memory_service import BaseMemoryService
from google.adk.artifacts.in_memory_artifact_service import InMemoryArtifactService
from google.adk.events import Event, EventActions
import time
from src.utils.logger import setup_logger
from src.core.exceptions import AgentNotFoundError
from src.services.agent_service import get_agent
from src.services.adk.agent_builder import AgentBuilder
from src.utils.adk_utils import extract_state_params
from sqlalchemy.orm import Session
from typing import Optional, List, Tuple, Dict, Any, Union
import base64
import json
import uuid
from src.services.temp_limits_service import check_session_limit
from src.services.session_service import SessionLimitExceeded
from datetime import datetime
from fastapi import HTTPException

logger = setup_logger(__name__)


def convert_sets(obj):
    """Convert sets to lists for JSON serialization."""
    if isinstance(obj, set):
        return list(obj)
    elif isinstance(obj, dict):
        return {k: convert_sets(v) for k, v in obj.items()}
    elif isinstance(obj, list):
        return [convert_sets(i) for i in obj]
    else:
        return obj


class RunnerUtils:
    """Utility class for common runner operations."""

    def __init__(self, db: Session):
        self.db = db
        self.agent_builder = AgentBuilder(db)

    async def get_and_build_agent(self, agent_id: str):
        """Get agent from database and build it."""
        from src.services.agent_service import get_agent, get_agent_integrations
        
        get_root_agent = await get_agent(self.db, agent_id)
        if get_root_agent is None:
            raise AgentNotFoundError(f"Agent with ID {agent_id} not found")

        # Load integrations directly from database
        integrations = await get_agent_integrations(self.db, agent_id)
        
        # Attach integrations to agent object for use in builder
        get_root_agent._integrations = integrations

        root_agent, state_params = await self.agent_builder.build_agent(get_root_agent)
        logger.debug(f"State params: {state_params}")

        return root_agent, state_params

    def create_session_id(
        self, external_id: str, agent_id: str, session_id: Optional[str] = None
    ) -> str:
        """Create or use provided session ID."""
        if session_id:
            return session_id
        else:
            return f"{external_id}_{agent_id}"

    def create_runner(
        self,
        agent,
        agent_id: str,
        session_service: DatabaseSessionService,
        artifacts_service: InMemoryArtifactService,
        memory_service: Optional[BaseMemoryService] = None,
        memory_runner: bool = False,
    ) -> Runner:
        """Create and configure Runner."""
        if memory_runner:
            return InMemoryRunner(
                app_name=agent_id,
                agent=agent,
                # session_service=session_service,
                # artifacts_service=artifacts_service,
                # memory_service=memory_service,
            )
        else:
            return Runner(
                agent=agent,
                app_name=agent_id,
                session_service=session_service,
                artifact_service=artifacts_service,
                memory_service=memory_service,
            )

    async def get_or_create_session(
        self,
        session_service: DatabaseSessionService,
        agent_id: str,
        external_id: str,
        adk_session_id: str,
    ):
        """Get existing session or create new one."""
        # First, try to get session by ID directly from database (more reliable)
        # This ensures we find sessions created via the API endpoint
        try:
            from src.services.session_service import get_session_by_id
            # Pass self.db to use the same database session
            session = await get_session_by_id(session_service, adk_session_id, db=self.db)
            if session:
                logger.debug(f"Found existing session {adk_session_id} in database")
                return session
        except HTTPException as e:
            # If session not found (404), continue to standard method
            if e.status_code == 404:
                logger.debug(f"Session {adk_session_id} not found in database, trying standard method")
            else:
                # Re-raise other HTTP exceptions
                raise
        except Exception as e:
            logger.debug(f"Could not get session by ID {adk_session_id}: {str(e)}, trying standard method")
        
        # Fallback to standard method
        session = await session_service.get_session(
            app_name=agent_id,
            user_id=external_id,
            session_id=adk_session_id,
        )

        if session is None:
            # Check session limits before creating new session
            await self._check_session_limits(external_id)

            session = await session_service.create_session(
                app_name=agent_id,
                user_id=external_id,
                session_id=adk_session_id,
            )
            logger.info(f"Created new session {adk_session_id} for agent {agent_id} and user {external_id}")

        return session

    async def _check_session_limits(self, user_id: str) -> None:
        """Check session limits before creating new sessions.

        Args:
            user_id: The user ID to check limits for

        Raises:
            SessionLimitExceeded: If session limit is exceeded
        """
        # Check session count limit
        allowed, message = check_session_limit(self.db)
        if not allowed:
            logger.warning(f"Session limit exceeded for user {user_id}: {message}")
            raise SessionLimitExceeded(message)

        logger.debug(f"Session limits check passed for user {user_id}")

    async def setup_session_state(
        self,
        session_service: DatabaseSessionService,
        session,
        message: str,
        state_params: Optional[List[str]] = None,
        metadata: Optional[Dict[str, Any]] = None,
    ):
        """Setup session state with user input, state params and metadata."""
        # Store user input
        state_changes = {"user_input": message}
        actions_with_update = EventActions(state_delta=state_changes)
        user_input_event = Event(
            invocation_id=f"user_input_{int(time.time())}",
            author="system",
            actions=actions_with_update,
            timestamp=time.time(),
        )

        await session_service.append_event(session, user_input_event)
        logger.debug(f"Stored user input in session state via ADK: {message}")

        # Setup state parameters
        if state_params:
            for param in state_params:
                state_changes = {f"{param}": ""}
                actions_with_update = EventActions(state_delta=state_changes)
                new_param_event = Event(
                    invocation_id=f"param_{param}_{int(time.time())}",
                    author="system",
                    actions=actions_with_update,
                    timestamp=time.time(),
                )
                await session_service.append_event(session, new_param_event)
                logger.debug(f"Stored {param} in session state via ADK")

        # Store current time
        state_changes = {"_datetime": datetime.now().isoformat()}
        actions_with_update = EventActions(state_delta=state_changes)
        current_time_event = Event(
            invocation_id=f"current_time_{int(time.time())}",
            author="system",
            actions=actions_with_update,
            timestamp=time.time(),
        )
        await session_service.append_event(session, current_time_event)
        logger.debug(f"Stored current time in session state via ADK: {time.time()}")

        # Setup metadata
        if metadata:
            logger.info(f"[RunnerUtils] Setting up metadata with {len(metadata)} keys: {list(metadata.keys())}")
            for key, value in metadata.items():
                # Log contact data specifically
                if key == "contact" and isinstance(value, dict):
                    logger.info(f"[RunnerUtils] Storing contact data: name={value.get('name', 'N/A')}, id={value.get('id', 'N/A')}")
                elif key == "evoai_crm_data" and isinstance(value, dict) and "contact" in value:
                    contact_in_data = value.get("contact", {})
                    logger.info(f"[RunnerUtils] Storing evoai_crm_data with contact: name={contact_in_data.get('name', 'N/A') if isinstance(contact_in_data, dict) else 'N/A'}")
                
                state_changes = {f"{key}": value}
                actions_with_update = EventActions(state_delta=state_changes)
                new_metadata_event = Event(
                    invocation_id=f"metadata_{key}_{int(time.time())}",
                    author="system",
                    actions=actions_with_update,
                    timestamp=time.time(),
                )
                await session_service.append_event(session, new_metadata_event)
                logger.info(f"[RunnerUtils] ✅ Stored metadata '{key}' in session state via ADK")

    async def process_files(
        self,
        files: Optional[List],
        artifacts_service: InMemoryArtifactService,
        agent_id: str,
        external_id: str,
        adk_session_id: str,
    ) -> Tuple[List[Part], List[str]]:
        """Process uploaded files and return file parts and transcribed audio texts."""
        file_parts = []
        transcribed_texts = []

        if files and len(files) > 0:
            inlined_bytes = 0
            for file_data in files:
                try:
                    # Check if file is audio
                    is_audio = self._is_audio_file(
                        file_data.content_type, file_data.filename
                    )

                    logger.info(
                        f"Processing file: {file_data.filename} (type: {file_data.content_type}, is_audio: {is_audio})"
                    )

                    file_bytes = base64.b64decode(file_data.data)
                    file_part = Part(
                        inline_data=Blob(
                            mime_type=file_data.content_type,
                            data=file_bytes,
                        )
                    )

                    # EVO-2181: add the file to the content parts so the model
                    # actually receives it. This append used to be gated behind
                    # `if is_audio`, so an image was blobbed and saved to the
                    # artifact store but never handed to the LLM -> the agent
                    # replied "No content to process".
                    #
                    # It runs before save_artifact on purpose: the bytes are
                    # already in hand, and a failure while storing them must not
                    # cost the model its copy of the file and bring this very bug
                    # back.
                    skip_reason = self._inline_skip_reason(
                        file_data.content_type, len(file_bytes), inlined_bytes
                    )
                    if skip_reason:
                        logger.warning(
                            f"File {file_data.filename} ({file_data.content_type}) not sent"
                            f" to the model: {skip_reason}. Still saved as an artifact."
                        )
                    else:
                        inlined_bytes += len(file_bytes)
                        file_parts.append(file_part)
                        logger.info(
                            f"Added {'audio' if is_audio else 'file'} {file_data.filename}"
                            f" ({file_data.content_type}) to content parts for LLM processing"
                        )

                    # Always save to artifacts for reference
                    await artifacts_service.save_artifact(
                        app_name=agent_id,
                        user_id=external_id,
                        session_id=adk_session_id,
                        filename=file_data.filename,
                        artifact=file_part,
                    )

                except Exception as e:
                    logger.error(
                        f"Error processing file {file_data.filename}: {str(e)}"
                    )

        return file_parts, transcribed_texts

    # What google-adk can actually turn into a model content part. Its LiteLlm
    # path (`_get_content`) decodes text/* inline, maps image//audio//video/ to
    # the matching data-uri part and application/pdf + application/json to a file
    # part, then raises ValueError on anything else -- and the runner turns that
    # ValueError into a 500, losing the whole turn, the user's text included.
    # Mirrored here because it is a private ADK detail; test_media_file_parts
    # pins the two together against the installed version.
    _MODEL_READABLE_MIME_PREFIXES = ("text/", "image/", "audio/", "video/")
    _MODEL_READABLE_MIME_TYPES = frozenset({"application/pdf", "application/json"})

    # Ceilings on what we inline, mirroring the bounds the bot-runtime already
    # applies when downloading the attachment (ai_adapter.go: maxAttachmentBytes
    # / maxAttachmentsTotalBytes). Providers reject an oversized inline request,
    # and that rejection is a 500 here too.
    MAX_INLINE_FILE_BYTES = 15 * 1024 * 1024
    MAX_INLINE_REQUEST_BYTES = 20 * 1024 * 1024

    def _inline_skip_reason(
        self, content_type: str, size_bytes: int, already_inlined: int
    ) -> Optional[str]:
        """Why this file must not travel to the model as inline data, or None.

        Skipping is the graceful path: the file is still saved as an artifact and
        the rest of the message -- text and readable media -- still gets an
        answer. Forwarding it instead costs the whole turn.
        """
        # Checked verbatim, exactly as ADK will see it on the Blob. Normalizing
        # first (lowercasing, dropping ";codecs=opus") would answer a question
        # nobody asks downstream: _get_content matches the raw mime_type, with a
        # case-sensitive startswith and an exact-match set. So "IMAGE/PNG" and
        # "application/pdf; charset=binary" would clear a normalized check and
        # then raise ValueError inside ADK -- a 500 that costs the whole turn,
        # which is the failure this guard exists to prevent.
        mime_type = content_type or ""
        if not (
            mime_type.startswith(self._MODEL_READABLE_MIME_PREFIXES)
            or mime_type in self._MODEL_READABLE_MIME_TYPES
        ):
            return "the model layer cannot carry this content type as inline data"

        if size_bytes > self.MAX_INLINE_FILE_BYTES:
            return (
                f"{size_bytes} bytes is over the {self.MAX_INLINE_FILE_BYTES} byte"
                " per-file inline limit"
            )

        if already_inlined + size_bytes > self.MAX_INLINE_REQUEST_BYTES:
            return (
                "it would push this request past the"
                f" {self.MAX_INLINE_REQUEST_BYTES} byte inline budget"
            )

        return None

    def _is_audio_file(self, content_type: str, filename: str) -> bool:
        """Check if file is an audio file based on content type and extension."""
        if not content_type and not filename:
            return False

        # Check MIME type (handle types with parameters like "audio/webm;codecs=opus")
        if content_type:
            # Extract main MIME type (before semicolon if present)
            main_mime_type = content_type.split(";")[0].strip().lower()

            audio_mime_types = [
                "audio/mpeg",  # MP3
                "audio/mp3",
                "audio/wav",  # WAV
                "audio/wave",
                "audio/x-wav",
                "audio/ogg",  # OGG
                "audio/vorbis",
                "audio/flac",  # FLAC
                "audio/x-flac",
                "audio/aac",  # AAC
                "audio/mp4",  # M4A
                "audio/x-m4a",
                "audio/webm",  # WebM Audio
                "audio/opus",  # Opus
                "audio/amr",  # AMR
                "audio/3gpp",  # 3GP Audio
                "audio/x-ms-wma",  # WMA
            ]

            if main_mime_type in audio_mime_types:
                return True

        # Check file extension as fallback
        if filename:
            audio_extensions = [
                ".mp3",
                ".wav",
                ".ogg",
                ".flac",
                ".aac",
                ".m4a",
                ".wma",
                ".opus",
                ".amr",
                ".3gp",
                ".webm",
            ]
            filename_lower = filename.lower()
            for ext in audio_extensions:
                if filename_lower.endswith(ext):
                    return True

        return False

    def create_content(self, message: str, file_parts: List[Part]) -> Optional[Content]:
        """Create content with message and file parts."""
        # If message is empty and no files, return None to indicate no content to process
        if not message.strip() and not file_parts:
            return None

        # If message is empty but files exist, use empty message (let files speak for themselves)
        if not message.strip() and file_parts:
            message = ""

        parts = [Part(text=message)]
        if file_parts:
            parts.extend(file_parts)
        return Content(role="user", parts=parts)

    def create_content_with_transcribed_audio(
        self, message: str, file_parts: List[Part], transcribed_texts: List[str]
    ) -> Optional[Content]:
        """Create content with message, file parts, and transcribed audio texts."""
        # Build full message with transcribed audio texts
        full_message = message
        if transcribed_texts:
            transcriptions = "\n\n".join(transcribed_texts)
            full_message += f"\n\n{transcriptions}"

        # If both message and transcriptions are empty, and no file parts, return None
        if not full_message.strip() and not file_parts:
            logger.info("Empty message and transcription detected, skipping processing")
            return None

        parts = [Part(text=full_message)]
        if file_parts:
            parts.extend(file_parts)
        return Content(role="user", parts=parts)

    def _is_meaningful_transcription(self, transcribed_text: str) -> bool:
        """Check if transcribed text contains meaningful content."""
        # Only ignore if completely empty
        return bool(transcribed_text and transcribed_text.strip())

    async def add_session_to_memory(
        self,
        memory_service: Optional[BaseMemoryService],
        session_service: DatabaseSessionService,
        agent_id: str,
        effective_user_id: str,
        adk_session_id: str,
        root_agent: Optional[Any] = None,
    ):
        """Add completed session to memory."""
        # Skip if memory service is not provided
        if memory_service is None:
            logger.debug(f"Memory service not provided, skipping memory storage for session {adk_session_id}")
            return
            
        try:
            completed_session = await session_service.get_session(
                app_name=agent_id,
                user_id=effective_user_id,
                session_id=adk_session_id,
            )

            # Check if session was retrieved successfully
            if completed_session is None:
                logger.warning(f"Session {adk_session_id} not found, cannot add to memory")
                return

            # Extract compression parameters from agent config if available
            short_term_max_messages = None
            compression_interval = None
            memory_base_config_id = None

            # Get agent from database to extract config
            try:
                agent = await get_agent(self.db, agent_id)
                if agent:
                    # Extract compression parameters from agent config
                    if agent.config:
                        agent_config = agent.config if isinstance(agent.config, dict) else {}
                        if isinstance(agent_config, dict):
                            short_term_max_messages = agent_config.get("memory_short_term_max_messages")
                            compression_interval = agent_config.get("memory_medium_term_compression_interval")
                            memory_base_config_id = agent_config.get("memory_base_config_id")
            except Exception as e:
                logger.debug(f"Could not extract compression parameters from agent: {e}")

            # Pass database session and compression parameters if memory service supports it
            if hasattr(memory_service, "add_session_to_memory"):
                # Check if method accepts compression parameters
                import inspect
                sig = inspect.signature(memory_service.add_session_to_memory)
                params = list(sig.parameters.keys())
                
                # Build kwargs based on what the method accepts
                kwargs = {}
                if "db" in params:
                    kwargs["db"] = self.db
                if "short_term_max_messages" in params and short_term_max_messages is not None:
                    kwargs["short_term_max_messages"] = short_term_max_messages
                if "compression_interval" in params and compression_interval is not None:
                    kwargs["compression_interval"] = compression_interval
                if "memory_base_config_id" in params and memory_base_config_id is not None:
                    kwargs["memory_base_config_id"] = memory_base_config_id
                
                await memory_service.add_session_to_memory(completed_session, **kwargs)
            else:
                await memory_service.add_session_to_memory(completed_session)
            
            logger.debug(f"Successfully added session {adk_session_id} to memory")
        except Exception as e:
            # Check if it's an OpenSearch shard limit error
            error_str = str(e)
            if "maximum shards" in error_str and "validation_exception" in error_str:
                logger.warning(
                    f"OpenSearch shard limit reached for session {adk_session_id}. "
                    f"Memory service may be degraded. Consider cleaning up old indices or "
                    f"increasing shard limits in OpenSearch configuration. Error: {error_str}"
                )
            else:
                logger.error(
                    f"Failed to add session {adk_session_id} to memory service: {error_str}"
                )
            # Continue execution - memory failure shouldn't break agent functionality
