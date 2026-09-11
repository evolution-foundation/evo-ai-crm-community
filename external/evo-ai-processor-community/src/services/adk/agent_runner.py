"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: agent_runner.py                                                       │
│ Developed by: Davidson Gomes                                                 │
│ Creation date: May 13, 2025                                                  │
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

from google.adk.sessions import DatabaseSessionService
from google.adk.memory.base_memory_service import BaseMemoryService
from google.adk.artifacts.in_memory_artifact_service import InMemoryArtifactService
from src.services.adk.runners.standard_runner import StandardRunner
from src.services.adk.runners.streaming_runner import StreamingRunner
from src.services.adk.runners.live_runner import LiveRunner
from sqlalchemy.orm import Session
from typing import Optional, AsyncGenerator, Dict, Any


async def run_agent(
    agent_id: str,
    external_id: str,
    message: str,
    session_service: DatabaseSessionService,
    artifacts_service: InMemoryArtifactService,
    memory_service: Optional[BaseMemoryService] = None,
    db: Session = None,
    session_id: Optional[str] = None,
    timeout: float = 60.0,
    files: Optional[list] = None,
    metadata: Optional[Dict[str, Any]] = None,
    user_id: Optional[str] = None,
) -> Dict[str, Any]:
    """Execute a non-streaming agent request."""
    runner = StandardRunner(db)
    return await runner.run_agent(
        agent_id=agent_id,
        external_id=external_id,
        message=message,
        session_service=session_service,
        artifacts_service=artifacts_service,
        memory_service=memory_service,
        session_id=session_id,
        timeout=timeout,
        files=files,
        metadata=metadata,
        user_id=user_id,
    )


async def run_agent_stream(
    agent_id: str,
    external_id: str,
    message: str,
    session_service: DatabaseSessionService,
    artifacts_service: InMemoryArtifactService,
    memory_service: Optional[BaseMemoryService] = None,
    db: Session = None,
    session_id: Optional[str] = None,
    files: Optional[list] = None,
    timeout: float = 60.0,
    metadata: Optional[Dict[str, Any]] = None,
    user_id: Optional[str] = None,
) -> AsyncGenerator[str, None]:
    """Execute the agent with streaming of events."""
    runner = StreamingRunner(db)
    async for event in runner.run_agent_stream(
        agent_id=agent_id,
        external_id=external_id,
        message=message,
        session_service=session_service,
        artifacts_service=artifacts_service,
        memory_service=memory_service,
        session_id=session_id,
        files=files,
        timeout=timeout,
        metadata=metadata,
        user_id=user_id,
    ):
        yield event


async def run_agent_live(
    websocket,
    agent_id: str,
    external_id: str,
    session_service: DatabaseSessionService,
    artifacts_service: InMemoryArtifactService,
    memory_service: Optional[BaseMemoryService] = None,
    db: Session = None,
    session_id: Optional[str] = None,
    is_audio: bool = False,
    voice_config: Optional[Dict[str, Any]] = None,
    language_code: str = "en-US",
    files: Optional[list] = None,
    metadata: Optional[Dict[str, Any]] = None,
):
    """Execute a live agent session with real-time bidirectional communication."""
    runner = LiveRunner(db)
    await runner.run_live_session(
        websocket=websocket,
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


# Backwards compatibility functions - deprecated but maintained
def convert_sets(obj):
    """Convert sets to lists for JSON serialization.

    Deprecated: Use convert_sets from runners.runner_utils instead.
    """
    from src.services.adk.runners.runner_utils import convert_sets as _convert_sets

    return _convert_sets(obj)
