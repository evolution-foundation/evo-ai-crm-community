"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: live_runner.py                                                        │
│ Developed by: Davidson Gomes                                                 │
│ Creation date: January 2025                                                  │
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

import asyncio
import base64
import json
import traceback
from typing import Optional, Dict, Any, Tuple
from sqlalchemy.orm import Session

from google.genai.types import (
    Part,
    Content,
    Blob,
    VoiceConfig,
    PrebuiltVoiceConfigDict,
    SpeechConfig,
)
from google.adk.agents import LiveRequestQueue
from google.adk.agents.run_config import RunConfig
from google.adk.sessions import DatabaseSessionService
from google.adk.memory.base_memory_service import BaseMemoryService
from google.adk.artifacts.in_memory_artifact_service import InMemoryArtifactService

from src.services.adk.runners.runner_utils import RunnerUtils, convert_sets
from src.utils.logger import setup_logger
from src.core.exceptions import AgentNotFoundError

logger = setup_logger(__name__)


class LiveRunner:
    """Runner for live agent interactions with real-time streaming."""

    def __init__(self, db: Session):
        self.db = db
        self.utils = RunnerUtils(db)

    async def start_agent_session(
        self,
        agent_id: str,
        external_id: str,
        session_service: DatabaseSessionService,
        artifacts_service: InMemoryArtifactService,
        memory_service: Optional[BaseMemoryService] = None,
        session_id: Optional[str] = None,
        is_audio: bool = False,
        voice_config: Optional[Dict[str, Any]] = None,
        language_code: str = "en-US",
        files: Optional[list] = None,
        metadata: Optional[Dict[str, Any]] = None,
    ) -> Tuple[Any, LiveRequestQueue]:
        """Start a live agent session and return live events and request queue."""

        try:
            logger.info(
                f"🚀 Starting live session for agent {agent_id}, user {external_id}, is_audio={is_audio}"
            )

            # Get and build agent (following streaming_runner pattern)
            root_agent, state_params = await self.utils.get_and_build_agent(agent_id)

            # Setup session ID
            adk_session_id = self.utils.create_session_id(
                external_id, agent_id, session_id
            )

            # Create a Runner with the built agent
            runner = self.utils.create_runner(
                root_agent,
                agent_id,
                session_service,
                artifacts_service,
                memory_service,
                memory_runner=True,
            )

            # Get or create session
            session = await self.utils.get_or_create_session(
                session_service, agent_id, external_id, adk_session_id
            )

            # Setup session state
            await self.utils.setup_session_state(
                session_service, session, "", state_params, metadata
            )

            # Configure response modality
            modality = "AUDIO" if is_audio else "TEXT"

            # Configure voice settings
            voice_name = "Zephyr"  # Default voice
            if voice_config:
                voice_name = voice_config.get("voice_name", "Zephyr")

            voice_config_obj = VoiceConfig(
                prebuilt_voice_config=PrebuiltVoiceConfigDict(voice_name=voice_name)
            )
            speech_config = SpeechConfig(
                voice_config=voice_config_obj, language_code=language_code
            )

            run_config = RunConfig(
                response_modalities=[modality],
                speech_config=speech_config,
            )

            # Create a LiveRequestQueue for this session
            live_request_queue = LiveRequestQueue()

            # Start agent live session
            live_events = runner.run_live(
                session=session,
                live_request_queue=live_request_queue,
                run_config=run_config,
            )

            logger.info("✅ Agent session started successfully")
            return live_events, live_request_queue

        except AgentNotFoundError:
            raise
        except Exception as e:
            logger.error(f"💥 Failed to start live agent session: {str(e)}")
            raise Exception(f"Failed to start live agent session: {str(e)}")

    async def agent_to_client_messaging(self, websocket, live_events):
        """Handle agent to client communication."""
        try:
            logger.debug("🎯 Starting agent_to_client_messaging loop")
            while True:
                logger.debug("⏳ Waiting for agent events...")
                async for event in live_events:
                    logger.debug(
                        f"🔔 Received agent event: turn_complete={event.turn_complete}, interrupted={event.interrupted}"
                    )

                    # If the turn complete or interrupted, send it
                    if event.turn_complete or event.interrupted:
                        message = {
                            "turn_complete": event.turn_complete,
                            "interrupted": event.interrupted,
                        }
                        await websocket.send_text(json.dumps(message))
                        logger.debug(f"[AGENT TO CLIENT]: {message}")
                        continue

                    # Read the Content and its first Part
                    part: Part = (
                        event.content and event.content.parts and event.content.parts[0]
                    )
                    logger.debug(f"🔍 Event content part: {part is not None}")

                    if not part:
                        logger.debug("⚠️ No part found in event, skipping")
                        continue

                    # If it's audio, send Base64 encoded audio data
                    is_audio = (
                        part.inline_data
                        and part.inline_data.mime_type.startswith("audio/pcm")
                    )
                    logger.debug(f"🎵 Is audio part: {is_audio}")

                    if is_audio:
                        audio_data = part.inline_data and part.inline_data.data
                        if audio_data:
                            logger.debug(
                                f"🎤 Preparing to send audio: {len(audio_data)} bytes"
                            )
                            message = {
                                "mime_type": "audio/pcm",
                                "data": base64.b64encode(audio_data).decode("ascii"),
                            }
                            await websocket.send_text(json.dumps(message))
                            logger.debug(
                                f"[AGENT TO CLIENT]: audio/pcm: {len(audio_data)} bytes"
                            )
                            continue

                    # If it's text and a partial text, send it
                    logger.debug(
                        f"📝 Checking for text: {part.text is not None}, partial: {event.partial}"
                    )
                    if part.text and event.partial:
                        message = {"mime_type": "text/plain", "data": part.text}
                        await websocket.send_text(json.dumps(message))
                        logger.debug(f"[AGENT TO CLIENT]: text/plain: {message}")

        except Exception as e:
            logger.error(f"💥 agent_to_client_messaging error: {type(e).__name__}: {e}")
            logger.error(f"🔥 Full traceback: {traceback.format_exc()}")
            raise

    async def client_to_agent_messaging(self, websocket, live_request_queue):
        """Handle client to agent communication."""
        try:
            logger.debug("🎯 Starting client_to_agent_messaging loop")
            while True:
                # Decode JSON message
                logger.debug("⏳ Waiting for WebSocket message...")
                message_json = await websocket.receive_text()
                logger.debug(
                    f"📥 Received WebSocket message: {len(message_json)} chars"
                )

                message = json.loads(message_json)
                mime_type = message["mime_type"]
                data = message["data"]
                logger.debug(
                    f"🔍 Parsed message - mime_type: {mime_type}, data_size: {len(data)}"
                )

                # Send the message to the agent
                if mime_type == "text/plain":
                    # Send a text message
                    content = Content(role="user", parts=[Part.from_text(text=data)])
                    live_request_queue.send_content(content=content)
                    logger.debug(f"[CLIENT TO AGENT]: {data}")
                elif mime_type == "audio/pcm":
                    # Send an audio data
                    decoded_data = base64.b64decode(data)
                    logger.debug(f"🎵 Decoded audio data: {len(decoded_data)} bytes")
                    logger.debug("🚀 Sending audio to live_request_queue...")
                    live_request_queue.send_realtime(
                        Blob(data=decoded_data, mime_type=mime_type)
                    )
                    logger.debug("✅ Audio sent to live_request_queue successfully")
                    logger.debug(
                        f"[CLIENT TO AGENT]: audio/pcm: {len(decoded_data)} bytes sent to Gemini"
                    )
                else:
                    logger.error(f"❌ Unsupported mime_type: {mime_type}")
                    raise ValueError(f"Mime type not supported: {mime_type}")

        except Exception as e:
            logger.error(f"💥 client_to_agent_messaging error: {type(e).__name__}: {e}")
            logger.error(f"🔥 Full traceback: {traceback.format_exc()}")
            raise

    async def run_live_session(
        self,
        websocket,
        agent_id: str,
        external_id: str,
        session_service: DatabaseSessionService,
        artifacts_service: InMemoryArtifactService,
        memory_service: Optional[BaseMemoryService] = None,
        session_id: Optional[str] = None,
        is_audio: bool = False,
        voice_config: Optional[Dict[str, Any]] = None,
        language_code: str = "en-US",
        files: Optional[list] = None,
        metadata: Optional[Dict[str, Any]] = None,
    ):
        """Run a complete live session with WebSocket management."""
        live_request_queue = None

        try:
            # Start agent session
            live_events, live_request_queue = await self.start_agent_session(
                agent_id=agent_id,
                external_id=external_id,
                session_service=session_service,
                artifacts_service=artifacts_service,
                memory_service=memory_service,
                session_id=session_id,
                is_audio=is_audio,
                voice_config=voice_config,
                language_code=language_code,
                files=files,
                metadata=metadata,
            )

            # Create communication tasks
            logger.debug("🎭 Creating asyncio tasks for bidirectional communication...")
            agent_to_client_task = asyncio.create_task(
                self.agent_to_client_messaging(websocket, live_events)
            )
            client_to_agent_task = asyncio.create_task(
                self.client_to_agent_messaging(websocket, live_request_queue)
            )
            logger.debug(
                "🎭 Both tasks created, waiting for completion or exception..."
            )

            # Wait for completion or exception
            tasks = [agent_to_client_task, client_to_agent_task]
            done, pending = await asyncio.wait(
                tasks, return_when=asyncio.FIRST_EXCEPTION
            )
            logger.debug(
                f"⚠️ One or more tasks completed/failed. Done: {len(done)}, Pending: {len(pending)}"
            )

            # Check for exceptions in completed tasks
            for task in done:
                if task.exception():
                    logger.error(
                        f"💥 Task {task.get_name()} failed with exception: {task.exception()}"
                    )
                    logger.error(
                        f"🔥 Full traceback: {traceback.format_exception(type(task.exception()), task.exception(), task.exception().__traceback__)}"
                    )

            # Cancel pending tasks
            for task in pending:
                logger.debug(f"🛑 Cancelling pending task: {task.get_name()}")
                task.cancel()

        except Exception as e:
            logger.error(f"💥 Live session error: {e}")
            logger.error(f"🔥 Full traceback: {traceback.format_exc()}")
            raise

        finally:
            # Clean up resources
            if live_request_queue:
                logger.debug("🔒 Closing LiveRequestQueue...")
                live_request_queue.close()
                logger.debug("✅ LiveRequestQueue closed")
            logger.info(
                f"👋 Live session ended for agent {agent_id}, user {external_id}"
            )
