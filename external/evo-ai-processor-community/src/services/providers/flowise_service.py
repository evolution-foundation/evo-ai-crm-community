"""
Flowise provider service for external agent integration.
"""

import logging
from typing import Dict, Any, Optional
import httpx

logger = logging.getLogger(__name__)


class FlowiseService:
    """Service for integrating with Flowise chatflows."""

    def __init__(self, config: Dict[str, Any]):
        """
        Initialize Flowise service.

        Args:
            config: Configuration dictionary with:
                - apiUrl: Full URL of the Flowise chatflow endpoint
                - apiKey: Optional API key for authentication
        """
        self.api_url = config.get("apiUrl")
        self.api_key = config.get("apiKey")
        
        if not self.api_url:
            raise ValueError("Flowise apiUrl is required")

    async def send_message(
        self,
        message: str,
        session_id: str,
        context: Optional[Dict[str, Any]] = None,
    ) -> str:
        """
        Send a message to Flowise and get the response.

        Args:
            message: User message
            session_id: Session identifier for conversation continuity
            context: Optional context variables (remoteJid, pushName, etc.)

        Returns:
            Response text from Flowise
        """
        if not self.api_url:
            raise ValueError("Flowise apiUrl is not configured")

        # Build payload
        payload: Dict[str, Any] = {
            "question": message,
            "overrideConfig": {
                "sessionId": session_id,
                "vars": {
                    "remoteJid": context.get("remoteJid", "") if context else "",
                    "pushName": context.get("pushName", "") if context else "",
                    "instanceName": context.get("instanceName", "") if context else "",
                    "serverUrl": context.get("serverUrl", "") if context else "",
                    "apiKey": context.get("apiKey", "") if context else "",
                },
            },
        }

        # Build headers
        headers: Dict[str, str] = {
            "Content-Type": "application/json",
        }
        
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"

        try:
            async with httpx.AsyncClient(timeout=30.0) as client:
                response = await client.post(
                    self.api_url,
                    json=payload,
                    headers=headers,
                )
                response.raise_for_status()
                
                response_data = response.json()
                return response_data.get("text", "")
        except httpx.HTTPStatusError as e:
            logger.error(f"Flowise API error: {e.response.status_code} - {e.response.text}")
            raise Exception(f"Flowise API error: {e.response.status_code}")
        except Exception as e:
            logger.error(f"Error calling Flowise: {e}")
            raise
