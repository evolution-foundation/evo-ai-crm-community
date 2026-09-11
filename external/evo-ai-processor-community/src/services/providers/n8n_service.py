"""
N8N provider service for external agent integration.
"""

import logging
from typing import Dict, Any, Optional
import httpx
import base64

logger = logging.getLogger(__name__)


class N8NService:
    """Service for integrating with N8N webhooks."""

    def __init__(self, config: Dict[str, Any]):
        """
        Initialize N8N service.

        Args:
            config: Configuration dictionary with:
                - webhookUrl: URL of the N8N webhook
                - basicAuthUser: Optional username for Basic Auth
                - basicAuthPass: Optional password for Basic Auth
        """
        self.webhook_url = config.get("webhookUrl")
        self.basic_auth_user = config.get("basicAuthUser")
        self.basic_auth_pass = config.get("basicAuthPass")
        
        if not self.webhook_url:
            raise ValueError("N8N webhookUrl is required")

    async def send_message(
        self,
        message: str,
        session_id: str,
        context: Optional[Dict[str, Any]] = None,
    ) -> str:
        """
        Send a message to N8N webhook and get the response.

        Args:
            message: User message
            session_id: Session identifier for conversation continuity
            context: Optional context variables (remoteJid, pushName, etc.)

        Returns:
            Response text from N8N (output or answer field)
        """
        if not self.webhook_url:
            raise ValueError("N8N webhookUrl is not configured")

        # Build payload
        payload: Dict[str, Any] = {
            "chatInput": message,
            "sessionId": session_id,
            "remoteJid": context.get("remoteJid", "") if context else "",
            "pushName": context.get("pushName", "") if context else "",
            "keyId": context.get("keyId", "") if context else "",
            "fromMe": False,
            "quotedMessage": context.get("quotedMessage") if context else None,
            "instanceName": context.get("instanceName", "") if context else "",
            "serverUrl": context.get("serverUrl", "") if context else "",
            "apiKey": context.get("apiKey", "") if context else "",
        }

        # Build headers
        headers: Dict[str, str] = {
            "Content-Type": "application/json",
        }
        
        # Add Basic Auth if configured
        if self.basic_auth_user and self.basic_auth_pass:
            auth_string = f"{self.basic_auth_user}:{self.basic_auth_pass}"
            auth_bytes = auth_string.encode("utf-8")
            auth_b64 = base64.b64encode(auth_bytes).decode("utf-8")
            headers["Authorization"] = f"Basic {auth_b64}"

        try:
            async with httpx.AsyncClient(timeout=30.0) as client:
                response = await client.post(
                    self.webhook_url,
                    json=payload,
                    headers=headers,
                )
                response.raise_for_status()
                
                response_data = response.json()
                # N8N can return either 'output' or 'answer'
                return response_data.get("output") or response_data.get("answer", "")
        except httpx.HTTPStatusError as e:
            logger.error(f"N8N API error: {e.response.status_code} - {e.response.text}")
            raise Exception(f"N8N API error: {e.response.status_code}")
        except Exception as e:
            logger.error(f"Error calling N8N: {e}")
            raise
