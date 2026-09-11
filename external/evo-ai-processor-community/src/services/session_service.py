"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: session_service.py                                                    │
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

from google.adk.sessions import DatabaseSessionService
from sqlalchemy.orm import Session
from src.models.models import Session as SessionModel
from google.adk.events import Event
from google.adk.sessions import Session as SessionADK
from typing import Optional, List
from fastapi import HTTPException, status
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy import func

from src.services.agent_service import get_agents_by_account

import uuid
import logging
from src.models.models import SessionMetadata
from src.schemas.schemas import SessionMetadataCreate, SessionMetadataUpdate
from src.models.models import ExecutionMetrics
from src.schemas.schemas import ExecutionMetricsCreate
from src.models.models import Agent

logger = logging.getLogger(__name__)


class SessionLimitExceeded(Exception):
    """Exception raised when session limits are exceeded."""

    pass


def _session_to_dict(session: SessionModel):
    """Convert Session model to dictionary with created_at field"""
    # Serialize datetime objects to ISO format strings
    create_time_str = session.create_time.isoformat() if session.create_time else None
    update_time_str = session.update_time.isoformat() if session.update_time else None
    
    result = {
        "id": session.id,
        "app_name": session.app_name,
        "user_id": session.user_id,
        "state": session.state,
        "create_time": create_time_str,
        "update_time": update_time_str,
        "created_at": create_time_str,
    }
    return result


async def get_sessions_by_account(
    db: Session,
    user_id: str,
    user_email: Optional[str] = None,
) -> List[dict]:
    """Search for sessions of a client with pagination, including shared folder agents"""
    try:
        if user_email:
            # Get all agents accessible to the user (owned + shared)
            from src.services.agent_service import get_accessible_agents_for_account

            agents = get_accessible_agents_for_account(db, user_email)
        else:
            # Fallback to all agents if no user email provided
            agents = get_agents_by_account(db)

        sessions = []
        for agent in agents:
            # EVO-2103: scope to the caller. Without user_id this returned every
            # session of every accessible agent - including the real WhatsApp
            # conversations of other owners, and their session ids.
            db_sessions = await get_sessions_by_agent(db, agent.id, user_id=user_id)
            sessions.extend(db_sessions)

        return sessions
    except SQLAlchemyError as e:
        logger.error(f"Error searching for sessions of an account {user_id}: {str(e)}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Error searching for sessions",
        )


async def get_sessions_by_agent(
    db: Session,
    agent_id: uuid.UUID,
    skip: int = 0,
    limit: int = 100,
    user_id: Optional[str] = None,
) -> List[dict]:
    """Search for sessions of an agent with pagination, optionally filtered by user_id.

    IMPORTANT: This function queries ONLY the database (SessionModel table), NOT the ADK.
    All sessions must exist in the database to be returned.

    EVO-2103: only user_id=None means "no owner filter" (service credentials). An
    empty string is an identity that failed to resolve and filters to nothing -
    it must never widen the query back to every session of the agent.
    """
    try:
        agent_id_str = str(agent_id)
        
        # Force a fresh query by expiring all cached objects
        db.expire_all()
        
        # Build query directly from database (SessionModel table only)
        query = db.query(SessionModel).filter(SessionModel.app_name == agent_id_str)
        
        logger.info(
            f"🔍 Querying sessions from DATABASE ONLY for agent_id={agent_id_str}, user_id={user_id}, skip={skip}, limit={limit}"
        )
        
        # Filter by user_id if provided ("" filters, only None opts out)
        if user_id is not None:
            query = query.filter(SessionModel.user_id == user_id)
            logger.info(f"Filtering by user_id: {user_id}")
        else:
            logger.info("No user_id filter applied, returning all sessions for agent")

        # Execute query and get results directly from database
        # Use with_for_update(False) to ensure fresh data from database
        db_sessions = query.order_by(SessionModel.create_time.desc()).offset(skip).limit(limit).all()
        
        logger.info(
            f"Found {len(db_sessions)} sessions in database for agent {agent_id_str}"
        )
        
        # Convert each session to dictionary
        # Query database directly for each session ID to ensure it exists (bypass SQLAlchemy cache)
        result = []
        for session in db_sessions:
            if session and session.id:
                try:
                    # Query database directly using text() to bypass any SQLAlchemy cache
                    from sqlalchemy import text
                    check_query = text("SELECT id FROM sessions WHERE id = :session_id")
                    exists_result = db.execute(check_query, {"session_id": session.id}).first()
                    
                    if not exists_result:
                        logger.warning(
                            f"⚠️ Session {session.id} not found in database (direct SQL query), skipping"
                        )
                        continue
                    
                    # Convert to dict using the session object from original query
                    session_dict = _session_to_dict(session)
                    result.append(session_dict)
                    logger.debug(f"✅ Added session {session.id} to result")
                except Exception as e:
                    logger.warning(f"Error processing session {session.id}: {str(e)}")
                    continue
        
        logger.info(f"Returning {len(result)} valid sessions from database (filtered {len(db_sessions) - len(result)} invalid)")
        return result
    except SQLAlchemyError as e:
        logger.error(f"Error searching for sessions of agent {agent_id_str}: {str(e)}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Error searching for sessions",
        )


async def get_session_by_id(
    session_service: DatabaseSessionService, 
    session_id: str,
    db: Optional[Session] = None
) -> Optional[SessionADK]:
    """Search for a session by ID"""
    try:
        if not session_id:
            logger.error(f"Empty session ID provided")
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Session ID is required",
            )

        # Use provided db session or create a new one
        from src.config.database import get_db
        from sqlalchemy.orm import Session as SQLSession
        
        should_close_db = False
        if db is None:
            db_gen = get_db()
            db: SQLSession = next(db_gen)
            should_close_db = True

        try:
            db_session = (
                db.query(SessionModel).filter(SessionModel.id == session_id).first()
            )

            if not db_session:
                logger.error(f"Session not found in database: {session_id}")
                raise HTTPException(
                    status_code=status.HTTP_404_NOT_FOUND,
                    detail=f"Session not found: {session_id}",
                )

            # Now we have app_name and user_id, get the ADK session
            session = await session_service.get_session(
                app_name=db_session.app_name,
                user_id=db_session.user_id,
                session_id=session_id,
            )

            # If session doesn't exist in ADK but exists in database, create it in ADK
            if session is None:
                logger.info(
                    f"Session {session_id} exists in database but not in ADK, creating in ADK..."
                )
                try:
                    session = await session_service.create_session(
                        app_name=db_session.app_name,
                        user_id=db_session.user_id,
                        session_id=session_id,
                    )
                    logger.info(f"✅ Session {session_id} created in ADK successfully")
                except Exception as create_error:
                    logger.error(
                        f"Failed to create session {session_id} in ADK: {str(create_error)}"
                    )
                    raise HTTPException(
                        status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                        detail=f"Session exists in database but failed to create in ADK: {str(create_error)}",
                    )

            return session

        finally:
            if should_close_db:
                db.close()

    except Exception as e:
        logger.error(f"Error searching for session {session_id}: {str(e)}")
        if isinstance(e, HTTPException):
            raise e
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Error searching for session: {str(e)}",
        )


async def delete_session(
    session_service: DatabaseSessionService, session_id: str, db: Optional[Session] = None
) -> None:
    """Deletes a session by ID from both database and ADK"""
    should_close_db = False
    if db is None:
        from src.config.database import get_db
        db_gen = get_db()
        db = next(db_gen)
        should_close_db = True
    
    try:
        # First, try to get session info from database
        db_session = db.query(SessionModel).filter(SessionModel.id == session_id).first()
        
        if db_session:
            # Delete from database first
            db.delete(db_session)
            db.commit()
            logger.info(f"✅ Session {session_id} deleted from database")
        else:
            logger.warning(f"Session {session_id} not found in database, may have been already deleted")
        
        # Then delete from ADK if we have session info
        if db_session:
            try:
                await session_service.delete_session(
                    app_name=db_session.app_name,
                    user_id=db_session.user_id,
                    session_id=session_id,
                )
                logger.info(f"✅ Session {session_id} deleted from ADK")
            except Exception as adk_error:
                logger.warning(f"⚠️ Session {session_id} deleted from database but failed in ADK: {str(adk_error)}")
        
        # Also delete metadata if exists
        try:
            db.query(SessionMetadata).filter(SessionMetadata.session_id == session_id).delete()
            db.commit()
        except Exception as metadata_error:
            logger.warning(f"⚠️ Error deleting metadata for session {session_id}: {str(metadata_error)}")
        
        return None
    except Exception as e:
        if db:
            db.rollback()
        logger.error(f"Error deleting session {session_id}: {str(e)}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Error deleting session: {str(e)}",
        )
    finally:
        if should_close_db and db:
            db.close()


async def get_session_events(
    session_service: DatabaseSessionService, session_id: str, db: Optional[Session] = None
) -> List[Event]:
    """Search for the events of a session by ID"""
    try:
        session = await get_session_by_id(session_service, session_id, db=db)
        # If we get here, the session exists (get_session_by_id already validates)

        if not hasattr(session, "events") or session.events is None:
            return []

        # Sort events by timestamp in ascending order (oldest first)
        sorted_events = sorted(
            session.events,
            key=lambda event: event.timestamp if hasattr(event, "timestamp") else 0,
        )

        return sorted_events
    except Exception as e:
        logger.error(f"Error searching for events of session {session_id}: {str(e)}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Error searching for events of session: {str(e)}",
        )


async def delete_bulk_sessions(
    session_service: DatabaseSessionService, session_ids: List[str], db: Optional[Session] = None
) -> dict:
    """Deletes multiple sessions by their IDs"""
    should_close_db = False
    if db is None:
        from src.config.database import get_db
        db_gen = get_db()
        db = next(db_gen)
        should_close_db = True
    
    try:
        deleted_count = 0
        failed_sessions = []

        for session_id in session_ids:
            try:
                # Delete session (from both database and ADK)
                await delete_session(session_service, session_id, db=db)
                deleted_count += 1
                logger.info(f"Session deleted successfully: {session_id}")
            except HTTPException as e:
                # Handle specific HTTP exceptions (like session not found)
                if e.status_code == 404:
                    # Session doesn't exist - count as success (idempotent)
                    deleted_count += 1
                    logger.info(f"Session {session_id} not found, already deleted")
                else:
                    failed_sessions.append({"session_id": session_id, "error": e.detail})
                    logger.warning(f"Failed to delete session {session_id}: {e.detail}")
            except Exception as e:
                # Handle unexpected errors
                failed_sessions.append({"session_id": session_id, "error": str(e)})
                logger.error(
                    f"Unexpected error deleting session {session_id}: {str(e)}"
                )

        result = {
            "deleted_count": deleted_count,
            "total_requested": len(session_ids),
            "failed_sessions": failed_sessions,
        }

        logger.info(
            f"Bulk delete completed: {deleted_count}/{len(session_ids)} sessions deleted"
        )
        return result

    except Exception as e:
        logger.error(f"Error in bulk delete sessions: {str(e)}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Error in bulk delete sessions: {str(e)}",
        )
    finally:
        if should_close_db and db:
            db.close()


def get_session_metadata(db: Session, session_id: str) -> Optional[dict]:
    """Get metadata for a session"""
    try:
        metadata = (
            db.query(SessionMetadata)
            .filter(SessionMetadata.session_id == session_id)
            .first()
        )

        if metadata:
            # Serialize datetime objects to ISO format strings
            created_at_str = metadata.created_at.isoformat() if metadata.created_at else None
            updated_at_str = metadata.updated_at.isoformat() if metadata.updated_at else None
            
            return {
                "session_id": metadata.session_id,
                "name": metadata.name,
                "description": metadata.description,
                "tags": metadata.tags or [],
                "created_by_user_id": str(metadata.created_by_user_id),
                "created_at": created_at_str,
                "updated_at": updated_at_str,
            }
        return None
    except SQLAlchemyError as e:
        logger.error(f"Database error getting session metadata: {str(e)}")
        return None


def create_session_metadata(
    db: Session,
    session_id: str,
    user_id: str,
    metadata_data: SessionMetadataCreate,
) -> SessionMetadata:
    """Create metadata for a session"""
    try:
        db_metadata = SessionMetadata(
            session_id=session_id,
            name=metadata_data.name,
            description=metadata_data.description,
            tags=metadata_data.tags or [],
            created_by_user_id=user_id,
        )
        db.add(db_metadata)
        db.commit()
        db.refresh(db_metadata)
        logger.info(f"Created metadata for session {session_id}")
        return db_metadata
    except SQLAlchemyError as e:
        db.rollback()
        logger.error(f"Database error creating session metadata: {str(e)}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to create session metadata: {str(e)}",
        )


def update_session_metadata(
    db: Session,
    session_id: str,
    user_id: str,
    metadata_data: SessionMetadataUpdate,
) -> Optional[SessionMetadata]:
    """Update metadata for a session"""
    try:
        db_metadata = (
            db.query(SessionMetadata)
            .filter(
                SessionMetadata.session_id == session_id,
                SessionMetadata.created_by_user_id == user_id,
            )
            .first()
        )

        if not db_metadata:
            return None

        if metadata_data.name is not None:
            db_metadata.name = metadata_data.name
        if metadata_data.description is not None:
            db_metadata.description = metadata_data.description
        if metadata_data.tags is not None:
            db_metadata.tags = metadata_data.tags

        db.commit()
        db.refresh(db_metadata)
        logger.info(f"Updated metadata for session {session_id}")
        return db_metadata
    except SQLAlchemyError as e:
        db.rollback()
        logger.error(f"Database error updating session metadata: {str(e)}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to update session metadata: {str(e)}",
        )


def delete_session_metadata(db: Session, session_id: str, user_id: str) -> bool:
    """Delete metadata for a session"""
    try:
        deleted_rows = (
            db.query(SessionMetadata)
            .filter(
                SessionMetadata.session_id == session_id,
                SessionMetadata.created_by_user_id == user_id,
            )
            .delete()
        )

        db.commit()
        logger.info(f"Deleted metadata for session {session_id}")
        return deleted_rows > 0
    except SQLAlchemyError as e:
        db.rollback()
        logger.error(f"Database error deleting session metadata: {str(e)}")
        return False


def create_execution_metrics(
    db: Session, metrics_data: ExecutionMetricsCreate
) -> ExecutionMetrics:
    """Create execution metrics for a session"""
    try:
        db_metrics = ExecutionMetrics(
            agent_id=metrics_data.agent_id,
            session_id=metrics_data.session_id,
            user_id=metrics_data.user_id,
            llm_model=metrics_data.llm_model,
            prompt_tokens=metrics_data.prompt_tokens,
            candidate_tokens=metrics_data.candidate_tokens,
            cost=metrics_data.cost,
            total_tokens=metrics_data.total_tokens,
        )
        db.add(db_metrics)
        db.commit()
        db.refresh(db_metrics)
        logger.info(f"Created execution metrics for session {metrics_data.session_id}")
        return db_metrics
    except SQLAlchemyError as e:
        db.rollback()
        logger.error(f"Database error creating execution metrics: {str(e)}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to create execution metrics: {str(e)}",
        )


def get_execution_metrics(
    db: Session,
    user_id: Optional[str] = None,
    session_id: Optional[str] = None,
    agent_id: Optional[uuid.UUID] = None,
    skip: int = 0,
    limit: int = 100,
) -> dict:
    """Get execution metrics with optional filters, pagination, and totals."""
    try:
        query = db.query(ExecutionMetrics)

        if user_id:
            query = query.filter(ExecutionMetrics.user_id == user_id)

        if session_id:
            query = query.filter(ExecutionMetrics.session_id == session_id)

        if agent_id:
            query = query.filter(ExecutionMetrics.agent_id == agent_id)

        # Calculate totals from the filtered query
        totals_query = query.with_entities(
            func.sum(ExecutionMetrics.prompt_tokens).label("prompt_tokens"),
            func.sum(ExecutionMetrics.candidate_tokens).label("candidate_tokens"),
            func.sum(ExecutionMetrics.total_tokens).label("total_tokens"),
            func.sum(ExecutionMetrics.cost).label("cost"),
        ).first()

        totals = {
            "prompt_tokens": int(totals_query.prompt_tokens or 0),
            "candidate_tokens": int(totals_query.candidate_tokens or 0),
            "total_tokens": int(totals_query.total_tokens or 0),
            "cost": float(totals_query.cost or 0.0),
        }

        # Get paginated metrics
        metrics = (
            query.order_by(ExecutionMetrics.created_at.desc())
            .offset(skip)
            .limit(limit)
            .all()
        )
        return {"metrics": metrics, "totals": totals}
    except SQLAlchemyError as e:
        logger.error(f"Database error getting execution metrics: {str(e)}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to get execution metrics: {str(e)}",
        )
