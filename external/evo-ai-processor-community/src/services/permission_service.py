"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: permission_service.py                                                 │
│ Developed by: Davidson Gomes                                                 │
│ Creation date: January 27, 2025                                              │
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

from typing import Optional
from fastapi import HTTPException, Request
from src.utils.logger import setup_logger
from src.services.evo_auth_service import EvoAuthService

logger = setup_logger(__name__)

class PermissionService:
    """Permission validation service for FastAPI
    
    Delegates permission checks to EvoAuthService for consistent behavior
    across all authentication and authorization operations.
    """
    
    # Permissions an agent-bot key may exercise on its OWN agent. A bot key is
    # a runtime credential: it exists to let the agent be invoked and to read
    # its own conversational state. Management/credential actions (integrations
    # connect/read/update/disconnect/create, tool config, session lifecycle
    # mutation, agent deletion) are intentionally absent so a leaked bot key
    # cannot delete the agent or read/write OAuth credentials. Fail closed:
    # anything not listed here is denied even on the bot's own agent path.
    _BOT_RUNTIME_PERMISSIONS = frozenset({
        "ai_agent_processor.execute",
        "ai_a2a_protocol.execute",
        "ai_a2a_protocol.read",
        "ai_a2a_protocol.task_management",
        "ai_chat_sessions.read",
    })

    def __init__(self, evo_auth_base_url: str):
        self.evo_auth_service = EvoAuthService(evo_auth_base_url)
        logger.info(f"Permission service initialized with EvoAuthService")
    
    async def check_permission(self, auth_token: str, permission_key: str, token_type: str = "bearer") -> bool:
        """Check if user has specific permission via evo-auth-service
        
        Delegates to EvoAuthService.check_permission for unified permission handling.
        
        Args:
            auth_token: Authentication token (bearer or api_access_token)
            permission_key: Permission key (e.g., 'ai_clients.usage')
            token_type: Type of token ('bearer' or 'api_access_token')
            
        Returns:
            True if user has permission, False otherwise
        """
        return await self.evo_auth_service.check_permission(auth_token, permission_key, token_type)
    
    @staticmethod
    def _path_scoped_to_agent(path: str, agent_id: str) -> bool:
        """True when the request path targets the given agent: the agent_id is
        a full path segment (/agents/{id}/..., /chat/{id}, /a2a/{id}/...) or the
        trailing token of a session-id segment ({display_id}_{agent_id}).

        Canonical segment extraction (no substring matching), so an agent id
        embedded mid-token in an unrelated value cannot spoof scope.
        """
        if not agent_id:
            return False
        for segment in path.split("/"):
            if not segment:
                continue
            if segment == agent_id:
                return True
            # Session ids embed the agent id as the suffix after the last "_".
            if "_" in segment and segment.rsplit("_", 1)[-1] == agent_id:
                return True
        return False

    @classmethod
    def is_agent_bot_permission_allowed(
        cls, user_context: Optional[dict], path: str, permission_key: str
    ) -> bool:
        """Shared agent-bot confinement decision, usable outside the HTTP RBAC
        gate (e.g. WebSocket handshakes that never reach validate_permission).

        Regular (non-bot) contexts are unaffected and always return True. An
        agent-bot key is allowed only when the path targets its OWN agent and
        the permission is a runtime action. Fail closed on everything else.
        """
        if not user_context or not user_context.get("is_agent_bot"):
            return True
        bot_agent_id = str(user_context.get("agent_id") or "")
        if not bot_agent_id or not cls._path_scoped_to_agent(path, bot_agent_id):
            return False
        return permission_key in cls._BOT_RUNTIME_PERMISSIONS

    async def validate_permission(self, request: Request, resource: str, action: str) -> None:
        # Build permission key
        permission_key = f"{resource}.{action}"
        
        # Get user context from request state (set by EvoAuthMiddleware)
        user_context = getattr(request.state, 'user_context', None)
        
        if not user_context:
            logger.error("User context not found in request state")
            raise HTTPException(
                status_code=401,
                detail={
                    "error": "Authentication required",
                    "code": "ERR_UNAUTHORIZED",
                    "message": "User context not available. Ensure EvoAuthMiddleware is configured."
                }
            )
        
        # Get token info
        token_info = user_context.get("token_info", {})
        token_type = token_info.get("type", "bearer")

        # Agent Bots bypass RBAC only on routes scoped to their OWN agent
        # (the middleware validated the key against that agent) AND only for
        # runtime permissions. A bot key must not act as a wildcard credential
        # on other agents, nor perform management/credential actions (delete
        # the agent, read/write OAuth credentials) even on its own agent.
        if user_context.get("is_agent_bot"):
            bot_agent_id = str(user_context.get("agent_id") or "")
            path = str(request.url.path)
            scoped_to_own_agent = bool(bot_agent_id) and self._path_scoped_to_agent(path, bot_agent_id)

            if not scoped_to_own_agent:
                logger.warning(
                    f"Permission: Agent Bot for agent {bot_agent_id or '<unknown>'} denied "
                    f"{permission_key} on unscoped path {path}"
                )
                raise HTTPException(
                    status_code=403,
                    detail={
                        "error": "Insufficient permissions",
                        "code": "ERR_FORBIDDEN",
                        "message": "Agent API Key can only access its own agent resources",
                        "permission": permission_key
                    }
                )

            if permission_key not in self._BOT_RUNTIME_PERMISSIONS:
                logger.warning(
                    f"Permission: Agent Bot for agent {bot_agent_id} denied non-runtime "
                    f"permission {permission_key}"
                )
                raise HTTPException(
                    status_code=403,
                    detail={
                        "error": "Insufficient permissions",
                        "code": "ERR_FORBIDDEN",
                        "message": "Agent API Key is limited to runtime actions on its own agent",
                        "permission": permission_key
                    }
                )

            logger.info(f"Permission: Agent Bot access granted for permission {permission_key}")
            return


        auth_token = token_info.get("access_token")
        if not auth_token:
            logger.error("Token not found in user context")
            raise HTTPException(
                status_code=401,
                detail={
                    "error": "Authorization token required",
                    "code": "ERR_UNAUTHORIZED",
                    "message": "Bearer token not available in user context"
                }
            )
        
        # Validate permission via evo-auth-service
        has_permission = await self.check_permission(auth_token, permission_key, token_type)
        
        logger.info(f"Permission: Has permission {permission_key}: {has_permission}")
        
        if not has_permission:
            raise HTTPException(
                status_code=403,
                detail={
                    "error": "Insufficient permissions",
                    "code": "ERR_FORBIDDEN",
                    "message": f"User does not have required permission: {permission_key}",
                    "permission": permission_key
                }
            )
        
        logger.info(f"Permission: Access granted for permission {permission_key}")


# Global singleton instance
_permission_service: Optional[PermissionService] = None

def initialize_permission_service(evo_auth_base_url: str) -> None:
    """Initialize the global permission service"""
    global _permission_service
    _permission_service = PermissionService(evo_auth_base_url)
    logger.info("Global permission service initialized")

def permission_service() -> PermissionService:
    """Get the global permission service instance"""
    global _permission_service
    if _permission_service is None:
        raise RuntimeError("Permission service not initialized. Call initialize_permission_service first.")
    return _permission_service
