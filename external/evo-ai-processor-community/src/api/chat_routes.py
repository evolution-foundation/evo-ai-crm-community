"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: chat_routes.py                                                        │
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

from fastapi import (
    APIRouter,
    Depends,
    HTTPException,
    Request,
    status,
    WebSocket,
    WebSocketDisconnect,
)
from sqlalchemy.orm import Session
from src.config.database import get_db
from src.models.models import Session as SessionModel
from src.api.dependencies import get_current_user, get_user_identity, user_owns_session
from src.services import (
    agent_service,
    folder_share_service
)
from src.schemas.chat import ChatRequest, FileData
from src.services.adk.agent_runner import (
    run_agent as run_agent_adk,
    run_agent_stream,
    run_agent_live,
)
from src.core.exceptions import AgentNotFoundError
from src.services.service_providers import (
    session_service,
    artifacts_service,
    memory_service,
)
from src.services.adk.memory import MemoryLimitExceeded
from src.services.session_service import SessionLimitExceeded
from src.middleware.permissions import RequirePermission
from src.services.permission_service import PermissionService

# Runtime permission an agent-bot key must hold to invoke an agent over a chat
# WebSocket. WebSocket routes bypass the HTTP RequirePermission gate, so this
# confinement is enforced inline against the same allowlist.
WS_RUNTIME_PERMISSION = "ai_agent_processor.execute"

import logging
import json
from typing import Optional
from jose import jwt, JWTError
from src.config.settings import settings
from src.utils.response import success_response, error_response, map_status_to_error_code
from src.schemas.responses import SuccessResponse, ErrorResponse
from src.schemas.response_models import ChatResponseData

logger = logging.getLogger(__name__)

router = APIRouter(
    prefix="/chat",
    tags=["chat"],
)

async def get_jwt_token_ws(token: str, skip_validation: bool = False) -> Optional[dict]:
    """
    Verifies token for WebSocket using EvoAuth service.
    Returns the payload if the token is valid, None otherwise.
    """
    if skip_validation:
        # For WebSocket, we need to validate via EvoAuth service
        try:
            from src.services.evo_auth_service import get_auth_service
            auth_service = get_auth_service()
            # validate_token already returns the built EvoAuthResponse (with
            # .user/.email); there is no `.data` wrapper to unwrap.
            #
            # evo-auth decides the token type from the header it arrives in, so the
            # same value has to be offered under both shapes: a browser token only
            # validates as `bearer`, an API token only as `api_access_token`. The
            # handshake carries no type, hence the probe (EVO-2123).
            auth_response = None
            for token_type in ("bearer", "api_access_token"):
                auth_response = await auth_service.validate_token(token, token_type)
                if auth_response and auth_response.user:
                    break

            if auth_response and auth_response.user:
                # Return user context similar to what middleware does
                user = auth_response.user.dict() if hasattr(auth_response.user, 'dict') else auth_response.user
                # Surface agent-bot identity when the token is bound to an agent
                # (metadata.agent_id), mirroring EvoAuthMiddleware, so WebSocket
                # handlers can enforce the same per-agent confinement.
                metadata = getattr(auth_response, "metadata", None) or {}
                bot_agent_id = metadata.get("agent_id")
                return {
                    "sub": user.get("email") or user.get("id"),
                    "email": user.get("email"),
                    "user_id": user.get("id"),
                    "user": user,
                    "is_agent_bot": bool(bot_agent_id),
                    "agent_id": bot_agent_id,
                }
        except Exception as e:
            logger.warning(f"EvoAuth token validation failed: {str(e)}")
            return None
    
    # Fallback to JWT if needed (for backward compatibility)
    try:
        payload = jwt.decode(
            token, settings.JWT_SECRET_KEY, algorithms=[settings.JWT_ALGORITHM]
        )
        return payload
    except JWTError:
        return None

@router.websocket("/ws/{agent_id}/{user_id}/{session_id}")
async def websocket_chat(
    websocket: WebSocket,
    agent_id: str,
    user_id: str,
    session_id: str,
    db: Session = Depends(get_db),
):
    try:
        # Accept the connection
        await websocket.accept()
        logger.info("WebSocket connection accepted")

        # Wait for authentication message
        auth_data = await websocket.receive_json()
        logger.info("Authentication data received")

        if not (
            auth_data.get("type") == "authorization"
            and (auth_data.get("token") or auth_data.get("api_key"))
        ):
            await websocket.close(code=status.WS_1008_POLICY_VIOLATION)
            return

        # Verify if the agent exists
        agent = await agent_service.get_agent(db, agent_id)
        if not agent:
            await websocket.close(code=status.WS_1008_POLICY_VIOLATION)
            return

        # Verify authentication
        is_authenticated = False
        auth_payload = None

        # Try with token (Bearer token from EvoAuth)
        if auth_data.get("token"):
            try:
                payload = await get_jwt_token_ws(auth_data["token"], True)
                if payload:
                    auth_payload = payload
                    user_id = payload.get("user_id") or payload.get("sub")
                    is_authenticated = True
                    logger.info(f"WebSocket: User {user_id} authenticated for agent {agent_id}")
            except Exception as e:
                logger.warning(f"Token authentication failed: {str(e)}")

        # If JWT fails, try with API key
        if not is_authenticated and auth_data.get("api_key"):
            if agent.config and agent.config.get("api_key") == auth_data.get("api_key"):
                is_authenticated = True

        if not is_authenticated:
            await websocket.close(code=status.WS_1008_POLICY_VIOLATION)
            return

        # Confine agent-bot keys: a bot key may only invoke its OWN agent, and
        # only for the runtime action. Reject at the handshake before any work.
        if not PermissionService.is_agent_bot_permission_allowed(
            auth_payload, websocket.url.path, WS_RUNTIME_PERMISSION
        ):
            logger.warning(
                f"WebSocket: Agent Bot for agent {(auth_payload or {}).get('agent_id')} "
                f"denied access to agent {agent_id}"
            )
            await websocket.close(code=status.WS_1008_POLICY_VIOLATION)
            return

        logger.info(f"WebSocket authenticated for agent {agent_id}")

        # Main message loop
        while True:
            try:
                data = await websocket.receive_json()
                message = data.get("message")

                if not message:
                    continue

                # Process files if any
                files = None
                if data.get("files") and isinstance(data.get("files"), list):
                    try:
                        files = []
                        for file_data in data.get("files"):
                            if (
                                isinstance(file_data, dict)
                                and file_data.get("filename")
                                and file_data.get("content_type")
                                and file_data.get("data")
                            ):
                                files.append(
                                    FileData(
                                        filename=file_data.get("filename"),
                                        content_type=file_data.get("content_type"),
                                        data=file_data.get("data"),
                                    )
                                )
                        logger.info(f"Processed {len(files)} files")
                    except Exception as e:
                        logger.error(f"Error processing files: {str(e)}")
                        files = None

                # Stream agent response
                try:
                    async for chunk in run_agent_stream(
                        agent_id=agent_id,
                        external_id=user_id,
                        message=message,
                        session_service=session_service,
                        artifacts_service=artifacts_service,
                        memory_service=memory_service,
                        db=db,
                        session_id=session_id,
                        files=files,
                    ):
                        if not chunk or chunk.strip() == "":
                            logger.debug("Skipping empty chunk")
                            continue

                        await websocket.send_json(
                            {
                                "message": json.loads(chunk),
                                "turn_complete": False,
                            }
                        )

                    # Send completion signal
                    await websocket.send_json(
                        {
                            "message": "",
                            "turn_complete": True,
                        }
                    )

                except Exception as stream_error:
                    logger.error(f"Error in agent stream: {stream_error}")

                    # Handle specific limit exceptions
                    if isinstance(stream_error, SessionLimitExceeded):
                        await websocket.send_json(
                            {
                                "message": {
                                    "error": f"Session limit exceeded: {str(stream_error)}"
                                },
                                "turn_complete": True,
                                "error_type": "session_limit",
                            }
                        )
                    elif isinstance(stream_error, MemoryLimitExceeded):
                        await websocket.send_json(
                            {
                                "message": {
                                    "error": f"Memory limit exceeded: {str(stream_error)}"
                                },
                                "turn_complete": True,
                                "error_type": "memory_limit",
                            }
                        )
                    else:
                        await websocket.send_json(
                            {
                                "message": {
                                    "error": f"Stream error: {str(stream_error)}"
                                },
                                "turn_complete": True,
                            }
                        )

            except WebSocketDisconnect:
                logger.info("Client disconnected")
                break
            except json.JSONDecodeError:
                logger.warning("Invalid JSON message received")
                continue
            except Exception as e:
                logger.error(f"Error in message handling: {str(e)}")
                break

    except WebSocketDisconnect:
        logger.info("Client disconnected during setup")
    except Exception as e:
        logger.error(f"WebSocket error: {str(e)}")
        try:
            await websocket.close(code=status.WS_1011_INTERNAL_ERROR)
        except:
            pass


@router.websocket("/ws-live/{agent_id}/{user_id}/{session_id}")
async def websocket_live_chat(
    websocket: WebSocket,
    agent_id: str,
    user_id: str,
    session_id: str,
    db: Session = Depends(get_db),
):
    """WebSocket endpoint for live agent interactions with real-time bidirectional communication."""
    logger.info(f"=== LIVE WEBSOCKET START ===")
    logger.info(f"Incoming connection attempt for:")
    logger.info(f"  - Agent ID: {agent_id}")
    logger.info(f"  - User ID: {user_id}")
    logger.info(f"  - Session ID: {session_id}")
    logger.info(f"  - WebSocket state: {websocket.client_state}")
    logger.info(
        f"  - WebSocket headers: {dict(websocket.headers) if hasattr(websocket, 'headers') else 'No headers'}"
    )

    try:
        # Accept the connection
        logger.info("Attempting to accept WebSocket connection...")
        await websocket.accept()
        logger.info("✅ Live WebSocket connection ACCEPTED successfully")

        # Wait for authentication message
        logger.info("Waiting for authentication message...")
        try:
            auth_data = await websocket.receive_json()
            logger.info(f"✅ Authentication data received successfully")
            logger.info(
                f"Auth data keys: {list(auth_data.keys()) if isinstance(auth_data, dict) else 'Not a dict'}"
            )
            logger.info(f"Auth data type: {auth_data.get('type')}")
            logger.info(f"Has token: {'token' in auth_data}")
            logger.info(f"Has api_key: {'api_key' in auth_data}")
            logger.info(f"Complete auth data: {auth_data}")
        except WebSocketDisconnect as wd:
            logger.warning(f"🔌 Client disconnected while waiting for auth data: {wd}")
            return  # Don't try to close, already disconnected
        except json.JSONDecodeError as e:
            logger.error(f"❌ JSON decode error in auth data: {e}")
            try:
                await websocket.close(code=status.WS_1008_POLICY_VIOLATION)
            except:
                pass  # Already disconnected
            return
        except Exception as e:
            logger.error(f"❌ Error receiving auth data: {e}")
            logger.error(f"Error type: {type(e)}")
            try:
                await websocket.close(code=status.WS_1008_POLICY_VIOLATION)
            except:
                pass  # Already disconnected
            return

        # Validate auth data structure
        logger.info("Validating authentication data structure...")
        auth_type_valid = auth_data.get("type") == "authorization"
        has_token = bool(auth_data.get("token"))
        has_api_key = bool(auth_data.get("api_key"))
        auth_credentials_valid = has_token or has_api_key

        logger.info(
            f"Auth type valid: {auth_type_valid} (expected 'authorization', got '{auth_data.get('type')}')"
        )
        logger.info(f"Has token: {has_token}")
        logger.info(f"Has API key: {has_api_key}")
        logger.info(f"Auth credentials valid: {auth_credentials_valid}")

        if not (auth_type_valid and auth_credentials_valid):
            logger.error(f"❌ Invalid auth data structure")
            logger.error(f"Required: type='authorization' and (token or api_key)")
            logger.error(
                f"Received: type='{auth_data.get('type')}', token={has_token}, api_key={has_api_key}"
            )
            try:
                await websocket.close(code=status.WS_1008_POLICY_VIOLATION)
            except:
                pass  # Already disconnected
            return

        logger.info("✅ Auth data structure is valid")

        # Verify if the agent exists
        logger.info(f"Checking if agent {agent_id} exists in database...")
        try:
            agent = await agent_service.get_agent(db, agent_id)
            if not agent:
                logger.error(f"❌ Agent {agent_id} not found in database")
                try:
                    await websocket.close(code=status.WS_1008_POLICY_VIOLATION)
                except:
                    pass  # Already disconnected
                return

            logger.info(f"✅ Agent found: {agent.name}")
            logger.info(f"Agent details:")
            logger.info(f"  - ID: {agent.id}")
            logger.info(f"  - Name: {agent.name}")
            logger.info(f"  - Folder ID: {agent.folder_id}")
            logger.info(f"  - Has config: {bool(agent.config)}")
            if agent.config:
                logger.info(f"  - Config keys: {list(agent.config.keys())}")
                logger.info(f"  - Has API key in config: {'api_key' in agent.config}")
        except Exception as e:
            logger.error(f"❌ Error querying agent: {e}")
            try:
                await websocket.close(code=status.WS_1008_POLICY_VIOLATION)
            except:
                pass  # Already disconnected
            return

        # Start authentication process
        logger.info("=== STARTING AUTHENTICATION PROCESS ===")
        is_authenticated = False
        auth_payload = None

        # Try with JWT token first
        if auth_data.get("token"):
            logger.info("🔐 Attempting JWT authentication...")
            try:
                logger.info(f"JWT token length: {len(auth_data['token'])}")
                logger.info(f"JWT token starts with: {auth_data['token'][:20]}...")

                payload = await get_jwt_token_ws(auth_data["token"], True)
                logger.info(f"JWT payload received: {bool(payload)}")

                if payload:
                    auth_payload = payload
                    logger.info(f"JWT payload keys: {list(payload.keys())}")
                    logger.info(f"JWT payload user: {payload.get('sub', 'N/A')}")
                    logger.info(f"JWT payload email: {payload.get('email', 'N/A')}")

                    try:
                        logger.info("Verifying user client access...")
                        is_authenticated = True
                        logger.info(
                            "✅ JWT authentication successful via client verification"
                        )
                    except HTTPException as http_ex:
                        logger.warning(
                            f"⚠️ JWT client verification failed: {http_ex.detail}"
                        )
                        logger.info("Checking folder access as fallback...")

                        if agent.folder_id:
                            logger.info(f"Agent has folder_id: {agent.folder_id}")
                            user_email = payload.get("sub") or payload.get("email")
                            logger.info(f"User email from JWT: {user_email}")

                            if user_email:
                                logger.info("Checking folder access...")
                                has_access = folder_share_service.check_folder_access(
                                    db, agent.folder_id, user_email, "read"
                                )
                                logger.info(f"Folder access result: {has_access}")

                                if has_access:
                                    logger.info(
                                        f"✅ Live WebSocket: User {user_email} accessing agent {agent_id} via shared folder {agent.folder_id}"
                                    )
                                    is_authenticated = True
                                else:
                                    logger.warning(
                                        f"❌ User {user_email} denied folder access to {agent.folder_id}"
                                    )
                            else:
                                logger.warning(
                                    "❌ No user email found in JWT payload for folder access"
                                )
                        else:
                            logger.warning(
                                f"❌ Agent {agent_id} not in a folder, cannot use folder sharing"
                            )
                else:
                    logger.warning("❌ JWT token validation returned empty payload")

            except Exception as e:
                logger.error(f"❌ JWT authentication failed with exception: {str(e)}")
                logger.error(f"Exception type: {type(e)}")
                import traceback

                logger.error(f"Traceback: {traceback.format_exc()}")

        # If JWT fails, try with API key (same logic as regular WebSocket)
        if not is_authenticated and auth_data.get("api_key"):
            logger.info("🔑 Attempting API key authentication...")
            logger.info(f"Provided API key length: {len(auth_data.get('api_key', ''))}")
            logger.info(
                f"Provided API key starts with: {auth_data.get('api_key', '')[:10]}..."
            )

            # Use the same logic as regular WebSocket: verify if API key matches agent config
            if agent.config and agent.config.get("api_key") == auth_data.get("api_key"):
                is_authenticated = True
                logger.info("✅ API key authentication successful")
            else:
                logger.warning("❌ API key authentication failed")
                if agent.config:
                    stored_api_key = agent.config.get("api_key")
                    if stored_api_key:
                        logger.warning(
                            f"Expected API key starts with: {stored_api_key[:10]}..."
                        )
                        logger.warning(
                            f"Provided API key starts with: {auth_data.get('api_key', '')[:10]}..."
                        )
                        logger.warning(
                            "API key mismatch - ensure you're using the correct API key from agent configuration"
                        )
                    else:
                        logger.warning("No API key configured in agent config")
                else:
                    logger.warning("Agent has no config, cannot verify API key")

        # Final authentication check
        logger.info(
            f"=== AUTHENTICATION RESULT: {'SUCCESS' if is_authenticated else 'FAILED'} ==="
        )

        if not is_authenticated:
            logger.error("❌ Authentication failed for live WebSocket")
            logger.error("Neither JWT nor API key authentication succeeded")
            try:
                await websocket.close(code=status.WS_1008_POLICY_VIOLATION)
            except:
                pass  # Already disconnected
            return

        # Confine agent-bot keys: a bot key may only invoke its OWN agent, and
        # only for the runtime action. Reject at the handshake before any work.
        if not PermissionService.is_agent_bot_permission_allowed(
            auth_payload, websocket.url.path, WS_RUNTIME_PERMISSION
        ):
            logger.warning(
                f"❌ Live WebSocket: Agent Bot for agent "
                f"{(auth_payload or {}).get('agent_id')} denied access to agent {agent_id}"
            )
            try:
                await websocket.close(code=status.WS_1008_POLICY_VIOLATION)
            except:
                pass  # Already disconnected
            return

        logger.info(
            f"✅ Live WebSocket authenticated successfully for agent {agent_id}"
        )

        # Send authentication success message
        logger.info("Sending authentication success message...")
        try:
            await websocket.send_json(
                {
                    "type": "auth_success",
                    "message": "Authentication successful, live session ready",
                }
            )
            logger.info("✅ Auth success message sent")
        except WebSocketDisconnect:
            logger.warning("🔌 Client disconnected while sending auth success")
            return
        except Exception as e:
            logger.error(f"❌ Error sending auth success message: {e}")
            return

        # Extract configuration options from auth_data
        logger.info("Extracting configuration options...")
        is_audio = auth_data.get("is_audio", False)
        voice_config = auth_data.get("voice_config", {"voice_name": "Zephyr"})
        language_code = auth_data.get("language_code", "en-US")

        logger.info(f"Configuration:")
        logger.info(f"  - Audio enabled: {is_audio}")
        logger.info(f"  - Voice config: {voice_config}")
        logger.info(f"  - Language code: {language_code}")

        # Start live agent session
        logger.info("Starting live agent session...")
        try:
            await run_agent_live(
                websocket=websocket,
                agent_id=agent_id,
                external_id=user_id,
                session_service=session_service,
                artifacts_service=artifacts_service,
                memory_service=memory_service,
                db=db,
                session_id=session_id,
                is_audio=is_audio,
                voice_config=voice_config,
                language_code=language_code,
            )
            logger.info("✅ Live agent session completed normally")
        except Exception as e:
            logger.error(f"❌ Error in live agent session: {e}")
            import traceback

            logger.error(f"Traceback: {traceback.format_exc()}")

            # Handle specific limit exceptions
            if isinstance(e, SessionLimitExceeded):
                logger.warning(
                    f"Session limit exceeded in live session for user {user_id}: {str(e)}"
                )
                # Don't raise, just log - WebSocket will be closed gracefully below
            elif isinstance(e, MemoryLimitExceeded):
                logger.warning(
                    f"Memory limit exceeded in live session for user {user_id}: {str(e)}"
                )
                # Don't raise, just log - WebSocket will be closed gracefully below
            else:
                raise

    except WebSocketDisconnect:
        logger.info("🔌 Live client disconnected during setup")
    except SessionLimitExceeded as e:
        logger.warning(f"Session limit exceeded for user {user_id}: {str(e)}")
        logger.error(f"💥 Live WebSocket session limit error: {str(e)}")
        try:
            if websocket.client_state.name in ["CONNECTED", "CONNECTING"]:
                await websocket.close(code=status.WS_1008_POLICY_VIOLATION)
        except Exception as close_error:
            logger.debug(f"Expected error closing WebSocket: {close_error}")
    except MemoryLimitExceeded as e:
        logger.warning(f"Memory limit exceeded for user {user_id}: {str(e)}")
        logger.error(f"💥 Live WebSocket memory limit error: {str(e)}")
        try:
            if websocket.client_state.name in ["CONNECTED", "CONNECTING"]:
                await websocket.close(code=status.WS_1008_POLICY_VIOLATION)
        except Exception as close_error:
            logger.debug(f"Expected error closing WebSocket: {close_error}")
    except Exception as e:
        logger.error(f"💥 Live WebSocket critical error: {str(e)}")
        logger.error(f"Error type: {type(e)}")
        import traceback

        logger.error(f"Full traceback: {traceback.format_exc()}")
        try:
            # Only try to close if WebSocket is still connected
            if websocket.client_state.name in ["CONNECTED", "CONNECTING"]:
                await websocket.close(code=status.WS_1011_INTERNAL_ERROR)
        except Exception as close_error:
            logger.debug(f"Expected error closing WebSocket: {close_error}")

    logger.info("=== LIVE WEBSOCKET END ===")


@router.post(
    "/{agent_id}/{session_id}",
    response_model=SuccessResponse[ChatResponseData],
    responses={
        200: {"description": "Chat response generated successfully"},
        404: {"model": ErrorResponse, "description": "Agent not found"},
        402: {"model": ErrorResponse, "description": "Resource limit exceeded"},
        500: {"model": ErrorResponse, "description": "Internal server error"}
    }
)
async def chat(
    payload: ChatRequest,
    agent_id: str,
    session_id: str,
    request: Request,
    current_user: dict = Depends(get_current_user),
    db: Session = Depends(get_db),
    _: None = Depends(RequirePermission("ai_agent_processor", "execute")),
):
    logged_user_id = get_user_identity(current_user)

    # EVO-2103: the ADK indexes sessions by (agent_id, user_id, session_id), so
    # the lookup key must be the session owner (SessionModel.user_id), not the
    # logged user - they diverge for sessions the user does not own, and the ADK
    # then misses -> 500. But running someone else's session is exactly what must
    # NOT happen: the agent would answer with the owner's history as context and
    # its events would be appended to a real customer conversation. So resolve the
    # owner, and deny when it is not the caller.
    db_session = (
        db.query(SessionModel)
        .filter(
            SessionModel.id == session_id,
            SessionModel.app_name == str(agent_id),
        )
        .first()
    )
    session_owner_id = db_session.user_id if db_session and db_session.user_id else None

    if session_owner_id and not user_owns_session(current_user, session_owner_id):
        logger.warning(
            f"Forbidden chat on session {session_id}: owner={session_owner_id!r} "
            f"logged={logged_user_id!r}"
        )
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_403_FORBIDDEN),
            message="You do not own this session",
            status_code=status.HTTP_403_FORBIDDEN
        )

    # No session row yet (first message bootstraps it): fall back to the caller.
    user_id = session_owner_id or logged_user_id
    if not user_id:
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_403_FORBIDDEN),
            message="Unable to resolve the session owner for this request",
            status_code=status.HTTP_403_FORBIDDEN
        )

    try:
        final_response = await run_agent_adk(
            agent_id,
            user_id,
            payload.message,
            session_service,
            artifacts_service,
            memory_service,
            db,
            session_id=session_id,
            files=payload.files,
            user_id=user_id,
        )

        return success_response(
            data={
                "response": final_response["final_response"],
                "message_history": final_response["message_history"],
            },
            message="Chat response generated successfully"
        )

    except AgentNotFoundError as e:
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_404_NOT_FOUND),
            message=str(e),
            status_code=status.HTTP_404_NOT_FOUND
        )
    except MemoryLimitExceeded as e:
        logger.warning(f"Memory limit exceeded for user {user_id}: {str(e)}")
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_402_PAYMENT_REQUIRED),
            message=str(e),
            status_code=status.HTTP_402_PAYMENT_REQUIRED
        )
    except SessionLimitExceeded as e:
        logger.warning(f"Session limit exceeded for user {user_id}: {str(e)}")
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_402_PAYMENT_REQUIRED),
            message=str(e),
            status_code=status.HTTP_402_PAYMENT_REQUIRED
        )
    except Exception as e:
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_500_INTERNAL_SERVER_ERROR),
            message=str(e),
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR
        )
