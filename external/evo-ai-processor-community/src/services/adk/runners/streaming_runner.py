"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: streaming_runner.py                                                   │
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

from google.adk.sessions import DatabaseSessionService
from google.adk.memory.base_memory_service import BaseMemoryService
from google.adk.artifacts.in_memory_artifact_service import InMemoryArtifactService
from src.utils.logger import setup_logger
from src.core.exceptions import AgentNotFoundError, InternalServerError
from src.services.adk.runners.runner_utils import RunnerUtils, convert_sets
from src.services.session_service import create_execution_metrics
from src.schemas.schemas import ExecutionMetricsCreate
from sqlalchemy.orm import Session
from typing import Optional, AsyncGenerator, Dict, Any
import asyncio
import json
import uuid

logger = setup_logger(__name__)


class StreamingRunner:
    """Runner for streaming agent execution."""

    def __init__(self, db: Session):
        self.db = db
        self.utils = RunnerUtils(db)

    def _validate_event_content(self, event_dict: Dict[str, Any]) -> Dict[str, Any]:
        """Validate and ensure proper content structure for streaming events."""
        # Ensure proper content structure for valid events
        if "content" in event_dict and event_dict["content"]:
            event_content = event_dict["content"]

            if "role" not in event_content or event_content["role"] not in [
                "user",
                "agent",
            ]:
                event_content["role"] = "agent"

            if "parts" in event_content and event_content["parts"]:
                valid_parts = []
                for part in event_content["parts"]:
                    if isinstance(part, dict):
                        if "type" not in part and "text" in part:
                            part["type"] = "text"
                        valid_parts.append(part)

                if valid_parts:
                    event_content["parts"] = valid_parts
                else:
                    event_content["parts"] = [
                        {"type": "text", "text": "Content without valid format"}
                    ]
            else:
                event_content["parts"] = [
                    {"type": "text", "text": "Content without parts"}
                ]

        return event_dict

    async def run_agent_stream(
        self,
        agent_id: str,
        external_id: str,
        message: str,
        session_service: DatabaseSessionService,
        artifacts_service: InMemoryArtifactService,
        memory_service: Optional[BaseMemoryService] = None,
        session_id: Optional[str] = None,
        files: Optional[list] = None,
        timeout: float = 60.0,
        metadata: Optional[Dict[str, Any]] = None,
        user_id: Optional[str] = None,
    ) -> AsyncGenerator[str, None]:
        """Execute the agent with streaming of events."""
        try:
            logger.info(
                f"Starting streaming execution of agent {agent_id} for external_id {external_id}"
            )

            # Get and build agent
            root_agent, state_params = await self.utils.get_and_build_agent(agent_id)

            # Setup session
            adk_session_id = self.utils.create_session_id(
                external_id, agent_id, session_id
            )

            # Configure Runner
            agent_runner = self.utils.create_runner(
                root_agent, agent_id, session_service, artifacts_service, memory_service
            )

            # Get or create session
            # Use user_id (contact_id) if provided, otherwise fallback to external_id (conversation UUID)
            effective_user_id = user_id if user_id else external_id
            session = await self.utils.get_or_create_session(
                session_service, agent_id, effective_user_id, adk_session_id
            )

            # Setup session state
            await self.utils.setup_session_state(
                session_service, session, message, state_params, metadata
            )

            # Process files
            file_parts, transcribed_texts = await self.utils.process_files(
                files, artifacts_service, agent_id, external_id, adk_session_id
            )

            # Save user message to memory individually (FIFO) before processing
            if memory_service and hasattr(memory_service, "add_event_to_memory"):
                try:
                    # Get agent from database to extract config
                    from src.services.agent_service import get_agent
                    agent = await get_agent(self.db, agent_id)
                    
                    # Check if load_memory is enabled
                    load_memory_enabled = False
                    memory_base_config_id = None
                    short_term_max_messages = None
                    compression_interval = None

                    if agent:
                        if agent.config:
                            agent_config = agent.config if isinstance(agent.config, dict) else {}
                            if isinstance(agent_config, dict):
                                load_memory_enabled = agent_config.get("load_memory", False)
                                memory_base_config_id = agent_config.get("memory_base_config_id")
                                short_term_max_messages = agent_config.get("memory_short_term_max_messages")
                                compression_interval = agent_config.get("memory_medium_term_compression_interval")

                    # Only save to memory if load_memory is enabled
                    if load_memory_enabled:
                        # Combine message with transcribed texts
                        user_content = message
                        if transcribed_texts:
                            user_content += "\n\n" + "\n\n".join(transcribed_texts)

                        if user_content.strip():
                            await memory_service.add_event_to_memory(
                                app_name=agent_id,
                                user_id=effective_user_id,
                                role="user",
                                content=user_content,
                                memory_base_config_id=memory_base_config_id,
                                short_term_max_messages=short_term_max_messages,
                                compression_interval=compression_interval,
                            )
                except Exception as e:
                    logger.debug(f"Could not save user message to memory: {e}")

            # Preload memory if enabled (before processing user message)
            if memory_service:
                try:
                    from src.services.agent_service import get_agent
                    agent = await get_agent(self.db, agent_id)
                    if agent and agent.config:
                        agent_config = agent.config if isinstance(agent.config, dict) else {}
                        if isinstance(agent_config, dict) and agent_config.get("preload_memory") and agent_config.get("load_memory"):
                            logger.info(f"Preloading memory for agent {agent_id}, user {effective_user_id}")
                            # Call memory load endpoint directly via HTTP to get medium_term summaries
                            from src.services.memory_service import HttpMemoryService
                            from src.config.settings import settings
                            import httpx
                            
                            if isinstance(memory_service, HttpMemoryService):
                                memory_base_config_id = agent_config.get("memory_base_config_id")

                                # Call /memory/load endpoint directly (preload mode - empty query returns medium_term summaries)
                                try:
                                    base_url = settings.KNOWLEDGE_SERVICE_URL.rstrip("/")
                                    url = f"{base_url}/memory/load"

                                    params = {
                                        "app_name": agent_id,
                                        "user_id": effective_user_id,
                                        "query": "",  # Empty query loads medium_term summaries
                                        "max_results": 10,
                                    }

                                    headers = {
                                        "Content-Type": "application/json",
                                        "Accept": "application/json",
                                    }
                                    
                                    # Add service token for service-to-service authentication
                                    if settings.KNOWLEDGE_SERVICE_API_TOKEN:
                                        headers["X-Service-Token"] = settings.KNOWLEDGE_SERVICE_API_TOKEN
                                    
                                    if memory_base_config_id:
                                        headers["x-memory-base-config-id"] = str(memory_base_config_id)
                                    
                                    async with httpx.AsyncClient(timeout=30.0) as client:
                                        response = await client.get(url, params=params, headers=headers)
                                        response.raise_for_status()
                                        response_data = response.json()
                                    
                                    memory_results = response_data.get("memories", [])
                                    total = response_data.get("total", 0)
                                    
                                    if memory_results:
                                        logger.info(f"Preloaded {len(memory_results)} memory summaries for agent {agent_id}")
                                        
                                        # Add preloaded memories as system events to the session
                                        # This makes them available to the LLM as context
                                        from google.adk.events import Event
                                        from google.genai.types import Content, Part
                                        import time
                                        
                                        # Combine all memory summaries into a single context message
                                        memory_context_parts = []
                                        memory_context_parts.append("Previous conversation context:\n\n")
                                        
                                        for idx, memory in enumerate(memory_results, 1):
                                            memory_content = memory.get("content", "")
                                            memory_metadata = memory.get("metadata", {})
                                            memory_timestamp = memory.get("timestamp")
                                            
                                            if memory_content:
                                                memory_context_parts.append(f"--- Summary {idx} ---\n")
                                                memory_context_parts.append(f"{memory_content}\n")
                                                if memory_timestamp:
                                                    memory_context_parts.append(f"(Date: {memory_timestamp})\n")
                                                memory_context_parts.append("\n")
                                        
                                        if len(memory_context_parts) > 1:  # More than just the header
                                            memory_context_text = "".join(memory_context_parts).strip()
                                            
                                            # Create a system event with the memory context
                                            memory_event = Event(
                                                invocation_id=f"preload_memory_{int(time.time())}",
                                                author="system",
                                                content=Content(
                                                    role="system",
                                                    parts=[Part(text=memory_context_text)]
                                                ),
                                                timestamp=time.time(),
                                            )
                                            
                                            # Add the event to the session
                                            await session_service.append_event(session, memory_event)
                                            logger.debug(f"Added {len(memory_results)} memory summaries to session context")
                                    else:
                                        logger.debug(f"No memory summaries found for preload (agent {agent_id}, user {effective_user_id})")
                                except Exception as e:
                                    logger.warning(f"Could not preload memory: {e}")
                        
                        # Preload knowledge if enabled (before processing user message)
                        if isinstance(agent_config, dict) and agent_config.get("preload_knowledge") and agent_config.get("load_knowledge"):
                            logger.info(f"Preloading knowledge for agent {agent_id}")
                            try:
                                from src.config.settings import settings
                                import httpx
                                
                                knowledge_tags = agent_config.get("knowledge_tags")
                                knowledge_base_config_id = agent_config.get("knowledge_base_config_id")
                                knowledge_max_results = agent_config.get("knowledge_max_results", 5)

                                # Call /knowledge/search endpoint directly for preload
                                base_url = settings.KNOWLEDGE_SERVICE_URL.rstrip("/")
                                url = f"{base_url}/knowledge/search"

                                # Use a general query for preload context
                                payload = {
                                    "query": "general context and information",
                                    "tags": knowledge_tags or [],
                                    "max_results": knowledge_max_results,
                                }

                                headers = {
                                    "Content-Type": "application/json",
                                    "Accept": "application/json",
                                }
                                
                                # Add service token for service-to-service authentication
                                if settings.KNOWLEDGE_SERVICE_API_TOKEN:
                                    headers["X-Service-Token"] = settings.KNOWLEDGE_SERVICE_API_TOKEN
                                
                                if knowledge_base_config_id:
                                    headers["x-knowledge-base-config-id"] = str(knowledge_base_config_id)
                                
                                async with httpx.AsyncClient(timeout=30.0) as client:
                                    response = await client.post(url, json=payload, headers=headers)
                                    response.raise_for_status()
                                    response_data = response.json()
                                
                                knowledge_results = response_data.get("results", [])
                                total = response_data.get("total", 0)
                                
                                if knowledge_results:
                                    logger.info(f"Preloaded {len(knowledge_results)} knowledge entries for agent {agent_id}")
                                    
                                    # Add preloaded knowledge as system events to the session
                                    from google.adk.events import Event
                                    from google.genai.types import Content, Part
                                    import time
                                    
                                    # Combine all knowledge entries into a single context message
                                    knowledge_context_parts = []
                                    knowledge_context_parts.append("Preloaded knowledge base context:\n\n")
                                    
                                    for idx, result in enumerate(knowledge_results, 1):
                                        knowledge = result.get("knowledge", {})
                                        knowledge_title = knowledge.get("title", "")
                                        knowledge_content = knowledge.get("content", "")
                                        knowledge_description = knowledge.get("description", "")
                                        
                                        if knowledge_content:
                                            knowledge_context_parts.append(f"--- Knowledge Entry {idx} ---\n")
                                            if knowledge_title:
                                                knowledge_context_parts.append(f"Title: {knowledge_title}\n")
                                            if knowledge_description:
                                                knowledge_context_parts.append(f"Description: {knowledge_description}\n")
                                            knowledge_context_parts.append(f"Content: {knowledge_content}\n")
                                            knowledge_context_parts.append("\n")
                                    
                                    if len(knowledge_context_parts) > 1:  # More than just the header
                                        knowledge_context_text = "".join(knowledge_context_parts).strip()
                                        
                                        # Create a system event with the knowledge context
                                        knowledge_event = Event(
                                            invocation_id=f"preload_knowledge_{int(time.time())}",
                                            author="system",
                                            content=Content(
                                                role="system",
                                                parts=[Part(text=knowledge_context_text)]
                                            ),
                                            timestamp=time.time(),
                                        )
                                        
                                        # Add the event to the session
                                        await session_service.append_event(session, knowledge_event)
                                        logger.debug(f"Added {len(knowledge_results)} knowledge entries to session context")
                                else:
                                    logger.debug(f"No knowledge entries found for preload (agent {agent_id})")
                            except Exception as e:
                                logger.warning(f"Could not preload knowledge: {e}")
                except Exception as e:
                    logger.debug(f"Could not check preload config: {e}")

            # Create content with transcribed audio if available
            if transcribed_texts:
                content = self.utils.create_content_with_transcribed_audio(
                    message, file_parts, transcribed_texts
                )
            else:
                content = self.utils.create_content(message, file_parts)

            # If content is None (empty message/transcription), skip processing
            if content is None:
                logger.info(
                    "No meaningful content to process, skipping agent execution"
                )
                yield json.dumps(
                    {
                        "role": "system",
                        "content": {
                            "role": "agent",
                            "parts": [
                                {"type": "text", "text": "No content to process"}
                            ],
                        },
                    }
                )
                return

            logger.info("Starting agent streaming execution")

            try:
                total_prompt_tokens = 0
                total_candidate_tokens = 0
                total_tokens = 0
                # Start the agent execution
                events_async = agent_runner.run_async(
                    user_id=effective_user_id,
                    session_id=adk_session_id,
                    new_message=content,
                )

                # Stream events
                async for event in events_async:
                    try:
                        if event.usage_metadata:
                            total_prompt_tokens += (
                                event.usage_metadata.prompt_token_count or 0
                            )
                            total_candidate_tokens += (
                                event.usage_metadata.candidates_token_count or 0
                            )
                            total_tokens += event.usage_metadata.total_token_count or 0

                        # Handle both Pydantic v2 (model_dump) and older versions
                        if hasattr(event, "model_dump"):
                            event_dict = event.model_dump()
                        elif hasattr(event, "dict"):
                            event_dict = event.dict()
                        else:
                            event_dict = event.__dict__
                        event_dict = convert_sets(event_dict)

                        # Validate and fix event content structure
                        event_dict = self._validate_event_content(event_dict)

                        # Save event to memory individually (FIFO) if it has content
                        if memory_service and hasattr(memory_service, "add_event_to_memory"):
                            try:
                                if event.content and event.content.parts:
                                    # Extract text from event
                                    event_text = ""
                                    for part in event.content.parts:
                                        if hasattr(part, "text") and part.text:
                                            event_text += part.text + " "
                                    event_text = event_text.strip()
                                    
                                    if event_text:
                                        # Get agent from database to check if load_memory is enabled
                                        from src.services.agent_service import get_agent
                                        agent = await get_agent(self.db, agent_id)
                                        
                                        # Check if load_memory is enabled
                                        load_memory_enabled = False
                                        memory_base_config_id = None
                                        short_term_max_messages = None
                                        compression_interval = None

                                        if agent:
                                            if agent.config:
                                                agent_config = agent.config if isinstance(agent.config, dict) else {}
                                                if isinstance(agent_config, dict):
                                                    load_memory_enabled = agent_config.get("load_memory", False)
                                                    memory_base_config_id = agent_config.get("memory_base_config_id")
                                                    short_term_max_messages = agent_config.get("memory_short_term_max_messages")
                                                    compression_interval = agent_config.get("memory_medium_term_compression_interval")

                                        # Only save to memory if load_memory is enabled
                                        if load_memory_enabled:
                                            # Determine role (agent response)
                                            role = "agent"

                                            await memory_service.add_event_to_memory(
                                                app_name=agent_id,
                                                user_id=effective_user_id,
                                                role=role,
                                                content=event_text,
                                                memory_base_config_id=memory_base_config_id,
                                                short_term_max_messages=short_term_max_messages,
                                                compression_interval=compression_interval,
                                            )
                            except Exception as e:
                                logger.debug(f"Could not save event to memory: {e}")

                        yield json.dumps(event_dict)

                    except (GeneratorExit, asyncio.CancelledError):
                        logger.info("Client disconnected, stopping stream")
                        break
                    except Exception as e:
                        logger.error(f"Error processing event: {e}")
                        continue

                logger.info(
                    f"Session tokens: {total_tokens} (prompt={total_prompt_tokens},"
                    f" candidates={total_candidate_tokens})"
                )

                # Create execution metrics
                try:
                    # Handle both Pydantic v2 (model_dump) and older versions
                    if hasattr(root_agent.model, "model_dump"):
                        model_dict = root_agent.model.model_dump()
                    elif hasattr(root_agent.model, "dict"):
                        model_dict = root_agent.model.dict()
                    else:
                        model_dict = root_agent.model.__dict__
                    model_str = model_dict.get("model", str(root_agent.model))
                    metrics_data = ExecutionMetricsCreate(
                        agent_id=uuid.UUID(agent_id),
                        session_id=adk_session_id,
                        user_id=effective_user_id,
                        llm_model=str(model_str),
                        prompt_tokens=total_prompt_tokens,
                        candidate_tokens=total_candidate_tokens,
                        cost=0.0,
                        total_tokens=total_tokens,
                    )
                    create_execution_metrics(self.db, metrics_data)
                except Exception as e:
                    logger.error(f"Error creating execution metrics: {e}")

                # Note: We no longer save the entire session to memory at the end
                # Events are saved individually during execution (FIFO)
                logger.info("Agent streaming execution completed successfully")

            except (GeneratorExit, asyncio.CancelledError):
                logger.info("Client disconnected during streaming")
                return
            except Exception as e:
                logger.error(f"Error in streaming: {str(e)}")
                error_message = f"Error: {str(e)}"
                try:
                    yield json.dumps(
                        {
                            "role": "system",
                            "content": {
                                "role": "agent",
                                "parts": [{"type": "text", "text": error_message}],
                            },
                        }
                    )
                except (GeneratorExit, asyncio.CancelledError):
                    return
                raise InternalServerError(str(e)) from e

        except AgentNotFoundError as e:
            logger.error(f"Agent not found: {str(e)}")
            raise AgentNotFoundError(str(e))
        except Exception as e:
            logger.error(f"Internal error processing request: {str(e)}", exc_info=True)
            raise InternalServerError(str(e))
