"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: a2a_agent.py                                                          │
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

from google.adk.agents import BaseAgent
from google.adk.agents.invocation_context import InvocationContext
from google.adk.events import Event
from google.genai.types import Content, Part

from typing import AsyncGenerator, List, Dict, Any, Optional
import json
import os

from src.schemas.a2a_types import AgentCard
from src.utils.a2a_enhanced_client import (
    EnhancedA2AClient,
    A2AClientConfig,
    A2AImplementation,
    A2AResponse,
)

from uuid import uuid4


class A2ACustomAgent(BaseAgent):
    """
    Enhanced A2A agent that uses the official a2a-sdk client.

    This agent automatically detects and uses the best available A2A implementation
    (custom or SDK) and provides better error handling and type validation.
    """

    # Field declarations for Pydantic
    card_url: str
    agent_card: Optional[AgentCard]
    timeout: int
    base_url: str
    api_key: Optional[str]
    preferred_implementation: A2AImplementation

    def __init__(
        self,
        name: str,
        card_url: str,
        timeout: int = 300,
        api_key: Optional[str] = None,
        preferred_implementation: A2AImplementation = A2AImplementation.AUTO,
        sub_agents: List[BaseAgent] = [],
        **kwargs,
    ):
        """
        Initialize the enhanced A2A agent.

        Args:
            name: Agent name
            card_url: A2A agent card URL
            timeout: Maximum execution time (seconds)
            api_key: API key for authentication (if None, will try to get from env)
            preferred_implementation: Preferred A2A implementation (auto, custom, sdk)
            sub_agents: List of sub-agents to be executed after the A2A agent
        """
        # Extract base_url from card_url
        base_url = card_url
        if "/.well-known/agent.json" in base_url:
            base_url = base_url.split("/.well-known/agent.json")[0]

        # Extract base URL for API calls (remove agent-specific parts)
        if "/api/v1/a2a/" in base_url:
            base_url = base_url.split("/api/v1/a2a/")[0]
        elif "/api/v1/a2a-sdk/" in base_url:
            base_url = base_url.split("/api/v1/a2a-sdk/")[0]

        # Get API key from parameter or environment
        if not api_key:
            api_key = os.getenv("EVO_AI_API_KEY") or os.getenv("API_KEY")

        if not api_key:
            print("Warning: No API key provided. This may cause authentication errors.")

        print(f"Enhanced A2A agent initialized for URL: {card_url}")
        print(f"Base URL: {base_url}")
        print(f"Preferred implementation: {preferred_implementation.value}")

        # Initialize base class
        super().__init__(
            name=name,
            card_url=card_url,
            base_url=base_url,
            agent_card=None,
            timeout=timeout,
            api_key=api_key,
            preferred_implementation=preferred_implementation,
            sub_agents=sub_agents,
            **kwargs,
        )

    async def fetch_agent_card(self) -> AgentCard:
        """Fetch the agent card using the enhanced client."""
        if self.agent_card:
            return self.agent_card

        print(f"Fetching agent card from: {self.card_url}")

        try:
            # Extract agent ID from URL
            agent_id = self._extract_agent_id_from_url(self.card_url)

            # Create enhanced client
            config = A2AClientConfig(
                base_url=self.base_url,
                api_key=self.api_key or "default-key",
                implementation=self.preferred_implementation,
                timeout=self.timeout,
            )

            async with EnhancedA2AClient(config) as client:
                response = await client.get_agent_card(agent_id)

                if response.success:
                    print(
                        f"Agent card fetched using {response.implementation_used.value} implementation"
                    )
                    self.agent_card = AgentCard(**response.data)
                    return self.agent_card
                else:
                    raise ValueError(f"Failed to fetch agent card: {response.error}")

        except Exception as e:
            print(f"Error fetching agent card: {e}")
            # Fallback to basic agent card
            self.agent_card = AgentCard(
                name="A2A Agent",
                description="External A2A Agent",
                url=self.card_url,
                version="1.0.0",
                capabilities={"streaming": True},
                defaultInputModes=["text"],
                defaultOutputModes=["text"],
                skills=[],
            )
            return self.agent_card

    def _extract_agent_id_from_url(self, url: str) -> str:
        """Extract agent ID from the agent card URL."""
        try:
            # Handle different URL formats
            if "/api/v1/a2a/" in url:
                # Custom implementation URL
                parts = url.split("/api/v1/a2a/")[1]
                return parts.split("/")[0]
            elif "/api/v1/a2a-sdk/" in url:
                # SDK implementation URL
                parts = url.split("/api/v1/a2a-sdk/")[1]
                return parts.split("/")[0]
            else:
                # Try to extract from path
                path_parts = url.split("/")
                for i, part in enumerate(path_parts):
                    if part in ["a2a", "a2a-sdk"] and i + 1 < len(path_parts):
                        return path_parts[i + 1]

                # Fallback: use last meaningful part
                meaningful_parts = [
                    p
                    for p in path_parts
                    if p and p != ".well-known" and p != "agent.json"
                ]
                return meaningful_parts[-1] if meaningful_parts else "unknown-agent"

        except Exception as e:
            print(f"Error extracting agent ID from URL {url}: {e}")
            return "unknown-agent"

    async def _run_async_impl(
        self, ctx: InvocationContext
    ) -> AsyncGenerator[Event, None]:
        """
        Enhanced A2A implementation using the official SDK client.

        This method uses the EnhancedA2AClient which automatically detects
        and uses the best available implementation (custom or SDK).
        """

        try:
            # 1. Fetch the agent card if we haven't already
            try:
                agent_card = await self.fetch_agent_card()
                print(f"Agent card fetched: {agent_card.name}")
            except Exception as e:
                error_msg = f"Failed to fetch agent card: {str(e)}"
                print(error_msg)
                yield Event(
                    author=self.name,
                    content=Content(role="agent", parts=[Part(text=error_msg)]),
                )
                return

            # 2. Extract the user's message from the context
            user_message = self._extract_user_message(ctx)

            if not user_message:
                error_msg = "No user message found"
                print(error_msg)
                yield Event(
                    author=self.name,
                    content=Content(role="agent", parts=[Part(text=error_msg)]),
                )
                return

            # 3. Extract agent ID and create enhanced client
            agent_id = self._extract_agent_id_from_url(self.card_url)

            config = A2AClientConfig(
                base_url=self.base_url,
                api_key=self.api_key or "default-key",
                implementation=self.preferred_implementation,
                timeout=self.timeout,
            )

            print(f"Sending message to A2A agent {agent_id}: {user_message[:100]}...")

            # 4. Use enhanced client to communicate with the agent
            async with EnhancedA2AClient(config) as client:
                # Use session ID as a stable identifier
                session_id = (
                    str(ctx.session.id)
                    if ctx.session and hasattr(ctx.session, "id")
                    else str(uuid4())
                )

                # Check if the agent supports streaming
                supports_streaming = self._agent_supports_streaming(agent_card)

                if supports_streaming:
                    print("Agent supports streaming, using streaming API")
                    await self._process_streaming_response(
                        client, agent_id, user_message, session_id
                    )
                else:
                    print("Agent does not support streaming, using regular API")
                    await self._process_regular_response(
                        client, agent_id, user_message, session_id
                    )

            # 5. Run sub-agents
            for sub_agent in self.sub_agents:
                async for event in sub_agent.run_async(ctx):
                    yield event

        except Exception as e:
            # Handle any uncaught error
            error_msg = f"Error executing enhanced A2A agent: {str(e)}"
            print(error_msg)
            yield Event(
                author=self.name,
                content=Content(
                    role="agent",
                    parts=[Part(text=error_msg)],
                ),
            )

    def _extract_user_message(self, ctx: InvocationContext) -> Optional[str]:
        """Extract user message from the invocation context."""
        user_message = None

        # Search for the user's message in the session events
        if ctx.session and hasattr(ctx.session, "events") and ctx.session.events:
            for event in reversed(ctx.session.events):
                if event.author == "user" and event.content and event.content.parts:
                    user_message = event.content.parts[0].text
                    print("Message found in session events")
                    break

        # Check in the session state if the message was not found in the events
        if not user_message and ctx.session and ctx.session.state:
            if "user_message" in ctx.session.state:
                user_message = ctx.session.state["user_message"]
            elif "message" in ctx.session.state:
                user_message = ctx.session.state["message"]

        return user_message

    def _agent_supports_streaming(self, agent_card: AgentCard) -> bool:
        """Check if the agent supports streaming."""
        try:
            if hasattr(agent_card, "capabilities"):
                if hasattr(agent_card.capabilities, "streaming"):
                    return agent_card.capabilities.streaming
                elif isinstance(agent_card.capabilities, dict):
                    return agent_card.capabilities.get("streaming", False)
            return False
        except Exception as e:
            print(f"Error checking streaming capability: {e}")
            return False

    async def _process_streaming_response(
        self, client: EnhancedA2AClient, agent_id: str, message: str, session_id: str
    ) -> AsyncGenerator[Event, None]:
        """Process streaming response from the A2A agent."""
        try:
            async for response_chunk in client.send_message_streaming(
                agent_id=agent_id, message=message, session_id=session_id
            ):
                if response_chunk.success:
                    print(
                        f"Streaming chunk received using {response_chunk.implementation_used.value}"
                    )

                    # Extract and yield agent response
                    event = self._create_event_from_response(response_chunk)
                    if event:
                        yield event
                else:
                    print(f"Streaming error: {response_chunk.error}")
                    yield Event(
                        author=self.name,
                        content=Content(
                            role="agent",
                            parts=[
                                Part(text=f"Streaming error: {response_chunk.error}")
                            ],
                        ),
                    )

        except Exception as e:
            error_msg = f"Error in streaming: {str(e)}"
            print(error_msg)
            yield Event(
                author=self.name,
                content=Content(role="agent", parts=[Part(text=error_msg)]),
            )

    async def _process_regular_response(
        self, client: EnhancedA2AClient, agent_id: str, message: str, session_id: str
    ) -> AsyncGenerator[Event, None]:
        """Process regular (non-streaming) response from the A2A agent."""
        try:
            response = await client.send_message(
                agent_id=agent_id, message=message, session_id=session_id
            )

            if response.success:
                print(f"Response received using {response.implementation_used.value}")

                # Extract and yield agent response
                event = self._create_event_from_response(response)
                if event:
                    yield event
                else:
                    yield Event(
                        author=self.name,
                        content=Content(
                            role="agent",
                            parts=[
                                Part(text="Received response without readable content")
                            ],
                        ),
                    )
            else:
                error_msg = f"Request failed: {response.error}"
                print(error_msg)
                yield Event(
                    author=self.name,
                    content=Content(role="agent", parts=[Part(text=error_msg)]),
                )

        except Exception as e:
            error_msg = f"Error in regular request: {str(e)}"
            print(error_msg)
            yield Event(
                author=self.name,
                content=Content(role="agent", parts=[Part(text=error_msg)]),
            )

    def _create_event_from_response(self, response: A2AResponse) -> Optional[Event]:
        """Create an Event from an A2A response."""
        try:
            response_data = response.data

            if not response_data:
                return None

            # Handle different response formats
            parts = []

            # Try to extract message parts from various response structures
            if isinstance(response_data, dict):
                # Handle JSON-RPC response
                if "result" in response_data:
                    result = response_data["result"]

                    # Handle task status with message
                    if isinstance(result, dict) and "status" in result:
                        status = result["status"]
                        if "message" in status and "parts" in status["message"]:
                            message_parts = status["message"]["parts"]
                            for part in message_parts:
                                if part.get("type") == "text" and "text" in part:
                                    parts.append(Part(text=part["text"]))

                    # Handle direct message response
                    elif isinstance(result, dict) and "message" in result:
                        message = result["message"]
                        if isinstance(message, str):
                            parts.append(Part(text=message))
                        elif isinstance(message, dict) and "parts" in message:
                            for part in message["parts"]:
                                if part.get("type") == "text" and "text" in part:
                                    parts.append(Part(text=part["text"]))

                # Handle streaming event format
                elif "data" in response_data:
                    data = response_data["data"]
                    if isinstance(data, str):
                        parts.append(Part(text=data))
                    elif isinstance(data, dict):
                        # Recursively handle nested data
                        nested_event = self._create_event_from_response(
                            A2AResponse(success=True, data=data)
                        )
                        return nested_event

            # If we extracted parts, create the event
            if parts:
                return Event(
                    author=self.name,
                    content=Content(role="agent", parts=parts),
                )

            # Fallback: try to convert response to string
            elif response_data:
                text_content = str(response_data)
                if text_content and text_content != "None":
                    return Event(
                        author=self.name,
                        content=Content(role="agent", parts=[Part(text=text_content)]),
                    )

            return None

        except Exception as e:
            print(f"Error creating event from response: {e}")
            return Event(
                author=self.name,
                content=Content(
                    role="agent",
                    parts=[Part(text=f"Error processing response: {str(e)}")],
                ),
            )
