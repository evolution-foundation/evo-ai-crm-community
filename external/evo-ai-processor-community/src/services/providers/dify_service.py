"""
Dify provider service for external agent integration.
"""

import logging
from typing import Dict, Any, Optional
import httpx

logger = logging.getLogger(__name__)


class DifyService:
    """Service for integrating with Dify AI platform."""

    def __init__(self, config: Dict[str, Any]):
        """
        Initialize Dify service.

        Args:
            config: Configuration dictionary with:
                - apiUrl: Base URL of Dify API (e.g., https://api.dify.ai/v1)
                - apiKey: API key for authentication
                - botType: Type of bot ('chatBot', 'textGenerator', or 'agent')
        """
        self.api_url = config.get("apiUrl")
        self.api_key = config.get("apiKey")
        self.bot_type = config.get("botType", "chatBot")
        
        if not self.api_url:
            raise ValueError("Dify apiUrl is required")
        if not self.api_key:
            raise ValueError("Dify apiKey is required")
        if self.bot_type not in ["chatBot", "textGenerator", "agent"]:
            raise ValueError(f"Invalid botType: {self.bot_type}. Must be 'chatBot', 'textGenerator', or 'agent'")

    async def send_message(
        self,
        message: str,
        session_id: str,
        context: Optional[Dict[str, Any]] = None,
    ) -> str:
        """
        Send a message to Dify and get the response.

        Args:
            message: User message
            session_id: Session identifier for conversation continuity
            context: Optional context variables (remoteJid, pushName, etc.)

        Returns:
            Response text from Dify
        """
        if not self.api_url or not self.api_key:
            raise ValueError("Dify apiUrl and apiKey are required")

        # Determine endpoint based on bot type
        if self.bot_type == "chatBot":
            endpoint = f"{self.api_url}/chat-messages"
        elif self.bot_type == "textGenerator":
            endpoint = f"{self.api_url}/completion-messages"
        else:  # agent
            endpoint = f"{self.api_url}/chat-messages"

        # Build payload
        payload: Dict[str, Any] = {
            "inputs": {
                "remoteJid": context.get("remoteJid", "") if context else "",
                "pushName": context.get("pushName", "") if context else "",
                "instanceName": context.get("instanceName", "") if context else "",
                "serverUrl": context.get("serverUrl", "") if context else "",
                "apiKey": context.get("apiKey", "") if context else "",
            },
            "query": message,
            "response_mode": "streaming" if self.bot_type == "agent" else "blocking",
            "conversation_id": session_id if session_id and session_id != "new" else None,
            "user": context.get("remoteJid", session_id) if context else session_id,
        }

        # For textGenerator, move query to inputs
        if self.bot_type == "textGenerator":
            payload["inputs"]["query"] = message
            del payload["query"]

        headers: Dict[str, str] = {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json",
        }

        try:
            async with httpx.AsyncClient(timeout=60.0) as client:
                response = await client.post(
                    endpoint,
                    json=payload,
                    headers=headers,
                )
                response.raise_for_status()
                
                # Handle streaming response for agent type
                if self.bot_type == "agent":
                    return self._process_streaming_response(response.text)
                else:
                    response_data = response.json()
                    return response_data.get("answer", "")
        except httpx.HTTPStatusError as e:
            logger.error(f"Dify API error: {e.response.status_code} - {e.response.text}")
            raise Exception(f"Dify API error: {e.response.status_code}")
        except Exception as e:
            logger.error(f"Error calling Dify: {e}")
            raise

    def _process_streaming_response(self, response_text: str) -> str:
        """
        Process streaming SSE response from Dify agent.

        Args:
            response_text: Raw SSE response text

        Returns:
            Concatenated answer text
        """
        answer = ""
        conversation_id = None
        
        # Remove 'data: ' prefix and split by newlines
        data = response_text.replace("data: ", "")
        events = [line.strip() for line in data.split("\n") if line.strip()]
        
        for event_string in events:
            if event_string.startswith("{"):
                try:
                    import json
                    event = json.loads(event_string)
                    
                    if event.get("event") == "agent_message":
                        conversation_id = conversation_id or event.get("conversation_id")
                        answer += event.get("answer", "")
                except json.JSONDecodeError:
                    logger.warning(f"Failed to parse SSE event: {event_string}")
                    continue
        
        return answer
