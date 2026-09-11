"""
# Dependencies shared across API routes.
"""

import logging
from fastapi import HTTPException, Request, Depends, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from typing import Any, Tuple, Dict, Optional
from sqlalchemy.orm import Session
from src.services import folder_share_service

logger = logging.getLogger(__name__)

# Security scheme for Swagger documentation (optional to support both bearer and api_access_token)
security = HTTPBearer(auto_error=False)

# Checks user access to an agent
async def get_current_user(
    request: Request,
    _: Optional[HTTPAuthorizationCredentials] = Depends(security)
) -> Dict[str, Any]:
    """Get current authenticated user from request state (set by EvoAuthMiddleware)"""
    # Get user context from request state that was set by EvoAuthMiddleware
    if hasattr(request, 'state') and hasattr(request.state, 'user_context'):
        return request.state.user_context

    # Fallback: user_context should always be set by middleware
    logger.error("User context not found in request state - middleware not configured properly")
    raise HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Authentication required"
    )


def is_agent_bot(user_context: Optional[Dict[str, Any]]) -> bool:
    """True when the caller authenticated with an agent API key, not as a human."""
    return bool(user_context and user_context.get("is_agent_bot"))


def get_user_identity(user_context: Optional[Dict[str, Any]]) -> str:
    """Resolve the id a human user's sessions are stored under.

    Sessions carry the owner in SessionModel.user_id, and every session-scoped
    route must resolve the caller the same way, otherwise the same person is a
    different owner depending on the endpoint. Returns "" when no identity can
    be resolved (agent bots, malformed contexts) - callers MUST treat "" as
    "deny", never as "no filter".
    """
    if not user_context:
        return ""
    return str(
        user_context.get("user_id")
        or user_context.get("sub")
        or user_context.get("email")
        or ""
    )


def user_owns_session(user_context: Optional[Dict[str, Any]], session_owner_id: Any) -> bool:
    """Object-level ownership check for session-scoped routes.

    Agent bots are exempt: their sessions are stored under the contact id of the
    conversation (never under the bot), and the key is already constrained to a
    single agent by verify_agent_access. The CRM relies on this to sync/delete
    the sessions of real conversations.
    """
    if is_agent_bot(user_context):
        return True

    identity = get_user_identity(user_context)
    if not identity or not session_owner_id:
        return False

    return str(session_owner_id) == identity

async def verify_agent_access(
    db: Session,
    agent: Any,  # Agent object
    required_permission: str = "read",
    user_context: Optional[Dict[str, Any]] = None,
) -> Tuple[bool, bool]:
    """
    Object-level access check for an agent.

    The Community box is single-tenant: agents carry no owner/account column,
    so every authenticated user shares one agent pool and the coarse RBAC
    lives in the route-level RequirePermission gates. What this enforces:

    - Agent-bot credentials (is_agent_bot) act only on their OWN agent: a
      bot key for agent A is denied on agent B.
    - A missing user_context fails closed, so call sites cannot skip the
      check accidentally.
    - Regular users keep pool access; the return flags it as shared access
      when it flows through an active folder share for the user's email.

    Args:
        db: Database session
        agent: Agent object to be checked
        required_permission: Required permission ("read" or "write")
        user_context: Authenticated context set by EvoAuthMiddleware

    Returns:
        tuple: (has_access: bool, is_shared_access: bool)
        - has_access: True if access is granted
        - is_shared_access: True if access was granted via folder sharing

    Raises:
        HTTPException: If access is denied
    """
    if not user_context:
        logger.error("verify_agent_access called without user_context - denying access")
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Access denied",
        )

    if user_context.get("is_agent_bot"):
        bot_agent_id = str(user_context.get("agent_id") or "")
        if bot_agent_id and bot_agent_id == str(agent.id):
            return True, False

        logger.warning(
            f"Agent Bot for agent {bot_agent_id or '<unknown>'} denied access to agent {agent.id}"
        )
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Agent API Key can only access its own agent resources",
        )

    user_email = user_context.get("email")
    if agent.folder_id and user_email:
        try:
            if folder_share_service.check_folder_access(db, agent.folder_id, user_email, required_permission):
                logger.info(
                    f"User {user_email} granted {required_permission} access to agent {agent.id} "
                    f"via shared folder {agent.folder_id}"
                )
                return True, True
        except HTTPException:
            # An explicit denial from the share service must fail closed: it
            # must not be swallowed and downgraded into a silent grant.
            raise
        except Exception as e:
            # Transient infra errors do not revoke the single-tenant pool
            # access every authenticated user already has; only the shared
            # upgrade is withheld.
            logger.warning(f"Folder share lookup failed for agent {agent.id}: {e}")

    return True, False

def get_request_optional(request: Request) -> Request:
    """Dependency to provide the Request object, making it optional in endpoint signatures."""
    return request

def get_db_service():
    """Get database service for async operations."""
    from src.services.database_service import get_database_service
    return get_database_service()

