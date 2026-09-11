"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: evo_auth.py                                                           │
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

from fastapi import Request
import uuid
from fastapi.responses import JSONResponse
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.types import ASGIApp
from src.services.evo_auth_service import get_auth_service, AuthenticationError, ServiceUnavailableError, NetworkError
from src.services import agent_service
from src.services.agent_service import AgentValidationError
from src.config.database import get_db
from src.utils.http import HttpUtils
from src.utils.logger import setup_logger

logger = setup_logger(__name__)


class EvoAuthMiddleware(BaseHTTPMiddleware):
    """Clean middleware for EvoAuth authentication"""
    
    SKIP_PATHS = [
        "/", "/docs", "/redoc", "/openapi.json",
        "/health", "/ready", "/healthz", "/readyz",
        "/favicon.ico", "/static"
    ]
    
    def __init__(self, app: ASGIApp):
        super().__init__(app)
        logger.info("EvoAuth middleware initialized")
    
    async def dispatch(self, request: Request, call_next):
        # Skip OPTIONS requests (CORS preflight)
        if request.method == "OPTIONS":
            return await call_next(request)
        
        # Skip public endpoints
        if self._should_skip(request.url.path):
            return await call_next(request)
        
        # For /sync/ routes, check X-API-Key header first (for agent bot authentication)
        if '/sync/' in request.url.path:
            x_api_key = request.headers.get("x-api-key")
            if x_api_key:
                # Extract agent_id from session_id in path
                agent_id = self._extract_agent_id_from_sync_path(request.url.path)
                if agent_id:
                    logger.info(f"EvoAuth: /sync/ route detected, validating Agent API Key for agent {agent_id}")
                    db = next(get_db())
                    try:
                        validation_result = await agent_service.validate_agent_api_key(
                            db, agent_id, x_api_key
                        )

                        if validation_result and validation_result.get("valid"):
                            # Create agent context
                            agent_context = {
                                "agent_id": validation_result.get("agent_id"),
                                "agent_name": validation_result.get("agent_name"),
                                "is_agent_bot": True,
                                "token_info": {
                                    "access_token": x_api_key,
                                    "type": "agent_api_key"
                                }
                            }

                            request.state.user_context = agent_context
                            request.state.current_user = agent_context

                            logger.info(
                                f"EvoAuth: Successfully authenticated Agent Bot {validation_result.get('agent_name')} via X-API-Key for /sync/ route"
                            )

                            return await call_next(request)
                    except AgentValidationError as e:
                        # EVO-2166: infra/DB error is transient -> 503 (retryable),
                        # never a silent 401.
                        logger.error(f"EvoAuth: infra error validating Agent API Key (/sync/ route): {e}")
                        return self._service_unavailable_response("Agent authentication temporarily unavailable")
                    except Exception as e:
                        logger.warning(f"EvoAuth: Agent API Key validation failed for /sync/ route: {e}")
                    finally:
                        db.close()
                else:
                    logger.warning(f"EvoAuth: Could not extract agent_id from /sync/ path: {request.url.path}")
        
        # Extract token
        token, token_type = self._extract_token(request)
        if not token:
            return self._unauthorized_response("No authentication token provided")
        
        # Validate with auth service
        try:
            auth_service = get_auth_service()
            auth_response = await auth_service.validate_token(token, token_type)

            # Check if validation failed
            if not auth_response:
                # If token validation failed, try to validate as Agent API Key directly
                # This works for both "bearer" and "api_access_token" types
                agent_id = self._extract_agent_id_from_path(request.url.path)
                
                if agent_id:
                    logger.info(f"EvoAuth: Token validation failed (type: {token_type}), trying Agent API Key validation for agent {agent_id}")
                    db = next(get_db())
                    try:
                        validation_result = await agent_service.validate_agent_api_key(
                            db, agent_id, token
                        )

                        if validation_result and validation_result.get("valid"):
                            # Create agent context
                            agent_context = {
                                "agent_id": validation_result.get("agent_id"),
                                "agent_name": validation_result.get("agent_name"),
                                "is_agent_bot": True,
                                "token_info": {
                                    "access_token": token,
                                    "type": "agent_api_key"
                                }
                            }

                            request.state.user_context = agent_context
                            request.state.current_user = agent_context

                            logger.info(
                                f"EvoAuth: Successfully authenticated Agent Bot {validation_result.get('agent_name')} via API key"
                            )

                            return await call_next(request)
                    except AgentValidationError as e:
                        # EVO-2166: infra/DB error is transient -> 503 (retryable),
                        # never a silent 401.
                        logger.error(f"EvoAuth: infra error validating Agent API Key: {e}")
                        return self._service_unavailable_response("Agent authentication temporarily unavailable")
                    except Exception as e:
                        logger.warning(f"EvoAuth: Agent API Key validation failed: {e}")
                    finally:
                        db.close()
                
                return self._unauthorized_response("Invalid or expired token")
            
            # Detect if this is an Agent API Key
            is_agent_api_key = token_type == "api_access_token" and self._is_agent_token(auth_response)
            
            # If it's an agent API key, validate agent_id match
            if is_agent_api_key:
                agent_id = self._extract_agent_id_from_path(request.url.path)
                if agent_id and not self._agent_id_matches(auth_response, agent_id):
                    logger.warning(
                        f"Agent API Key attempted to access mismatched agent_id. "
                        f"Token agent: {self._get_token_agent_id(auth_response)}, "
                        f"Requested agent: {agent_id}"
                    )
                    return self._forbidden_response(
                        "Agent API Key can only access its own agent resources"
                    )
                
                # Get database session
                db = next(get_db())
                
                try:
                    # Validate API key using agent_service
                    validation_result = await agent_service.validate_agent_api_key(
                        db, agent_id, token
                    )

                    if not validation_result or not validation_result.get("valid"):
                        logger.warning(
                            f"EvoAuth: Invalid Agent Bot API key for agent {agent_id}"
                        )
                        return JSONResponse(
                            status_code=401,
                            content={
                                "error": "Invalid API key",
                                "code": "ERR_INVALID_API_KEY",
                                "message": "The provided API key is invalid or expired",
                            },
                        )

                    # Create a minimal user context for Agent Bot
                    agent_context = {
                        "agent_id": validation_result.get("agent_id"),
                        "agent_name": validation_result.get("agent_name"),
                        "is_agent_bot": True,
                        "token_info": {
                            "access_token": token,
                            "type": token_type
                        }
                    }

                    request.state.user_context = agent_context
                    request.state.current_user = agent_context

                    logger.debug(
                        f"EvoAuth: Successfully authenticated Agent Bot {validation_result.get('agent_name')}"
                    )

                    return await call_next(request)
                    
                finally:
                    db.close()
            
            # For regular users (bearer or non-agent api_access_token)
            # Build user context
            user_dict = auth_response.user.dict()

            # Build user context
            user_context = {
                'user_id': user_dict.get('id'),
                'email': user_dict.get('email'),
                'name': user_dict.get('name'),
                'display_name': user_dict.get('display_name'),
                'availability': user_dict.get('availability', 'online'),
                'mfa_enabled': user_dict.get('mfa_enabled', False),
                'confirmed': user_dict.get('confirmed', True),
                'is_agent_bot': False,
                'role': user_dict.get('role'),
                'type': user_dict.get('type'),
            }

            if not auth_response.token:
                user_context['token_info'] = {
                    'access_token': token,
                    'type': token_type
                }
            else:
                user_context['token_info'] = auth_response.token.dict()

            # Set context in request state
            request.state.user_context = user_context
            request.state.current_user = user_dict
            request.state.auth_response = auth_response
            request.state.is_agent_api_key = is_agent_api_key
            
            logger.debug(
                f"EvoAuth: Authenticated user: {auth_response.user.email} "
                f"(token_type: {user_context['token_info']['type']})"
            )
            
            return await call_next(request)
            
        except AuthenticationError as e:
            return self._unauthorized_response(str(e))
        except AgentValidationError as e:
            # EVO-2166: covers the main agent-api-key path (try/finally) — infra
            # error while validating the agent key -> 503 (retryable), not 401.
            logger.error(f"EvoAuth: agent validation infra error: {e}")
            return self._service_unavailable_response("Agent authentication temporarily unavailable")
        except NetworkError as e:
            return self._service_unavailable_response(str(e))
        except ServiceUnavailableError as e:
            return self._service_unavailable_response(str(e))
        except Exception as e:
            logger.error(
                f"Unexpected error in EvoAuth middleware: {type(e).__name__}: {e}",
                exc_info=True,
            )
            return self._service_unavailable_response("Authentication service error")
    
    def _should_skip(self, path: str) -> bool:
        """Check if path should skip authentication"""
        if path in self.SKIP_PATHS:
            return True
        
        # Check path prefixes
        skip_prefixes = ["/docs", "/redoc", "/openapi", "/static/"]
        return any(path.startswith(prefix) for prefix in skip_prefixes)
    
    def _extract_token(self, request: Request) -> tuple:
        """Extract token and determine type"""
        bearer = HttpUtils.extract_bearer_token(request)
        if bearer:
            return bearer, "bearer"
        
        api_token = HttpUtils.extract_api_access_token(request)
        if api_token:
            return api_token, "api_access_token"
        
        return None, None
    
    def _is_agent_token(self, auth_response) -> bool:
        """Check if the access token is for an Agent (has agent_id in metadata)"""
        if not hasattr(auth_response, 'metadata') or not auth_response.metadata:
            return False
        
        return 'agent_id' in auth_response.metadata and auth_response.metadata['agent_id'] is not None
    
    def _extract_agent_id_from_path(self, path: str) -> str:
        """Extract agent_id from URL path if present"""
        # Patterns: 
        # - /api/v1/a2a/{agent_id}/...
        # - /api/v1/chat/{agent_id}/...
        # - /api/v1/sessions/{agent_id}/... (but NOT /api/v1/sessions/sync/...)
        # - /api/v1/sessions/{session_id}/events (session_id format: {display_id}_{agent_id})
        # - /agents/{agent_id}/... or /agent/{agent_id}/...
        import re
        # Skip sync endpoints - they don't have agent_id in the path directly
        if '/sync/' in path:
            return None
        
        # Check for /sessions/{session_id}/events pattern
        # session_id format: {display_id}_{agent_id}
        events_match = re.search(r'/api/v1/sessions/([^/]+)/events', path)
        if events_match:
            session_id = events_match.group(1)
            # Extract agent_id from session_id (format: {display_id}_{agent_id})
            parts = session_id.rsplit('_', 1)
            if len(parts) == 2:
                potential_agent_id = parts[1]
                # Validate it's a UUID format
                try:
                    uuid.UUID(potential_agent_id)
                    return potential_agent_id
                except ValueError:
                    pass
        
        # Try A2A, chat, sessions patterns first
        match = re.search(r'/api/v1/(a2a|chat|sessions)/([^/]+)', path)
        if match:
            return match.group(2)
        # Fallback to agents/agent pattern
        match = re.search(r'/agents?/([^/]+)', path)
        return match.group(1) if match else None
    
    def _extract_agent_id_from_sync_path(self, path: str) -> str:
        """Extract agent_id from /sync/{session_id} path where session_id format is {display_id}_{agent_id}"""
        import re
        # Pattern: /api/v1/sessions/sync/{session_id}
        # session_id format: {display_id}_{agent_id}
        match = re.search(r'/sync/([^/]+)', path)
        if match:
            session_id = match.group(1)
            # Extract agent_id from session_id (format: {display_id}_{agent_id})
            # Try to split by last underscore and get the UUID part
            parts = session_id.rsplit('_', 1)
            if len(parts) == 2:
                # The last part should be the agent_id (UUID)
                potential_agent_id = parts[1]
                # Validate it's a UUID format
                try:
                    uuid.UUID(potential_agent_id)
                    return potential_agent_id
                except ValueError:
                    pass
        return None
    
    def _get_token_agent_id(self, auth_response) -> str:
        """Get agent_id from token metadata"""
        if hasattr(auth_response, 'metadata') and auth_response.metadata:
            return auth_response.metadata.get('agent_id')
        return None
    
    def _agent_id_matches(self, auth_response, requested_agent_id: str) -> bool:
        """Verify if the token's agent_id matches the requested agent_id"""
        token_agent_id = self._get_token_agent_id(auth_response)
        return token_agent_id and str(token_agent_id) == str(requested_agent_id)
    
    def _unauthorized_response(self, message: str) -> JSONResponse:
        """Return consistent 401 response"""
        return JSONResponse(
            status_code=401,
            content={
                "error": "Unauthorized",
                "code": "ERR_UNAUTHORIZED",
                "message": message
            }
        )
    
    def _forbidden_response(self, message: str) -> JSONResponse:
        """Return 403 response for permission denied"""
        return JSONResponse(
            status_code=403,
            content={
                "error": "Forbidden",
                "code": "ERR_FORBIDDEN",
                "message": message
            }
        )
    
    def _service_unavailable_response(self, message: str) -> JSONResponse:
        """Return 503 when auth service is down"""
        return JSONResponse(
            status_code=503,
            content={
                "error": "Service Unavailable",
                "code": "ERR_SERVICE_UNAVAILABLE",
                "message": message
            }
        )