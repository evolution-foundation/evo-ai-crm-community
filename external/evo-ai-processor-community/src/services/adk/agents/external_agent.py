"""
External agent for integrating with external providers (Flowise, N8N, Typebot, Dify, OpenAI).
"""

from google.adk.agents import BaseAgent
from google.adk.agents.invocation_context import InvocationContext
from google.adk.events import Event
from google.genai.types import Content, Part
from sqlalchemy.orm import Session
from typing import AsyncGenerator, Dict, Any
import logging
import json

from src.services.providers import (
    FlowiseService,
    N8NService,
    DifyService,
    OpenAIService,
    TypebotService,
)

logger = logging.getLogger(__name__)


class ExternalAgent(BaseAgent):
    """
    Custom agent that integrates with external providers.
    
    This agent implements the interaction with external AI services
    like Flowise, N8N, Typebot, Dify, and OpenAI.
    """

    # Field declarations for Pydantic
    provider: str
    integration_config: Dict[str, Any]
    db: Session
    provider_service: Any = None

    def __init__(
        self,
        name: str,
        provider: str,
        integration_config: Dict[str, Any],
        db: Session,
        sub_agents: list = [],
        **kwargs,
    ):
        """
        Initialize the External agent.

        Args:
            name: Agent name
            provider: Provider name ('flowise', 'n8n', 'typebot', 'dify', 'openai')
            integration_config: Configuration from evo_core_agent_integrations.config
            db: Database session
            sub_agents: List of sub-agents to be executed after the External agent
        """
        super().__init__(
            name=name,
            provider=provider,
            integration_config=integration_config,
            db=db,
            sub_agents=sub_agents,
            **kwargs,
        )
        
        # Initialize provider service
        self.provider_service = self._create_provider_service(provider, integration_config)

    def _create_provider_service(self, provider: str, config: Dict[str, Any]):
        """Create the appropriate provider service instance."""
        try:
            if provider == "flowise":
                return FlowiseService(config)
            elif provider == "n8n":
                return N8NService(config)
            elif provider == "dify":
                return DifyService(config)
            elif provider == "openai":
                return OpenAIService(config)
            elif provider == "typebot":
                return TypebotService(config)
            else:
                raise ValueError(f"Unknown provider: {provider}")
        except Exception as e:
            logger.error(f"Error creating provider service for {provider}: {e}")
            raise

    async def _run_async_impl(
        self, ctx: InvocationContext
    ) -> AsyncGenerator[Event, None]:
        """
        Implementation of the External agent.

        This method sends the user's message to the external provider
        and returns the response as events.
        """
        try:
            # Extract the user's message from the context
            user_message = None

            # Search for the user's message in the session events
            if ctx.session and hasattr(ctx.session, "events") and ctx.session.events:
                for event in reversed(ctx.session.events):
                    if event.author == "user" and event.content and event.content.parts:
                        user_message = event.content.parts[0].text
                        break

            # Check in the session state if the message was not found in the events
            if not user_message and ctx.session and ctx.session.state:
                if "user_message" in ctx.session.state:
                    user_message = ctx.session.state["user_message"]
                elif "message" in ctx.session.state:
                    user_message = ctx.session.state["message"]

            if not user_message:
                yield Event(
                    author=self.name,
                    content=Content(
                        role="agent",
                        parts=[Part(text="User message not found")],
                    ),
                )
                return

            # Get session ID from context
            session_id = self._get_session_id(ctx)

            # Build context for provider
            provider_context = self._build_provider_context(ctx, session_id)

            # Send message to provider
            try:
                provider_response = await self.provider_service.send_message(
                    message=user_message,
                    session_id=session_id,
                    context=provider_context,
                )

                response_text = provider_response
                structured = None
                if isinstance(provider_response, dict):
                    response_text = provider_response.get("text", "")
                    structured = provider_response.get("structured")

                parts = [Part(text=str(response_text) if response_text is not None else "")]
                if structured is not None:
                    parts.append(Part(text=f"EVO_STRUCTURED:{json.dumps(structured, ensure_ascii=False)}"))

                # Yield response event
                yield Event(
                    author=self.name,
                    content=Content(
                        role="agent",
                        parts=parts,
                    ),
                )

                # Execute sub-agents if any
                for sub_agent in self.sub_agents:
                    async for event in sub_agent.run_async(ctx):
                        yield event

            except Exception as e:
                logger.error(f"Error calling provider {self.provider}: {e}")
                yield Event(
                    author=f"{self.name}-error",
                    content=Content(
                        role="agent",
                        parts=[Part(text=f"Error calling {self.provider}: {str(e)}")],
                    ),
                )

        except Exception as e:
            logger.error(f"Error in ExternalAgent._run_async_impl: {e}")
            yield Event(
                author=f"{self.name}-error",
                content=Content(
                    role="agent",
                    parts=[Part(text=f"Error processing external agent: {str(e)}")],
                ),
            )

    def _get_session_id(self, ctx: InvocationContext) -> str:
        """Get or generate session ID from context."""
        if ctx.session and ctx.session.id:
            return ctx.session.id

        if ctx.session and ctx.session.state:
            session_id = ctx.session.state.get("session_id")
            if session_id:
                return session_id

        import uuid
        return str(uuid.uuid4())

    def _build_provider_context(self, ctx: InvocationContext, session_id: str) -> Dict[str, Any]:
        """Build context dictionary for provider."""
        context: Dict[str, Any] = {
            "sessionId": session_id,
        }

        # Extract additional context from session state if available
        if ctx.session and ctx.session.state:
            context.update({
                "remoteJid": ctx.session.state.get("remoteJid", ""),
                "pushName": ctx.session.state.get("pushName", ""),
                "instanceName": ctx.session.state.get("instanceName", ""),
                "serverUrl": ctx.session.state.get("serverUrl", ""),
                "apiKey": ctx.session.state.get("apiKey", ""),
                "ownerJid": ctx.session.state.get("ownerJid", ""),
            })

        return context
