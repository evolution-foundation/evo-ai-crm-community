"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: memory_service.py                                                     │
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

import uuid
from typing import TYPE_CHECKING, Optional, Dict, Any, Union
from google.adk.memory.base_memory_service import BaseMemoryService
from google.adk.memory.memory_entry import MemoryEntry
from google.adk.memory.base_memory_service import SearchMemoryResponse
from google.genai import types
from src.config.settings import settings
from src.utils.logger import setup_logger
from src.utils.http import http_client, HttpError

if TYPE_CHECKING:
    from google.adk.sessions.session import Session as ADKSession

logger = setup_logger(__name__)


class HttpMemoryService(BaseMemoryService):
    """HTTP-based memory service that uses the knowledge microservice.
    
    This service implements BaseMemoryService and delegates all operations
    to the knowledge service via HTTP API calls.
    """

    def __init__(self, base_url: str = None, auth_token: Optional[str] = None, token_type: str = "bearer"):
        """Initialize the HTTP memory service.
        
        Args:
            base_url: Base URL for the knowledge service (defaults to settings.KNOWLEDGE_SERVICE_URL)
            auth_token: Optional authentication token for service-to-service calls
            token_type: Type of auth token ('bearer' or 'api_access_token')
        """
        super().__init__()
        self.base_url = (base_url or settings.CORE_SERVICE_URL).rstrip("/")
        self.auth_token = auth_token
        self.token_type = token_type
        # Store last used memory_base_config_id for search operations
        self._last_memory_base_config_id: Optional[Union[str, uuid.UUID]] = None
        logger.info(f"HttpMemoryService initialized with base_url: {self.base_url}")

    def _get_headers(self) -> Dict[str, str]:
        """Build headers for HTTP requests.
        
        Returns:
            Dictionary with headers
        """
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json"
        }
        
        # Add service token if available (for service-to-service calls)
        if settings.EVOAI_CRM_API_TOKEN:
            headers["X-Service-Token"] = settings.EVOAI_CRM_API_TOKEN
            logger.debug(f"Added X-Service-Token header for memory request")
        else:
            logger.warning("EVOAI_CRM_API_TOKEN not configured - service-to-service calls may fail")
        
        # Add authentication header if token provided (overrides service token)
        if self.auth_token:
            if self.token_type == "bearer":
                headers["Authorization"] = f"Bearer {self.auth_token}"
            elif self.token_type == "api_access_token":
                headers["api_access_token"] = self.auth_token
            elif self.token_type == "service_token":
                headers["X-Service-Token"] = self.auth_token
        
        return headers

    async def add_session_to_memory(
        self,
        session: "ADKSession",
        db: Optional[Any] = None,
        short_term_max_messages: Optional[int] = None,
        compression_interval: Optional[int] = None,
        memory_base_config_id: Optional[Union[str, uuid.UUID]] = None,
    ) -> None:
        """Add session to memory via HTTP.
        
        Args:
            session: The ADK session to add to memory
            db: Database session (not used in HTTP implementation)
            short_term_max_messages: Maximum messages in short-term memory before compression
            compression_interval: Compress every N messages to medium-term memory
            memory_base_config_id: Optional UUID of the memory base configuration to use
        """
        try:
            # Extract information from session
            app_name = getattr(session, "app_name", None) or getattr(session, "agent_id", None)
            user_id = getattr(session, "user_id", None) or getattr(session, "client_id", None)
            
            if not app_name or not user_id:
                logger.warning(f"Cannot add session to memory: missing app_name or user_id")
                return
            

            
            # Get session content (messages, etc.) - extract all messages from the session events
            # The session.events contains all events including user and agent messages
            content_parts = []
            
            # First, try to get from session events (most reliable - contains all messages)
            if hasattr(session, "events") and session.events:
                for event in session.events:
                    author = getattr(event, "author", "user")
                    # Skip system events
                    if author == "system":
                        continue
                    
                    # Extract text from event content
                    text = ""
                    if hasattr(event, "content") and event.content:
                        content_obj = event.content
                        if hasattr(content_obj, "parts") and content_obj.parts:
                            # Extract text from parts
                            text_parts = []
                            for part in content_obj.parts:
                                if hasattr(part, "text") and part.text:
                                    text_parts.append(part.text)
                            text = " ".join(text_parts)
                        elif hasattr(content_obj, "text"):
                            text = content_obj.text
                    
                    # Only add non-empty messages
                    if text and text.strip():
                        # Map author to role (user or agent)
                        role = "user" if author == "user" else "agent"
                        content_parts.append(f"{role}: {text}")
            
            # Fallback: try session.messages if events not available
            if not content_parts and hasattr(session, "messages") and session.messages:
                for msg in session.messages:
                    role = getattr(msg, "role", "user")
                    text = getattr(msg, "content", "")
                    if isinstance(text, list):
                        # Handle Content with parts
                        text = " ".join([getattr(p, "text", "") for p in text if hasattr(p, "text")])
                    elif hasattr(text, "text"):
                        # Handle Content object directly
                        text = text.text
                    elif not isinstance(text, str):
                        # Fallback: convert to string
                        text = str(text)
                    if text and text.strip():
                        content_parts.append(f"{role}: {text}")
            
            # Last fallback: try session history
            if not content_parts and hasattr(session, "history") and session.history:
                for entry in session.history:
                    role = getattr(entry, "role", "user")
                    content = getattr(entry, "content", "")
                    if content and str(content).strip():
                        content_parts.append(f"{role}: {content}")
            
            content = "\n".join(content_parts) if content_parts else "Session memory"
            
            logger.debug(f"Extracted {len(content_parts)} messages from session for memory storage")
            
            # Extract metadata
            metadata = {}
            if hasattr(session, "metadata"):
                metadata = session.metadata
            elif hasattr(session, "state"):
                metadata = dict(session.state)
            
            # Call knowledge service HTTP API
            url = f"{self.base_url}/memory"
            payload = {
                "app_name": str(app_name),
                "user_id": str(user_id),
                "content": content,
                "metadata": metadata,
                "session_id": getattr(session, "id", None) or getattr(session, "session_id", None)
            }
            
            # Add compression parameters if provided
            if short_term_max_messages is not None:
                payload["short_term_max_messages"] = short_term_max_messages
            if compression_interval is not None:
                payload["compression_interval"] = compression_interval
            
            # Build headers with memory_base_config_id
            headers = self._get_headers()
            
            # Add memory_base_config_id header if provided
            if memory_base_config_id:
                if isinstance(memory_base_config_id, uuid.UUID):
                    headers["x-memory-base-config-id"] = str(memory_base_config_id)
                else:
                    headers["x-memory-base-config-id"] = str(memory_base_config_id)
                logger.debug(f"Using memory base config ID: {memory_base_config_id}")
            
            logger.info(f"Adding session to memory via HTTP: app={app_name}, user={user_id}, memory_base_config_id={memory_base_config_id}")
            
            response = await http_client.do_post_json(
                url=url,
                payload=payload,
                headers=headers,
                expected_status=201
            )
            
            logger.info(f"Successfully added session to memory: {response}")
            
        except HttpError as e:
            logger.error(f"HTTP error adding session to memory: {e.message} (status: {e.status_code})")
            # Don't raise - memory addition failures shouldn't break agent execution
        except Exception as e:
            logger.error(f"Error adding session to memory: {e}")
            # Don't raise - memory addition failures shouldn't break agent execution

    async def add_event_to_memory(
        self,
        app_name: str,
        user_id: str,
        role: str,
        content: str,
        memory_base_config_id: Optional[Union[str, uuid.UUID]] = None,
        short_term_max_messages: Optional[int] = None,
        compression_interval: Optional[int] = None,
    ) -> None:
        """Add a single event to memory via HTTP (FIFO - removes oldest when limit reached).
        
        Args:
            app_name: Application name (usually agent_id)
            user_id: User ID
            role: Role of the message ('user' or 'agent')
            content: Content of the message
            memory_base_config_id: Optional UUID of the memory base configuration to use
            short_term_max_messages: Maximum messages before removing oldest (FIFO)
            compression_interval: Compress every N messages into medium-term memory (optional)
        """
        try:
            if not app_name or not user_id or not content:
                logger.warning(f"Cannot add event to memory: missing required fields")
                return
            
            self._last_memory_base_config_id = memory_base_config_id
            
            logger.debug(f"Adding event to memory: app={app_name}, user={user_id}, role={role}")
            
            # Call knowledge service HTTP API
            url = f"{self.base_url}/memory/event"
            payload = {
                "app_name": str(app_name),
                "user_id": str(user_id),
                "role": role,
                "content": content,
            }
            
            # Add max_messages parameter if provided (for FIFO limit)
            if short_term_max_messages is not None:
                payload["max_messages"] = short_term_max_messages
            
            # Add compression_interval parameter if provided (for compression)
            if compression_interval is not None:
                payload["compression_interval"] = compression_interval
            
            # Build headers with memory_base_config_id
            headers = self._get_headers()
            
            # Add memory_base_config_id header if provided
            if memory_base_config_id:
                if isinstance(memory_base_config_id, uuid.UUID):
                    headers["x-memory-base-config-id"] = str(memory_base_config_id)
                else:
                    headers["x-memory-base-config-id"] = str(memory_base_config_id)
                logger.debug(f"Using memory base config ID: {memory_base_config_id}")
            
            response = await http_client.do_post_json(
                url=url,
                payload=payload,
                headers=headers,
                expected_status=201
            )
            
            logger.debug(f"Successfully added event to memory: {response}")
            
        except HttpError as e:
            logger.error(f"HTTP error adding event to memory: {e.message} (status: {e.status_code})")
            # Don't raise - memory addition failures shouldn't break agent execution
        except Exception as e:
            logger.error(f"Error adding event to memory: {e}")
            # Don't raise - memory addition failures shouldn't break agent execution

    async def search_memory(
        self,
        *,
        app_name: str,
        user_id: str,
        query: str,
        max_results: int = 10,
        db: Optional[Any] = None,
        memory_base_config_id: Optional[Union[str, uuid.UUID]] = None,
    ) -> SearchMemoryResponse:
        """Search memory via HTTP.
        
        Args:
            app_name: Application name (usually agent_id)
            user_id: User ID to search memories for
            query: Search query
            max_results: Maximum number of results
            db: Database session (not used in HTTP implementation)
            memory_base_config_id: Optional memory base config ID (will use last stored if not provided)
            
        Returns:
            SearchMemoryResponse with search results
        """
        try:
            effective_memory_base_config_id = memory_base_config_id or self._last_memory_base_config_id
            
            # Call knowledge service HTTP API
            url = f"{self.base_url}/memory/search"
            payload = {
                "app_name": app_name,
                "user_id": user_id,
                "query": query,
                "max_results": max_results
            }
            
            # Build headers with memory_base_config_id
            headers = self._get_headers()
            if effective_memory_base_config_id:
                if isinstance(effective_memory_base_config_id, uuid.UUID):
                    headers["x-memory-base-config-id"] = str(effective_memory_base_config_id)
                else:
                    headers["x-memory-base-config-id"] = str(effective_memory_base_config_id)
            
            logger.info(f"Searching memory via HTTP: app={app_name}, user={user_id}, query='{query}', memory_base_config_id={effective_memory_base_config_id}")
            
            response_data = await http_client.do_post_json(
                url=url,
                payload=payload,
                headers=headers,
                expected_status=200
            )
            
            # Convert response to SearchMemoryResponse
            memories = []
            for mem_data in response_data.get("memories", []):
                # Convert content string to Content object
                content_text = mem_data.get("content", "")
                content_obj = types.Content(
                    role=mem_data.get("metadata", {}).get("role", "user"),
                    parts=[types.Part(text=content_text)]
                )
                
                memory_entry = MemoryEntry(
                    content=content_obj,
                    metadata=mem_data.get("metadata", {}),
                    timestamp=mem_data.get("timestamp"),
                    score=mem_data.get("score")
                )
                memories.append(memory_entry)
            
            logger.info(f"Memory search returned {len(memories)} results")
            
            return SearchMemoryResponse(
                memories=memories,
                total=response_data.get("total", len(memories)),
                query=response_data.get("query", query)
            )
            
        except HttpError as e:
            logger.error(f"HTTP error searching memory: {e.message} (status: {e.status_code})")
            # Return empty results on error
            return SearchMemoryResponse(
                memories=[],
                total=0,
                query=query
            )
        except Exception as e:
            logger.error(f"Error searching memory: {e}")
            # Return empty results on error
            return SearchMemoryResponse(
                memories=[],
                total=0,
                query=query
            )

    async def clear_user_memory(self, app_name: str, user_id: str) -> None:
        """Clear user memory via HTTP.
        
        Args:
            app_name: Application name (usually agent_id)
            user_id: User ID to clear memories for
        """
        try:
            # Call knowledge service HTTP API
            url = f"{self.base_url}/memory/{app_name}/{user_id}"
            
            logger.info(f"Clearing memory via HTTP: app={app_name}, user={user_id}")
            
            await http_client.do_delete_json(
                url=url,
                payload=None,
                headers=self._get_headers(),
                expected_status=200
            )
            
            logger.info(f"Successfully cleared memory for app={app_name}, user={user_id}")
            
        except HttpError as e:
            logger.error(f"HTTP error clearing memory: {e.message} (status: {e.status_code})")
            # Don't raise - memory clearing failures shouldn't break agent execution
        except Exception as e:
            logger.error(f"Error clearing memory: {e}")

    def get_health_status(self) -> Dict[str, Any]:
        """Get health status of the memory service.
        
        Returns:
            Dict containing health status information
        """
        try:
            # Try to call health endpoint
            url = f"{self.base_url}/memory/health/status"
            # Note: This would need to be synchronous or we'd need to use asyncio.run
            # For now, just return status based on configuration
            return {
                "status": "healthy",
                "service": "HttpMemoryService",
                "base_url": self.base_url,
                "type": "http"
            }
        except Exception as e:
            return {
                "status": "unhealthy",
                "service": "HttpMemoryService",
                "error": str(e),
                "type": "http"
            }


# Create HTTP memory service instance
memory_service = HttpMemoryService()

# For backward compatibility
MemoryService = type(memory_service)
