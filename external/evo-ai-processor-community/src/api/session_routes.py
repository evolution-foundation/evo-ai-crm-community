"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: session_routes.py                                                     │
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

from fastapi import APIRouter, Depends, HTTPException, status, Header
from starlette.requests import Request
from sqlalchemy.orm import Session
from sqlalchemy.exc import IntegrityError
from src.config.database import get_db
from typing import Optional
import uuid
import base64
import time
from datetime import datetime
from src.services import (
    agent_service,
)
from google.adk.sessions import Session as Adk_Session
from google.adk.events import Event
from google.genai.types import Content, Part
from src.services.session_service import (
    get_session_events,
    get_session_by_id,
    delete_session,
    delete_bulk_sessions,
    get_sessions_by_agent,
    get_sessions_by_account,
    get_session_metadata,
    create_session_metadata,
    update_session_metadata,
    delete_session_metadata,
    get_execution_metrics,
)
from src.services.service_providers import session_service, artifacts_service
from src.models.models import Session as SessionModel
from src.schemas.schemas import (
    BulkDeleteSessionsRequest,
    BulkDeleteSessionsResponse,
    SessionMetadataCreate,
    SessionMetadataUpdate,
    SessionEventCreate,
    SessionEventResponse,
    SessionCreateRequest,
)
import logging
from src.api.dependencies import (
    verify_agent_access,
    get_current_user,
    get_request_optional,
    get_user_identity,
    is_agent_bot,
    user_owns_session,
)
from src.api.a2a_routes import verify_api_key
from src.middleware.permissions import RequirePermission
from src.services.agent_service import get_agent
from src.utils.response import success_response, error_response, map_status_to_error_code
from src.schemas.responses import SuccessResponse, ErrorResponse, PaginatedResponse
from src.schemas.response_models import SessionMetricsResponse
from src.schemas.schemas import (
    SessionWithMetadata, SessionMetadata, BulkDeleteSessionsResponse, SessionEventResponse
)

logger = logging.getLogger(__name__)

router = APIRouter(
    prefix="/sessions",
    tags=["sessions"],
)

@router.get(
    "/metrics",
    response_model=SuccessResponse[SessionMetricsResponse],
    responses={
        200: {"description": "Metrics retrieved successfully"},
        500: {"model": ErrorResponse, "description": "Internal server error"}
    }
)
async def get_metrics(
    session_id: Optional[str] = None,
    agent_id: Optional[uuid.UUID] = None,
    skip: int = 0,
    limit: int = 100,
    current_user: dict = Depends(get_current_user),
    _: None = Depends(RequirePermission("ai_chat_sessions", "metrics")),
    db: Session = Depends(get_db),
):
    """
    Get execution metrics with optional filters.
    - Returns execution metrics with optional filters.
    """

    agent_id = str(agent_id) if agent_id else None

    result = get_execution_metrics(
        db,
        user_id=None,
        session_id=session_id,
        agent_id=agent_id,
        skip=skip,
        limit=limit,
    )

    return success_response(
        data=result.model_dump() if hasattr(result, 'model_dump') else result,
        message="Metrics retrieved successfully"
    )


# Session Routes
@router.post(
    "/{agent_id}",
    response_model=SuccessResponse[SessionWithMetadata],
    responses={
        201: {"description": "Session created successfully"},
        400: {"model": ErrorResponse, "description": "Bad request"},
        500: {"model": ErrorResponse, "description": "Internal server error"}
    }
)
async def create_new_session(
    agent_id: uuid.UUID,
    request_data: Optional[SessionCreateRequest] = None,
    metadata: Optional[SessionMetadataCreate] = None,  # Keep for backward compatibility
    current_user: Optional[dict] = Depends(get_current_user),
    request: Optional[Request] = Depends(get_request_optional),
    x_api_key: Optional[str] = Header(None, alias="x-api-key"),
    _: Optional[None] = Depends(RequirePermission("ai_agents", "write")),
    db: Session = Depends(get_db)
):
    """
    Create a new session for a specific agent and user.
    Returns a unique session_id that can be used for subsequent chat interactions.
    Optionally accepts metadata (name, description, tags) for the session.
    
    Supports both authenticated users (via bearer token) and agent bots (via API key).
    For agent bots, session_id and user_id can be provided in the request body.
    """
    
    # Handle authentication - check if it's an agent bot request
    # Try to get user_context from request state if available
    user_context = {}
    try:
        if request and hasattr(request, 'state'):
            user_context = getattr(request.state, "user_context", {})
    except (AttributeError, TypeError):
        # Request might not be available or state might not exist
        pass
    is_agent_bot = user_context.get("is_agent_bot", False)
    
    if not is_agent_bot and not current_user:
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_401_UNAUTHORIZED),
            message="Authentication required",
            status_code=status.HTTP_401_UNAUTHORIZED
        )
    
    agent_id = str(agent_id)

    # Verify if the agent exists
    agent = await agent_service.get_agent(db, agent_id)
    if not agent:
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_404_NOT_FOUND),
            message="Agent not found",
            status_code=status.HTTP_404_NOT_FOUND
        )

    # Verify access (agent bots are constrained to their own agent inside)
    has_access, is_shared_access = await verify_agent_access(db, agent, "read", current_user)

    # Get user identifier
    default_user_id = str(current_user.get("user_id") or current_user.get("email") or "") if current_user else ""

    # Get session_id and user_id from request_data or use defaults
    if request_data:
        session_id = request_data.session_id or str(uuid.uuid4())
        user_id = request_data.user_id or default_user_id
        metadata = request_data.metadata or metadata
    else:
        # Backward compatibility: generate UUID session_id
        session_id = str(uuid.uuid4())
        user_id = default_user_id

    # Create the session directly in the database first to ensure persistence
    try:
        logger.info(
            f"Creating session {session_id} for agent {agent_id} and user {user_id}"
        )
        
        # Check if session already exists (don't raise exception if not found)
        try:
            existing_session = await get_session_by_id(session_service, session_id, db=db)
            if existing_session:
                logger.info(f"Session {session_id} already exists, skipping creation")
                return success_response(
                    data={
                        "session_id": session_id,
                        "agent_id": agent_id,
                        "user_id": user_id,
                        "created_at": datetime.now().isoformat(),
                        "status": "exists",
                    },
                    message="Session already exists",
                    status_code=200
                )
        except HTTPException as e:
            # Session doesn't exist, which is fine - we'll create it
            if e.status_code == 404:
                logger.debug(f"Session {session_id} does not exist, will create new one")
            else:
                # Re-raise other HTTP exceptions
                raise
        
        # Create session record directly in database using SQLAlchemy
        db_session = SessionModel(
            id=session_id,
            app_name=agent_id,
            user_id=user_id,
            state={},
            create_time=datetime.now(),
            update_time=datetime.now(),
        )
        db.add(db_session)
        db.commit()
        db.refresh(db_session)
        
        logger.info(
            f"✅ Session {session_id} successfully created in database: "
            f"app_name={db_session.app_name}, user_id={db_session.user_id}"
        )
        
        # Now create the session in the DatabaseSessionService (for ADK compatibility)
        try:
            await session_service.create_session(
                app_name=agent_id,
                user_id=user_id,
                session_id=session_id,
            )
            logger.info(f"✅ Session {session_id} also created in DatabaseSessionService")
        except Exception as adk_error:
            logger.warning(
                f"⚠️ Session {session_id} created in database but failed in DatabaseSessionService: {str(adk_error)}. "
                f"This may be acceptable if ADK can work with existing session."
            )
        
    except Exception as create_error:
        db.rollback()
        logger.error(
            f"❌ Error creating session {session_id}: {str(create_error)}"
        )
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_500_INTERNAL_SERVER_ERROR),
            message=f"Error creating session: {str(create_error)}",
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR
        )

    # Create metadata if provided
    session_metadata = None
    if metadata:
        session_metadata = create_session_metadata(
            db, session_id, user_id, metadata
        )

    logger.info(
        f"Created new session {session_id} for agent {agent_id} and user {user_id}"
    )

    response_data = {
        "session_id": session_id,
        "agent_id": agent_id,
        "user_id": user_id,
        "created_at": datetime.now().isoformat(),
        "status": "created",
    }

    if session_metadata:
        response_data["metadata"] = {
            "name": session_metadata.name,
            "description": session_metadata.description,
            "tags": session_metadata.tags,
        }

    return success_response(
        data=response_data,
        message="Session created successfully",
        status_code=status.HTTP_201_CREATED
    )

# Get Sessions Routes
@router.get(
    "/account",
    response_model=PaginatedResponse[SessionWithMetadata],
    responses={
        200: {"description": "Sessions retrieved successfully"},
        500: {"model": ErrorResponse, "description": "Internal server error"}
    }
)
async def get_account_sessions(
    request: Request,
    current_user: dict = Depends(get_current_user),
    _: None = Depends(RequirePermission("ai_chat_sessions", "read")),
    db: Session = Depends(get_db)
):
    user_id = get_user_identity(current_user)
    email = current_user.get("email", "")

    # EVO-2103: same scoping rule as /sessions/agent/{id} - this endpoint used to
    # return every session of every accessible agent, which leaked the real
    # conversations (and their ids) of other owners to any authenticated user.
    if not user_id:
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_403_FORBIDDEN),
            message="Unable to resolve the identity of the caller",
            status_code=status.HTTP_403_FORBIDDEN
        )

    # Get sessions from database
    sessions = await get_sessions_by_account(db, user_id, email)

    # Add metadata to each session
    sessions_with_metadata = []
    for session in sessions:
        session_data = session.copy()
        metadata = get_session_metadata(db, session["id"])
        session_data["metadata"] = metadata
        sessions_with_metadata.append(session_data)

    return success_response(
        data=sessions_with_metadata,
        message="Sessions retrieved successfully"
    )


@router.get(
    "/agent/{agent_id}",
    response_model=PaginatedResponse[SessionWithMetadata],
    responses={
        200: {"description": "Sessions retrieved successfully"},
        404: {"model": ErrorResponse, "description": "Agent not found"},
        500: {"model": ErrorResponse, "description": "Internal server error"}
    }
)
async def get_agent_sessions(
    request: Request,
    agent_id: uuid.UUID,
    current_user: dict = Depends(get_current_user),
    _: None = Depends(RequirePermission("ai_agents", "read")),
    db: Session = Depends(get_db),
    skip: int = 0,
    limit: int = 100
):
    agent_id = str(agent_id)

    # Verify if the agent belongs to the user's client
    agent = await agent_service.get_agent(db, agent_id)
    if not agent:
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_404_NOT_FOUND),
            message="Agent not found",
            status_code=status.HTTP_404_NOT_FOUND
        )

    # Verify if the user has access to the agent (including shared folder access)
    has_access, is_shared_access = await verify_agent_access(db, agent, "read", current_user)

    # EVO-2103: filter sessions by the logged-in user. The test panel must not
    # leak WhatsApp/production conversations (which live under different owners
    # like contact_id) into another user's test-session list. An unresolvable
    # identity denies - it must never degrade into "no filter".
    current_user_id = get_user_identity(current_user)
    if not current_user_id and not is_agent_bot(current_user):
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_403_FORBIDDEN),
            message="Unable to resolve the identity of the caller",
            status_code=status.HTTP_403_FORBIDDEN
        )

    # Agent bots hold a service credential already constrained to their own agent
    # and own no sessions themselves, so they are not owner-scoped.
    scope_user_id = None if is_agent_bot(current_user) else current_user_id

    logger.info(
        f"Searching sessions for agent {agent_id} scoped to user {scope_user_id}"
    )

    sessions = await get_sessions_by_agent(db, agent_id, skip, limit, user_id=scope_user_id)
    
    logger.info(
        f"✅ Found {len(sessions)} sessions for agent {agent_id}"
    )

    # Add metadata to each session
    sessions_with_metadata = []
    for session in sessions:
        session_data = session.copy()
        metadata = get_session_metadata(db, session["id"])
        session_data["metadata"] = metadata
        sessions_with_metadata.append(session_data)

    return success_response(
        data=sessions_with_metadata,
        message="Sessions retrieved successfully"
    )


@router.delete(
    "/bulk",
    status_code=status.HTTP_200_OK,
    response_model=SuccessResponse[BulkDeleteSessionsResponse],
    responses={
        200: {"description": "Bulk delete completed successfully"},
        500: {"model": ErrorResponse, "description": "Internal server error"}
    }
)
async def bulk_delete_sessions(
    request: BulkDeleteSessionsRequest,
    current_user: dict = Depends(get_current_user),
    _: None = Depends(RequirePermission("ai_chat_sessions", "bulk_delete")),
    db: Session = Depends(get_db)
):
    """
    Bulk delete multiple sessions.

    This endpoint allows deleting multiple sessions at once. It validates that the user
    has access to each session before deletion. Returns a summary of the operation
    including successful deletions and any failures.
    """
    # Validate each session and check permissions
    validated_session_ids = []
    permission_errors = []

    for session_id in request.session_ids:
        try:
            # Get the session to verify it exists and get agent info
            session = await get_session_by_id(session_service, session_id)
            if not session:
                permission_errors.append(
                    {"session_id": session_id, "error": "Session not found"}
                )
                continue

            # EVO-2103: same ownership rule as the single delete - agent access is
            # pool-wide and does not protect another owner's conversation.
            if not user_owns_session(current_user, session.user_id):
                permission_errors.append(
                    {"session_id": session_id, "error": "Access denied: you do not own this session"}
                )
                continue

            # Verify if the session's agent belongs to the user's client
            agent_id = uuid.UUID(session.app_name) if session.app_name else None
            if agent_id:
                agent = await agent_service.get_agent(db, agent_id)
                if agent:
                    try:
                        has_access, is_shared_access = await verify_agent_access(
                            db, agent, "read", current_user
                        )
                        validated_session_ids.append(session_id)
                    except HTTPException as e:
                        permission_errors.append(
                            {
                                "session_id": session_id,
                                "error": f"Access denied: {e.detail}",
                            }
                        )
                else:
                    permission_errors.append(
                        {"session_id": session_id, "error": "Agent not found"}
                    )
            else:
                permission_errors.append(
                    {"session_id": session_id, "error": "Invalid session format"}
                )

        except HTTPException as e:
            permission_errors.append({"session_id": session_id, "error": e.detail})
        except Exception as e:
            permission_errors.append(
                {"session_id": session_id, "error": f"Validation error: {str(e)}"}
            )

    # Perform bulk deletion on validated sessions
    if validated_session_ids:
        result = await delete_bulk_sessions(session_service, validated_session_ids, db=db)

        # Add permission errors to the failed sessions list
        result["failed_sessions"].extend(permission_errors)
        result["total_requested"] = len(request.session_ids)

        logger.info(
            f"Bulk delete completed: {result['deleted_count']}/{len(request.session_ids)} sessions deleted, "
            f"{len(permission_errors)} permission errors"
        )

        return success_response(
            data=result.model_dump() if hasattr(result, 'model_dump') else result,
            message=f"Bulk delete completed: {result['deleted_count']}/{len(request.session_ids)} sessions deleted"
        )
    else:
        # No sessions were validated for deletion
        result = BulkDeleteSessionsResponse(
            deleted_count=0,
            total_requested=len(request.session_ids),
            failed_sessions=permission_errors,
        )
        return success_response(
            data=result.model_dump() if hasattr(result, 'model_dump') else result,
            message="No sessions were validated for deletion"
        )


@router.get(
    "/{session_id}",
    response_model=SuccessResponse[SessionWithMetadata],
    responses={
        200: {"description": "Session retrieved successfully"},
        404: {"model": ErrorResponse, "description": "Session not found"},
        500: {"model": ErrorResponse, "description": "Internal server error"}
    }
)
async def get_session(
    request: Request,
    session_id: str,
    current_user: dict = Depends(get_current_user),
    _: None = Depends(RequirePermission("ai_agents", "read")),
    db: Session = Depends(get_db)
):
    # Get the session
    session = await get_session_by_id(session_service, session_id)
    if not session:
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_404_NOT_FOUND),
            message="Session not found",
            status_code=status.HTTP_404_NOT_FOUND
        )

    # Verify if the session's agent belongs to the user's client
    agent_id = None
    if session.app_name:
        try:
            agent_id = uuid.UUID(session.app_name)
        except ValueError:
            # app_name is not a UUID, skip agent verification
            pass
    if agent_id:
        agent = await agent_service.get_agent(db, agent_id)
        if agent:
            has_access, is_shared_access = await verify_agent_access(
                db, agent, "read", current_user
            )

    # EVO-2103: the session payload carries the ADK state of the conversation,
    # so it is owner-scoped like /messages.
    if not user_owns_session(current_user, session.user_id):
        logger.warning(
            f"Forbidden read on session {session_id}: owner={session.user_id!r} "
            f"logged={get_user_identity(current_user)!r}"
        )
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_403_FORBIDDEN),
            message="You do not own this session",
            status_code=status.HTTP_403_FORBIDDEN
        )

    return success_response(
        data=session.model_dump() if hasattr(session, 'model_dump') else session.__dict__,
        message="Session retrieved successfully"
    )


@router.get(
    "/{session_id}/messages",
    response_model=SuccessResponse[list],
    responses={
        200: {"description": "Messages retrieved successfully"},
        404: {"model": ErrorResponse, "description": "Session not found"},
        500: {"model": ErrorResponse, "description": "Internal server error"}
    }
)
async def get_agent_messages(
    request: Request,
    session_id: str,
    current_user: dict = Depends(get_current_user),
        _: None = Depends(RequirePermission("ai_agents", "read")),
    db: Session = Depends(get_db)
):
    """
    Gets messages from a session with embedded artifacts.

    This function loads all messages from a session and processes any references
    to artifacts, loading them and converting them to base64 for direct use in the frontend.
    """
    # Get the session - pass db to use the same database session
    session = await get_session_by_id(session_service, session_id, db=db)
    if not session:
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_404_NOT_FOUND),
            message="Session not found",
            status_code=status.HTTP_404_NOT_FOUND
        )

    # Verify if the session's agent belongs to the user's client
    agent_id = None
    if session.app_name:
        try:
            agent_id = uuid.UUID(session.app_name)
        except ValueError:
            # app_name is not a UUID, skip agent verification
            pass
    if agent_id:
        agent = await agent_service.get_agent(db, agent_id)
        if agent:
            has_access, is_shared_access = await verify_agent_access(
                db, agent, "read", current_user
            )

    # Get app_name and user_id from the session object instead of parsing session_id
    app_name = session.app_name
    user_id = session.user_id

    if not app_name or not user_id:
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_400_BAD_REQUEST),
            message="Session missing app_name or user_id",
            status_code=status.HTTP_400_BAD_REQUEST
        )

    # EVO-2103: session content must not leak across owners. A user may only
    # read messages of sessions they own (test panel sessions). Production
    # conversations are viewed via the CRM inbox, not this endpoint.
    if not user_owns_session(current_user, user_id):
        logger.warning(
            f"Forbidden read on session {session_id}: owner={user_id!r} "
            f"logged={get_user_identity(current_user)!r}"
        )
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_403_FORBIDDEN),
            message="You do not own this session",
            status_code=status.HTTP_403_FORBIDDEN
        )

    try:
        events = await get_session_events(session_service, session_id, db=db)

        processed_events = []
        skipped_count = 0
        for event in events:
            try:
                # Handle both Pydantic v2 (model_dump) and older versions
                if hasattr(event, "model_dump"):
                    event_dict = event.model_dump()
                elif hasattr(event, "dict"):
                    event_dict = event.dict()
                else:
                    event_dict = event.__dict__
            except Exception as e:
                logger.error(f"Error converting event to dictionary: {str(e)}", exc_info=True)
                skipped_count += 1
                continue

            try:
                # Process the content parts specifically
                if event_dict.get("content") and event_dict["content"].get("parts"):
                    for part in event_dict["content"]["parts"]:
                        # Process inlineData if present
                        if part and part.get("inlineData") and part["inlineData"].get("data"):
                            # Check if it's already a string or if it's bytes
                            if isinstance(part["inlineData"]["data"], bytes):
                                # Convert bytes to base64 string
                                part["inlineData"]["data"] = base64.b64encode(
                                    part["inlineData"]["data"]
                                ).decode("utf-8")
                                logger.debug(
                                    f"Converted binary data to base64 in message {event_dict.get('id')}"
                                )

                        # Process fileData if present (reference to an artifact)
                        if part and part.get("fileData") and part["fileData"].get("fileId"):
                            try:
                                # Extract the file name from the fileId
                                file_id = part["fileData"]["fileId"]

                                # Load the artifact from the artifacts service
                                artifact = artifacts_service.load_artifact(
                                    app_name=app_name,
                                    user_id=user_id,
                                    session_id=session_id,
                                    filename=file_id,
                                )

                                if artifact and hasattr(artifact, "inline_data"):
                                    # Extract the data and MIME type
                                    file_bytes = artifact.inline_data.data
                                    mime_type = artifact.inline_data.mime_type

                                    # Add inlineData with the artifact data
                                    if not part.get("inlineData"):
                                        part["inlineData"] = {}

                                    # Ensure we're sending a base64 string, not bytes
                                    if isinstance(file_bytes, bytes):
                                        try:
                                            part["inlineData"]["data"] = base64.b64encode(
                                                file_bytes
                                            ).decode("utf-8")
                                        except Exception as e:
                                            logger.error(
                                                f"Error encoding artifact to base64: {str(e)}"
                                            )
                                            part["inlineData"]["data"] = None
                                    else:
                                        part["inlineData"]["data"] = str(file_bytes)

                                    part["inlineData"]["mimeType"] = mime_type

                                    logger.debug(
                                        f"Loaded artifact {file_id} for message {event_dict.get('id')}"
                                    )
                            except Exception as e:
                                logger.error(f"Error loading artifact: {str(e)}")

                # Check artifact_delta in actions
                if event_dict.get("actions") and event_dict["actions"].get("artifact_delta"):
                    artifact_deltas = event_dict["actions"]["artifact_delta"]
                    for filename, version in artifact_deltas.items():
                        try:
                            # Load the artifact
                            artifact = artifacts_service.load_artifact(
                                app_name=app_name,
                                user_id=user_id,
                                session_id=session_id,
                                filename=filename,
                                version=version,
                            )

                            if artifact and hasattr(artifact, "inline_data"):
                                # If the event doesn't have an artifacts section, create it
                                if "artifacts" not in event_dict:
                                    event_dict["artifacts"] = {}

                                # Add the artifact to the event's artifacts list
                                file_bytes = artifact.inline_data.data
                                mime_type = artifact.inline_data.mime_type

                                # Ensure the bytes are converted to base64
                                event_dict["artifacts"][filename] = {
                                    "data": (
                                        base64.b64encode(file_bytes).decode("utf-8")
                                        if isinstance(file_bytes, bytes)
                                        else str(file_bytes)
                                    ),
                                    "mimeType": mime_type,
                                    "version": version,
                                }

                                logger.debug(
                                    f"Added artifact {filename} (v{version}) to message {event_dict.get('id')}"
                                )
                        except Exception as e:
                            logger.error(
                                f"Error processing artifact_delta {filename}: {str(e)}"
                            )

                processed_events.append(event_dict)
            except Exception as e:
                logger.error(f"Error processing event: {str(e)}", exc_info=True)
                skipped_count += 1
                continue

        if skipped_count > 0:
            logger.warning(f"Session {session_id}: {skipped_count} event(s) skipped due to processing errors")

        return success_response(
            data=processed_events,
            message=f"Session messages retrieved successfully (skipped {skipped_count})" if skipped_count > 0
            else "Session messages retrieved successfully"
        )
    except Exception as e:
        logger.error(f"Error retrieving session messages: {str(e)}", exc_info=True)
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_500_INTERNAL_SERVER_ERROR),
            message="Failed to retrieve session messages. Please try again or contact support if the issue persists.",
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR
        )


@router.delete(
    "/{session_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    responses={
        204: {"description": "Session deleted successfully"},
        404: {"model": ErrorResponse, "description": "Session not found"},
        500: {"model": ErrorResponse, "description": "Internal server error"}
    }
)
async def remove_session(
    request: Request,
    session_id: str,
    current_user: dict = Depends(get_current_user),
    _: None = Depends(RequirePermission("ai_agents", "delete")),
    db: Session = Depends(get_db)
):
    # Try to get the session
    try:
        session = await get_session_by_id(session_service, session_id)

        # Verify if the session's agent belongs to the user's client
        agent_id = None
        if session.app_name:
            try:
                agent_id = uuid.UUID(session.app_name)
            except ValueError:
                # app_name is not a UUID, skip agent verification
                pass
        if agent_id:
            agent = await agent_service.get_agent(db, agent_id)
            if agent:
                has_access, is_shared_access = await verify_agent_access(
                    db, agent, "read", current_user
                )

        # EVO-2103: agent access is pool-wide on the single-tenant box, so it does
        # not stop a user from deleting the session of a real customer conversation
        # owned by someone else. Ownership does. The CRM deletes those sessions with
        # an agent-bot key, which user_owns_session exempts.
        if not user_owns_session(current_user, session.user_id):
            logger.warning(
                f"Forbidden delete on session {session_id}: owner={session.user_id!r} "
                f"logged={get_user_identity(current_user)!r}"
            )
            return error_response(
                request=request,
                code=map_status_to_error_code(status.HTTP_403_FORBIDDEN),
                message="You do not own this session",
                status_code=status.HTTP_403_FORBIDDEN
            )

        # Delete the session (from both database and ADK)
        await delete_session(session_service, session_id, db=db)
        logger.info(f"Session {session_id} deleted successfully")
        return success_response(
            data=None,
            message="Session deleted successfully",
            status_code=204
        )

    except HTTPException as e:
        if e.status_code == 404:
            # Session doesn't exist - this is OK for DELETE (idempotent)
            logger.info(f"Session {session_id} not found, already deleted or never existed")
            # Return success anyway (idempotent DELETE)
            return None
        else:
            # Re-raise other HTTP exceptions (like permission errors)
            raise


# Session Metadata Routes
@router.get(
    "/{session_id}/metadata",
    response_model=SuccessResponse[SessionMetadata],
    responses={
        200: {"description": "Session metadata retrieved successfully"},
        404: {"model": ErrorResponse, "description": "Session not found"},
        500: {"model": ErrorResponse, "description": "Internal server error"}
    }
)
async def get_session_metadata_endpoint(
    request: Request,
    session_id: str,
    current_user: dict = Depends(get_current_user),
    _: None = Depends(RequirePermission("ai_agents", "read")),
    db: Session = Depends(get_db)
):
    """Get metadata for a specific session"""
    # Get the session first to verify access
    session = await get_session_by_id(session_service, session_id)
    if not session:
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_404_NOT_FOUND),
            message="Session not found",
            status_code=status.HTTP_404_NOT_FOUND
        )

    # Verify if the session's agent belongs to the user's client
    agent_id = None
    if session.app_name:
        try:
            agent_id = uuid.UUID(session.app_name)
        except ValueError:
            # app_name is not a UUID, skip agent verification
            pass
    if agent_id:
        agent = await agent_service.get_agent(db, agent_id)
        if agent:
            has_access, is_shared_access = await verify_agent_access(
                db, agent, "read", current_user
            )

    # EVO-2124: get_session_metadata() looks the row up by session_id ALONE, so
    # without this gate any holder of ai_agents.read reads the name/description/
    # tags of a session owned by someone else — including the real customer
    # conversations EVO-2103 fenced off on every other session-scoped route.
    # Same owner check as GET /{session_id}; agent bots stay exempt.
    if not user_owns_session(current_user, session.user_id):
        logger.warning(
            f"Forbidden metadata read on session {session_id}: owner={session.user_id!r} "
            f"logged={get_user_identity(current_user)!r}"
        )
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_403_FORBIDDEN),
            message="You do not own this session",
            status_code=status.HTTP_403_FORBIDDEN
        )

    # Get metadata
    metadata = get_session_metadata(db, session_id)
    if not metadata:
        return success_response(
            data={"session_id": session_id, "metadata": None},
            message="Session metadata retrieved successfully"
        )

    return success_response(
        data={"session_id": session_id, "metadata": metadata},
        message="Session metadata retrieved successfully"
    )


@router.put(
    "/{session_id}/metadata",
    response_model=SuccessResponse[SessionMetadata],
    responses={
        200: {"description": "Session metadata updated successfully"},
        404: {"model": ErrorResponse, "description": "Session not found"},
        500: {"model": ErrorResponse, "description": "Internal server error"}
    }
)
async def update_session_metadata_endpoint(
    request: Request,
    session_id: str,
    metadata: SessionMetadataUpdate,
    current_user: dict = Depends(get_current_user),
    _: None = Depends(RequirePermission("ai_agents", "write")),
    db: Session = Depends(get_db)
):
    """Update metadata for a specific session"""
    # Get the session first to verify access
    session = await get_session_by_id(session_service, session_id)
    if not session:
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_404_NOT_FOUND),
            message="Session not found",
            status_code=status.HTTP_404_NOT_FOUND
        )

    # Verify if the session's agent belongs to the user's client
    agent_id = None
    if session.app_name:
        try:
            agent_id = uuid.UUID(session.app_name)
        except ValueError:
            # app_name is not a UUID, skip agent verification
            pass
    if agent_id:
        agent = await agent_service.get_agent(db, agent_id)
        if agent:
            has_access, is_shared_access = await verify_agent_access(
                db, agent, "write", current_user
            )

    # EVO-2124: the service scopes the row by created_by_user_id, so a non-owner
    # cannot overwrite someone else's metadata — but it would silently CREATE a
    # row of their own hanging off another user's session. Deny at the door, like
    # every other session-scoped route (EVO-2103). Agent bots stay exempt.
    if not user_owns_session(current_user, session.user_id):
        logger.warning(
            f"Forbidden metadata write on session {session_id}: owner={session.user_id!r} "
            f"logged={get_user_identity(current_user)!r}"
        )
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_403_FORBIDDEN),
            message="You do not own this session",
            status_code=status.HTTP_403_FORBIDDEN
        )

    # Use user_id from the authenticated user
    user_id = str(current_user.get("user_id") or current_user.get("email") or "")

    # Try to update existing metadata first
    updated_metadata = update_session_metadata(db, session_id, user_id, metadata)

    if not updated_metadata:
        # Create new metadata if it doesn't exist
        metadata_create = SessionMetadataCreate(
            name=metadata.name, description=metadata.description, tags=metadata.tags
        )
        updated_metadata = create_session_metadata(
            db, session_id, user_id, metadata_create
        )

    return success_response(
        data={
            "session_id": session_id,
            "metadata": {
                "name": updated_metadata.name,
                "description": updated_metadata.description,
                "tags": updated_metadata.tags,
                "updated_at": updated_metadata.updated_at,
            },
        },
        message="Session metadata updated successfully"
    )


@router.delete(
    "/{session_id}/metadata",
    status_code=status.HTTP_204_NO_CONTENT,
    responses={
        204: {"description": "Session metadata deleted successfully"},
        404: {"model": ErrorResponse, "description": "Session not found"},
        500: {"model": ErrorResponse, "description": "Internal server error"}
    }
)
async def delete_session_metadata_endpoint(
    request: Request,
    session_id: str,
    current_user: dict = Depends(get_current_user),
    _: None = Depends(RequirePermission("ai_agents", "write")),
    db: Session = Depends(get_db)
):
    """Delete metadata for a specific session"""
    # Get the session first to verify access
    session = await get_session_by_id(session_service, session_id)
    if not session:
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_404_NOT_FOUND),
            message="Session not found",
            status_code=status.HTTP_404_NOT_FOUND
        )

    # Verify if the session's agent belongs to the user's client
    agent_id = None
    if session.app_name:
        try:
            agent_id = uuid.UUID(session.app_name)
        except ValueError:
            # app_name is not a UUID, skip agent verification
            pass
    if agent_id:
        agent = await agent_service.get_agent(db, agent_id)
        if agent:
            has_access, is_shared_access = await verify_agent_access(
                db, agent, "write", current_user
            )

    # EVO-2124: owner check before the delete, mirroring the other session-scoped
    # routes (EVO-2103). The service already scopes by created_by_user_id, so this
    # turns a misleading 404 into an honest 403 and keeps the doctrine uniform.
    if not user_owns_session(current_user, session.user_id):
        logger.warning(
            f"Forbidden metadata delete on session {session_id}: owner={session.user_id!r} "
            f"logged={get_user_identity(current_user)!r}"
        )
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_403_FORBIDDEN),
            message="You do not own this session",
            status_code=status.HTTP_403_FORBIDDEN
        )

    # Use user_id from the authenticated user
    user_id = str(current_user.get("user_id") or current_user.get("email") or "")

    deleted = delete_session_metadata(db, session_id, user_id)

    if not deleted:
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_404_NOT_FOUND),
            message="Session metadata not found or you don't have permission to delete it",
            status_code=status.HTTP_404_NOT_FOUND
        )

    return success_response(
        data=None,
        message="Session metadata deleted successfully",
        status_code=204
    )


# Internal sync endpoints (for CRM service) - accepts API key authentication
@router.post(
    "/sync/{agent_id}",
    response_model=SuccessResponse[SessionWithMetadata],
    status_code=status.HTTP_201_CREATED,
    include_in_schema=False,
    responses={
        404: {"description": "Not found"},
    }  # Hide from OpenAPI docs as it's internal
)
async def create_session_sync(
    agent_id: uuid.UUID,
    request_data: SessionCreateRequest,
    request: Request,
    x_api_key: str = Header(None, alias="x-api-key"),
    db: Session = Depends(get_db),
):
    """
    Internal endpoint for creating sessions from CRM.
    Accepts authentication via API key (for agent bots).
    """
    logger.info(f"[Sync] Creating session for agent {agent_id}")
    
    # Verify API key (skip if already validated by middleware for Agent Bots)
    user_context = getattr(request.state, "user_context", {})
    is_agent_bot = user_context.get("is_agent_bot", False)
    
    if not is_agent_bot:
        # Regular API key validation for non-Agent Bot requests
        await verify_api_key(db, x_api_key)
    else:
        logger.info(f"🤖 Agent Bot authentication already validated by middleware")
    
    # Verify agent exists
    agent = await get_agent(db, str(agent_id))
    if not agent:
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_404_NOT_FOUND),
            message=f"Agent {agent_id} not found",
            status_code=status.HTTP_404_NOT_FOUND
        )
    
    # Get session_id and user_id from request_data
    session_id = request_data.session_id or str(uuid.uuid4())
    user_id = request_data.user_id or str(uuid.uuid4())
    
    # Check if session already exists
    try:
        existing_session = await get_session_by_id(session_service, session_id, db=db)
        if existing_session:
            logger.info(f"[Sync] Session {session_id} already exists")
            return {
                "session_id": session_id,
                "agent_id": str(agent_id),
                "user_id": user_id,
                "status": "exists",
            }
    except HTTPException:
        # Session doesn't exist, continue with creation
        pass
    
    # Create session record directly in database
    try:
        db_session = SessionModel(
            id=session_id,
            app_name=str(agent_id),
            user_id=user_id,
            state={},
            create_time=datetime.now(),
            update_time=datetime.now(),
        )
        db.add(db_session)
        db.commit()
        db.refresh(db_session)
        
        logger.info(
            f"[Sync] ✅ Session {session_id} created: app_name={db_session.app_name}, user_id={db_session.user_id}"
        )
        
        # Create session in DatabaseSessionService (for ADK compatibility)
        try:
            await session_service.create_session(
                app_name=str(agent_id),
                user_id=user_id,
                session_id=session_id,
            )
            logger.info(f"[Sync] ✅ Session {session_id} also created in DatabaseSessionService")
        except Exception as adk_error:
            logger.warning(
                f"[Sync] ⚠️ Session {session_id} created in database but failed in DatabaseSessionService: {str(adk_error)}"
            )
        
        return {
            "session_id": session_id,
            "agent_id": str(agent_id),
            "user_id": user_id,
            "status": "created",
        }
        
    except Exception as create_error:
        db.rollback()
        logger.error(f"[Sync] ❌ Error creating session {session_id}: {str(create_error)}")
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_500_INTERNAL_SERVER_ERROR),
            message=f"Error creating session: {str(create_error)}",
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR
        )


@router.delete(
    "/sync/{session_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    include_in_schema=False,
    responses={
        404: {"model": ErrorResponse, "description": "Not found"},
    }  # Hide from OpenAPI docs as it's internal
)
async def delete_session_sync(
    session_id: str,
    request: Request,
    x_api_key: str = Header(None, alias="x-api-key"),
    db: Session = Depends(get_db),
):
    """
    Internal endpoint for deleting sessions from CRM.
    Accepts authentication via API key (for agent bots).
    """
    logger.info(f"[Sync] Deleting session {session_id}")
    
    # Verify API key (skip if already validated by middleware for Agent Bots)
    user_context = getattr(request.state, "user_context", {})
    is_agent_bot = user_context.get("is_agent_bot", False)
    
    if not is_agent_bot:
        # Regular API key validation for non-Agent Bot requests
        await verify_api_key(db, x_api_key)
    else:
        logger.info(f"🤖 Agent Bot authentication already validated by middleware")
    
    # Try to delete the session (from both database and ADK)
    try:
        await delete_session(session_service, session_id, db=db)
        logger.info(f"[Sync] ✅ Session {session_id} deleted successfully")
    except HTTPException as e:
        if e.status_code == 404:
            # Session doesn't exist - this is OK for DELETE (idempotent)
            logger.info(f"[Sync] ℹ️ Session {session_id} not found, already deleted or never existed")
            # Return success anyway (idempotent DELETE)
            return None
        else:
            # Re-raise other HTTP exceptions
            raise
    except Exception as e:
        logger.error(f"[Sync] ❌ Error deleting session {session_id}: {str(e)}")
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_500_INTERNAL_SERVER_ERROR),
            message=f"Error deleting session: {str(e)}",
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR
        )

    return success_response(
        data=None,
        message="Session deleted successfully",
        status_code=204
    )


@router.post(
    "/{session_id}/events",
    response_model=SessionEventResponse,
    status_code=status.HTTP_201_CREATED,
)
async def create_session_event(
    session_id: str,
    event_data: SessionEventCreate,
    request: Request,
    x_api_key: str = Header(
        None,
        responses={
            404: {"description": "Not found"}
        },
        alias="x-api-key"
    ),
    db: Session = Depends(get_db),
):
    """
    Create an event in a session.
    
    This endpoint allows adding events to sessions for synchronization purposes.
    Accepts authentication via API key (for agent bots) or bearer token.
    """
    logger.info(f"Creating event in session {session_id}")
    
    # Verify API key (skip if already validated by middleware for Agent Bots)
    user_context = getattr(request.state, "user_context", {})
    is_agent_bot = user_context.get("is_agent_bot", False)
    
    if not is_agent_bot:
        # Regular API key validation for non-Agent Bot requests
        await verify_api_key(db, x_api_key)
    else:
        logger.info(f"🤖 Agent Bot authentication already validated by middleware")
    
    # Try to get the session (get_session_by_id will auto-create in ADK if it exists in DB but not in ADK)
    try:
        session = await get_session_by_id(session_service, session_id, db=db)
    except HTTPException as e:
        # If session doesn't exist in database, create it automatically
        if e.status_code == status.HTTP_404_NOT_FOUND:
            logger.info(f"Session {session_id} not found in database, creating it automatically...")
            
            # Extract agent_id and conversation_uuid from session_id (format: {conversation_uuid}_{agent_id})
            parts = session_id.rsplit('_', 1)
            if len(parts) != 2:
                return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_400_BAD_REQUEST),
            message=f"Invalid session_id format: {session_id}. Expected format: {{conversation_uuid}}_{{agent_id}}",
            status_code=status.HTTP_400_BAD_REQUEST
        )
            
            conversation_uuid, agent_id_str = parts
            
            try:
                agent_id = uuid.UUID(agent_id_str)
            except ValueError:
                return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_400_BAD_REQUEST),
            message=f"Invalid agent_id in session_id: {agent_id_str}",
            status_code=status.HTTP_400_BAD_REQUEST
        )
            
            # Verify agent exists
            agent = await get_agent(db, agent_id)
            if not agent:
                return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_404_NOT_FOUND),
            message=f"Agent {agent_id} not found for session {session_id}",
            status_code=status.HTTP_404_NOT_FOUND
        )
            
            # Get user_id from request body (contact_id sent by Rails)
            # Try to get it from the raw request body since SessionEventCreate doesn't have user_id field
            try:
                request_body = await request.json()
                user_id = request_body.get('user_id', conversation_uuid)
            except Exception:
                # Fallback to conversation_uuid if we can't parse the request body
                user_id = conversation_uuid
            
            # Create session in database (check if it already exists first)
            from src.models.models import Session as SessionModel
            
            # Check if session already exists (race condition check)
            existing_session = db.query(SessionModel).filter(SessionModel.id == session_id).first()
            if existing_session:
                logger.info(f"Session {session_id} already exists in database, using existing session")
                db_session = existing_session
            else:
                try:
                    db_session = SessionModel(
                        id=session_id,
                        app_name=str(agent_id),
                        user_id=user_id,
                        state={}
                    )
                    db.add(db_session)
                    db.commit()
                    db.refresh(db_session)
                    logger.info(f"✅ Created session {session_id} in database with user_id={user_id}")
                except IntegrityError:
                    # Session was created by another process between check and creation
                    db.rollback()
                    logger.info(f"Session {session_id} was created concurrently, fetching existing session")
                    db_session = db.query(SessionModel).filter(SessionModel.id == session_id).first()
                    if not db_session:
                        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_500_INTERNAL_SERVER_ERROR),
            message=f"Failed to create or retrieve session {session_id}",
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR
        )
            
            # Create session in ADK (if it doesn't exist)
            try:
                session = await session_service.create_session(
                    app_name=str(agent_id),
                    user_id=user_id,
                    session_id=session_id,
                )
                logger.info(f"✅ Created session {session_id} in ADK")
            except Exception as adk_error:
                # Session might already exist in ADK, try to get it
                logger.info(f"Session might already exist in ADK, attempting to get it: {adk_error}")
                session = await session_service.get_session(
                    app_name=str(agent_id),
                    user_id=user_id,
                    session_id=session_id,
                )
                if not session:
                    return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_500_INTERNAL_SERVER_ERROR),
            message=f"Failed to create or retrieve ADK session {session_id}: {str(adk_error)}",
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR
        )
                logger.info(f"✅ Retrieved existing session {session_id} from ADK")
        else:
            raise e
    
    # Verify if the session's agent exists and is accessible
    agent_id = None
    if session.app_name:
        try:
            agent_id = uuid.UUID(session.app_name)
        except ValueError:
            # app_name is not a UUID, skip agent verification
            pass
    
    if agent_id:
        agent = await get_agent(db, agent_id)
        if not agent:
            return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_404_NOT_FOUND),
            message=f"Agent {agent_id} not found for session {session_id}",
            status_code=status.HTTP_404_NOT_FOUND
        )
    
    try:
        # Create event timestamp if not provided
        event_timestamp = event_data.timestamp if event_data.timestamp else time.time()
        
        # Generate invocation_id if not provided
        invocation_id = event_data.invocation_id or f"event_{int(event_timestamp)}_{uuid.uuid4().hex[:8]}"
        
        # Create Content object
        content = Content(
            role=event_data.role or "user",
            parts=[Part(text=event_data.content)]
        )
        
        # Create Event object
        event = Event(
            invocation_id=invocation_id,
            author=event_data.author,
            content=content,
            timestamp=event_timestamp,
        )
        
        # Append event to session
        await session_service.append_event(session, event)
        
        logger.info(
            f"✅ Successfully created event {invocation_id} in session {session_id}"
        )
        
        return SessionEventResponse(
            status="success",
            message=f"Event created successfully in session {session_id}",
            event_id=invocation_id,
            session_id=session_id,
        )
        
    except Exception as e:
        logger.error(f"❌ Error creating event in session {session_id}: {str(e)}")
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_500_INTERNAL_SERVER_ERROR),
            message=f"Error creating event: {str(e)}",
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR
        )
