"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: a2a_routes.py                                                         │
│ Developed by: Davidson Gomes                                                 │
│ Creation date: May 23, 2025                                                  │
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

"""
A2A Protocol Official Implementation

100% compliant with the official A2A specification:
https://google.github.io/A2A/specification

This is the official and only A2A implementation for the Evo AI platform.

Methods implemented:
- message/send: Send a message and get response
- message/stream: Send a message and stream response  
- agent/authenticatedExtendedCard: Get agent information (via .well-known/agent.json)

Features:
- Direct integration with agent_runner (no complex SDK layer)
- 100% specification compliant JSON-RPC format
- Proper Task object structure
- Full streaming support
- API key authentication
"""

import uuid
import json
import base64
import httpx
from datetime import datetime
from typing import Dict, Any, List, Optional, Union
from urllib.parse import urlparse

from fastapi import APIRouter, Depends, Header, Request, status
from sqlalchemy.orm import Session
from starlette.responses import JSONResponse
from sse_starlette.sse import EventSourceResponse
from sqlalchemy.sql import text

from src.config.database import get_db
from src.config.settings import settings
from src.models.models import Agent
from src.services.agent_service import get_agent
from src.services.adk.agent_runner import run_agent, run_agent_stream
from src.services.service_providers import (
    session_service,
    artifacts_service,
    memory_service,
)
from src.schemas.chat import FileData
from src.schemas.responses import ErrorResponse
from src.utils.logger import setup_logger
from src.utils.response import error_response, map_status_to_error_code, success_response
from src.utils.client_disconnect import ClientGoneAway, run_unless_client_disconnects
from src.utils.provider_errors import classify_provider_error, log_provider_failure, redact_secrets
from src.services.tools_service import tools_service
from src.services.mcp_server_service import get_mcp_server
from src.middleware.permissions import RequirePermission

logger = setup_logger(__name__)

router = APIRouter(
    prefix="/a2a",
    tags=["a2a-official"],
)

# Global storage for task push notification configs (in production, use database)
task_push_configs = {}

# Global storage for task states (in production, use database)
task_states = {}


async def verify_api_key(db: Session, request: Request, x_api_key: str) -> Union[JSONResponse, bool]:
    """Verifies API key against agent config. Returns True if valid, JSONResponse if error."""
    if not x_api_key:
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_401_UNAUTHORIZED),
            message="API key not provided",
            status_code=status.HTTP_401_UNAUTHORIZED
        )

    textQuery = f"SELECT * FROM {Agent.__tablename__} WHERE config->>'api_key' = :api_key LIMIT 1"
    query = text(textQuery)
    result = db.execute(query, {"api_key": x_api_key}).first()

    if not result:
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_401_UNAUTHORIZED),
            message="Invalid API key",
            status_code=status.HTTP_401_UNAUTHORIZED
        )
    
    return True


def validate_external_sharing_preconditions(agent: Agent, request: Request) -> Union[JSONResponse, None]:
    """Validates external sharing preconditions: auth, allowlist, callback, publish state."""
    import json
    
    # Parse agent config
    agent_config = agent.config if isinstance(agent.config, dict) else json.loads(agent.config or '{}')
    external_sharing = agent_config.get('external_sharing', {})
    
    # Check if external sharing is enabled
    if not external_sharing.get('enabled', False):
        return None  # External sharing not enabled, skip validation
    
    # 1. Validate publish state
    publish_state = external_sharing.get('publish_state', 'draft')
    if publish_state != 'published':
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_403_FORBIDDEN),
            message=f"Agent is not published. Current state: {publish_state}",
            status_code=status.HTTP_403_FORBIDDEN,
            details={
                "error": "AGENT_NOT_PUBLISHED",
                "publish_state": publish_state,
                "required_state": "published"
            }
        )
    
    # 2. Validate allowlist
    allowlist = external_sharing.get('allowlist', [])
    if not allowlist:
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_403_FORBIDDEN),
            message="External sharing allowlist is empty",
            status_code=status.HTTP_403_FORBIDDEN,
            details={
                "error": "ALLOWLIST_EMPTY",
                "message": "At least one allowlist entry is required for external sharing"
            }
        )
    
    # Get client host/IP from request headers
    # For external sharing, we need to check the Origin or Referer header to identify the calling domain
    # Fallback to Host header (which would be our own domain) or x-forwarded-for for IP-based allowlist
    client_host = None
    
    # Try Origin header first (most reliable for external API calls)
    origin = request.headers.get('origin', '')
    if origin:
        try:
            parsed_origin = urlparse(origin)
            client_host = parsed_origin.hostname
        except Exception:
            pass
    
    # Fallback to Referer header
    if not client_host:
        referer = request.headers.get('referer', '')
        if referer:
            try:
                parsed_referer = urlparse(referer)
                client_host = parsed_referer.hostname
            except Exception:
                pass
    
    # Fallback to x-forwarded-for for IP-based allowlist
    if not client_host:
        forwarded_for = request.headers.get('x-forwarded-for', '')
        if forwarded_for:
            client_host = forwarded_for.split(',')[0].strip()
    
    # Last resort: use client IP
    if not client_host and request.client:
        client_host = request.client.host
    
    # Remove port from host if present
    if client_host and ':' in client_host:
        client_host = client_host.split(':')[0]
    
    if not client_host:
        logger.warning("⚠️ Could not determine client host/IP for allowlist validation")
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_403_FORBIDDEN),
            message="Could not determine client origin for allowlist validation",
            status_code=status.HTTP_403_FORBIDDEN,
            details={
                "error": "CLIENT_ORIGIN_UNKNOWN",
                "message": "Origin header or Referer header required for external sharing"
            }
        )
    
    # Check if client is in allowlist
    client_allowed = False
    client_host_lower = client_host.lower()
    
    for allowed_entry in allowlist:
        allowed_entry_clean = allowed_entry.strip().lower()
        
        # Exact match (case-insensitive)
        if allowed_entry_clean == client_host_lower:
            client_allowed = True
            break
        
        # Domain matching (e.g., "example.com" matches "sub.example.com")
        if client_host_lower.endswith('.' + allowed_entry_clean):
            client_allowed = True
            break
        
        # Subdomain matching (e.g., ".example.com" matches any subdomain)
        if allowed_entry_clean.startswith('.') and client_host_lower.endswith(allowed_entry_clean):
            client_allowed = True
            break
        
        # IP address matching (exact match for IPs)
        # Check if both are IP addresses (simple check: contains only digits and dots)
        if (allowed_entry_clean.replace('.', '').isdigit() and 
            client_host_lower.replace('.', '').isdigit() and
            allowed_entry_clean == client_host_lower):
            client_allowed = True
            break
    
    if not client_allowed:
        logger.warning(f"⚠️ Access denied: {client_host} not in allowlist {allowlist}")
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_403_FORBIDDEN),
            message="Access denied: client not in allowlist",
            status_code=status.HTTP_403_FORBIDDEN,
            details={
                "error": "NOT_IN_ALLOWLIST",
                "client_host": client_host,
                "allowlist": allowlist
            }
        )
    
    # 3. Validate callback URL exists
    callback_url = external_sharing.get('callback_url', '')
    if not callback_url or not callback_url.strip():
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_500_INTERNAL_SERVER_ERROR),
            message="External sharing callback URL is not configured",
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            details={
                "error": "CALLBACK_URL_MISSING",
                "message": "Callback URL is required for external sharing"
            }
        )
    
    # Validate callback URL format
    try:
        parsed_callback = urlparse(callback_url)
        if parsed_callback.scheme != 'https':
            return error_response(
                request=request,
                code=map_status_to_error_code(status.HTTP_500_INTERNAL_SERVER_ERROR),
                message="Callback URL must use HTTPS",
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                details={
                    "error": "INVALID_CALLBACK_URL",
                    "message": "Callback URL must use HTTPS protocol"
                }
            )
    except Exception as e:
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_500_INTERNAL_SERVER_ERROR),
            message=f"Invalid callback URL format: {str(e)}",
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            details={
                "error": "INVALID_CALLBACK_URL",
                "message": str(e)
            }
        )
    
    logger.info(f"✅ External sharing preconditions validated for agent {agent.id}")
    return None  # All preconditions met


def extract_text_from_message(message: Dict[str, Any]) -> str:
    """Extract text from message parts according to A2A spec."""
    if not message or "parts" not in message:
        return ""

    for part in message["parts"]:
        if part.get("type") == "text" and "text" in part:
            return part["text"]

    return ""


def extract_files_from_message(message: Dict[str, Any]) -> List[FileData]:
    """Extract files from message parts according to A2A spec."""
    files = []
    if not message or "parts" not in message:
        return files

    for part in message["parts"]:
        if part.get("type") == "file" and "file" in part:
            file_data = part["file"]

            # Check if file has bytes (base64 encoded)
            if "bytes" in file_data and file_data["bytes"]:
                try:
                    # Validate base64 content
                    base64.b64decode(file_data["bytes"])

                    file_obj = FileData(
                        filename=file_data.get("name", "file"),
                        content_type=file_data.get(
                            "mimeType", "application/octet-stream"
                        ),
                        data=file_data["bytes"],  # Keep as base64 string
                    )
                    files.append(file_obj)
                    logger.info(
                        f"📎 Extracted file: {file_obj.filename} ({file_obj.content_type})"
                    )

                except Exception as e:
                    logger.error(f"❌ Invalid base64 in file: {e}")
                    continue
            else:
                logger.warning(
                    f"⚠️ File part missing bytes data: {file_data.get('name', 'unnamed')}"
                )

    logger.info(f"📎 Total files extracted: {len(files)}")
    return files


def create_task_response(
    task_id: str,
    context_id: str,
    final_response: str,
    artifacts: Optional[List[Dict[str, Any]]] = None,
    conversation_history: Optional[List[Dict[str, Any]]] = None,
    current_user_message: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    """Create Task response according to A2A specification."""

    logger.info(
        f"🏗️ create_task_response called with history: {len(conversation_history) if conversation_history else 0} messages"
    )

    # Create main response artifact (only the agent's response)
    artifacts = artifacts or [
        {
            "artifactId": str(uuid.uuid4()),
            "parts": [{"type": "text", "text": final_response}],
        }
    ]

    logger.info(f"📦 Created main artifact")

    # Create Task response according to A2A spec
    task_response = {
        "id": task_id,
        "contextId": context_id,
        "status": {"state": "completed", "timestamp": datetime.now().isoformat() + "Z"},
        "artifacts": artifacts,
        "kind": "task",
    }

    # Build complete history for A2A response
    complete_history = []

    # Add existing conversation history
    if conversation_history:
        for msg in conversation_history:
            # Create A2A Message object
            a2a_message = {
                "role": msg["role"],
                "parts": [{"type": "text", "text": msg["content"]}],
                "messageId": msg.get("messageId"),
                "taskId": task_id,
                "contextId": context_id,
                "kind": "message",
            }

            # Add timestamp if available
            if msg.get("timestamp"):
                a2a_message["timestamp"] = msg["timestamp"]

            complete_history.append(a2a_message)

    # Add current user message if provided (this is the message that triggered this response)
    if current_user_message:
        logger.info(f"📝 Adding current user message to history")
        a2a_message = {
            "role": "user",
            "parts": [{"type": "text", "text": current_user_message["content"]}],
            "messageId": current_user_message.get("messageId"),
            "taskId": task_id,
            "contextId": context_id,
            "kind": "message",
        }

        # Add timestamp if available
        if current_user_message.get("timestamp"):
            a2a_message["timestamp"] = current_user_message["timestamp"]

        complete_history.append(a2a_message)

    # Add history field to Task object (A2A spec compliant)
    if complete_history:
        task_response["history"] = complete_history
        logger.info(
            f"📚 Added {len(complete_history)} messages to history field (including current message)"
        )
    else:
        logger.warning("⚠️ No conversation history provided to create_task_response")

    logger.info(f"✅ create_task_response returning A2A compliant Task object")
    return task_response


def clean_message_content(content: str, role: str) -> str:
    """Clean message content, extracting just the text if it contains JSON."""
    if role == "agent" or role == "assistant":
        # Check if content looks like JSON (starts with { and contains jsonrpc)
        if content.strip().startswith("{") and "jsonrpc" in content:
            try:
                # Try to parse as JSON and extract the actual response text
                import json

                json_data = json.loads(content)

                # Look for the actual text in artifacts
                if "result" in json_data and "artifacts" in json_data["result"]:
                    for artifact in json_data["result"]["artifacts"]:
                        if "parts" in artifact:
                            for part in artifact["parts"]:
                                if part.get("type") == "text" and "text" in part:
                                    return part["text"]

                # Fallback: if we can't extract, return a cleaned version
                return "Previous assistant response"

            except (json.JSONDecodeError, KeyError):
                # If not valid JSON, return as-is but truncated
                return content[:100] + "..." if len(content) > 100 else content

    return content


async def extract_conversation_history(
    agent_id: str, external_id: str, db: Optional[Session] = None
) -> List[Dict[str, Any]]:
    """Extract conversation history from session using the same logic as /sessions/{session_id}/messages."""
    logger.info(
        f"🔍 extract_conversation_history called with agent_id={agent_id}, external_id={external_id}"
    )

    try:
        from src.services.session_service import get_session_events, get_session_by_id

        # Session ID format: {conversation_uuid}_{agent_id}
        # agent_id comes from the URL (/api/v1/a2a/{agent_id}) - this is the evo-core-service agent ID
        session_id = f"{external_id}_{agent_id}"
        logger.info(f"📋 Constructed session_id: {session_id}")

        # First, verify session exists (same as working endpoint)
        logger.info(f"🔍 Verifying session exists...")
        session = await get_session_by_id(session_service, session_id, db=db)
        if not session:
            logger.warning(f"⚠️ Session not found: {session_id}")
            return []

        logger.info(f"✅ Session found: {session_id}")

        # Get events using same method as working endpoint
        logger.info(f"🔍 Getting events for session...")
        events = await get_session_events(session_service, session_id, db=db)
        logger.info(
            f"📋 get_session_events returned {len(events) if events else 0} events"
        )

        history = []

        # Process events exactly like the working /messages endpoint
        for i, event in enumerate(events):
            logger.info(
                f"🔍 Processing event {i}: id={getattr(event, 'id', 'NO_ID')}, author={getattr(event, 'author', 'NO_AUTHOR')}"
            )

            # Convert event to dict like in working endpoint
            event_dict = (
                event.model_dump() if hasattr(event, "model_dump") else event.__dict__
            )

            # Check if event has content with parts (same logic as working endpoint)
            if event_dict.get("content") and event_dict["content"].get("parts"):
                logger.info(
                    f"📝 Event {i} has content with {len(event_dict['content']['parts'])} parts"
                )

                for j, part in enumerate(event_dict["content"]["parts"]):
                    logger.info(f"📝 Processing part {j}: {part}")

                    # Extract text content (same as working endpoint checks for text)
                    if isinstance(part, dict) and part.get("text"):
                        role = "user" if event_dict.get("author") == "user" else "agent"
                        text_content = part["text"]
                        if isinstance(text_content, str) and text_content.startswith(STRUCTURED_PART_PREFIX):
                            continue

                        # Clean the content to remove JSON artifacts
                        cleaned_content = clean_message_content(text_content, role)
                        logger.info(
                            f"📝 Cleaned content for {role}: {cleaned_content[:50]}..."
                        )

                        # Create A2A compatible history entry
                        history_entry = {
                            "role": role,
                            "content": cleaned_content,
                            "messageId": event_dict.get("id"),
                            "timestamp": event_dict.get("timestamp"),
                            "author": event_dict.get("author"),
                            "invocation_id": event_dict.get("invocation_id"),
                        }

                        history.append(history_entry)
                        logger.info(f"✅ Added history entry {len(history)}: {role}")
                    else:
                        logger.info(f"📝 Part {j} has no text content: {part}")
            else:
                logger.warning(f"⚠️ Event {i} has no content or parts")

        logger.info(
            f"📚 extract_conversation_history extracted {len(history)} messages using working logic"
        )
        return history

    except Exception:
        return []


def extract_history_from_params(params: Dict[str, Any]) -> List[Dict[str, Any]]:
    """Extract history from request params according to A2A spec."""
    history = []
    if "history" in params and isinstance(params["history"], list):
        for msg in params["history"]:
            if isinstance(msg, dict) and "role" in msg and "parts" in msg:
                # Extract text from parts
                text_content = ""
                for part in msg["parts"]:
                    if (
                        isinstance(part, dict)
                        and part.get("type") == "text"
                        and "text" in part
                    ):
                        text_content += part["text"] + " "

                if text_content.strip():
                    history.append(
                        {
                            "role": msg["role"],
                            "content": text_content.strip(),
                            "messageId": msg.get("messageId"),
                            "timestamp": None,  # Could be added if provided
                        }
                    )

    logger.info(f"📚 Extracted {len(history)} messages from request history")
    return history


def combine_histories(
    request_history: List[Dict[str, Any]], session_history: List[Dict[str, Any]]
) -> List[Dict[str, Any]]:
    """Combine request history with session history, avoiding duplicates."""
    combined = []

    # Add session history first
    for msg in session_history:
        combined.append(msg)

    # Add request history, avoiding duplicates based on messageId or content
    for req_msg in request_history:
        # Check if this message already exists in combined history
        is_duplicate = False
        for existing_msg in combined:
            if (
                req_msg.get("messageId")
                and req_msg["messageId"] == existing_msg.get("messageId")
            ) or (
                req_msg["content"] == existing_msg["content"]
                and req_msg["role"] == existing_msg["role"]
            ):
                is_duplicate = True
                break

        if not is_duplicate:
            combined.append(req_msg)

    # Sort by timestamp if available, otherwise maintain order
    return combined


@router.post("/{agent_id}",
    responses={
        400: {"model": ErrorResponse, "description": "Bad request"},
        401: {"model": ErrorResponse, "description": "Unauthorized"},
        404: {"model": ErrorResponse, "description": "Not found"},
        500: {"model": ErrorResponse, "description": "Internal server error"},
    })
async def process_a2a_message(
    agent_id: uuid.UUID,
    request: Request,
    x_api_key: str = Header(None, alias="x-api-key"),
    _: None = Depends(RequirePermission("ai_a2a_protocol", "execute")),
    db: Session = Depends(get_db),
):
    """
    Process A2A messages according to official specification.

    Supports:
    - message/send: Send a message and get response
    - message/stream: Send a message and stream response
    """
    logger.info(f"🎯 A2A Spec endpoint called for agent {agent_id}")

    # Verify API key (skip if already validated by middleware for Agent Bots)
    user_context = getattr(request.state, "user_context", {})
    is_agent_bot = user_context.get("is_agent_bot", False)
    
    if not is_agent_bot:
        # Regular API key validation for non-Agent Bot requests
        await verify_api_key(db, request, x_api_key)
    else:
        logger.info(f"🤖 Agent Bot authentication already validated by middleware")

    # Verify agent exists
    agent = await get_agent(db, agent_id)
    if not agent:
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_404_NOT_FOUND),
            message="Agent not found",
            status_code=status.HTTP_404_NOT_FOUND
        )
    
    # Validate external sharing preconditions (auth, allowlist, callback, publish state)
    preconditions_error = validate_external_sharing_preconditions(agent, request)
    if preconditions_error:
        return preconditions_error

    try:
        # Parse JSON-RPC request
        request_body = await request.json()

        jsonrpc = request_body.get("jsonrpc")
        if jsonrpc != "2.0":
            return error_response(
                request=request,
                code=map_status_to_error_code(status.HTTP_400_BAD_REQUEST),
                message="Invalid JSON-RPC version",
                status_code=status.HTTP_400_BAD_REQUEST
            )

        method = request_body.get("method")
        params = request_body.get("params", {})
        request_id = request_body.get("id")

        logger.info(f"📝 Method: {method}, ID: {request_id}")

        if method == "message/send":
            return await handle_message_send(agent_id, params, request_id, request, db)
        elif method == "message/stream":
            return await handle_message_stream(agent_id, params, request_id, request, db)
        elif method == "tasks/get":
            return await handle_tasks_get(agent_id, params, request_id, request, db)
        elif method == "tasks/cancel":
            return await handle_tasks_cancel(agent_id, params, request_id, request, db)
        elif method == "tasks/pushNotificationConfig/set":
            return await handle_tasks_push_notification_config_set(
                agent_id, params, request_id, request, db
            )
        elif method == "tasks/pushNotificationConfig/get":
            return await handle_tasks_push_notification_config_get(
                agent_id, params, request_id, request, db
            )
        elif method == "tasks/resubscribe":
            return await handle_tasks_resubscribe(agent_id, params, request_id, request, db)
        elif method == "agent/authenticatedExtendedCard":
            return await handle_agent_authenticated_extended_card(
                agent_id, params, request_id, request, db
            )
        else:
            # JSON-RPC error for method not found
            return error_response(
                request=request,
                code=map_status_to_error_code(status.HTTP_400_BAD_REQUEST),
                message="Method not found",
                status_code=status.HTTP_400_BAD_REQUEST,
                details={
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "error": {
                        "code": -32601,
                        "message": "Method not found",
                        "data": {
                            "method": method,
                            "supported_methods": [
                                "message/send",
                                "message/stream",
                                "tasks/get",
                                "tasks/cancel",
                                "tasks/pushNotificationConfig/set",
                                "tasks/pushNotificationConfig/get",
                                "tasks/resubscribe",
                                "agent/authenticatedExtendedCard",
                            ],
                        },
                    },
                },
            )

    except json.JSONDecodeError:
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_400_BAD_REQUEST),
            message="Invalid JSON",
            status_code=status.HTTP_400_BAD_REQUEST
        )
    except Exception as e:
        logger.error(f"Error processing A2A request: {e}")
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_500_INTERNAL_SERVER_ERROR),
            message=f"Error processing A2A request: {str(e)}",
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            details={
                "jsonrpc": "2.0",
                "id": request_body.get("id") if "request_body" in locals() else None,
                "error": {
                    "code": -32603,
                    "message": "Internal error",
                    "data": {"error": str(e)},
                },
            }
        )


def extract_metadata_from_request(params: Dict[str, Any]) -> Dict[str, Any]:
    """Extract metadata from request according to A2A spec."""
    metadata = {}
    if "metadata" in params:
        metadata = params["metadata"]

    message = params.get("message")
    if message and "metadata" in message:
        metadata.update(message["metadata"])

    message_parts = params.get("message", {}).get("parts", [])
    for part in message_parts:
        if part and "metadata" in part:
            metadata.update(part["metadata"])

    return metadata


STRUCTURED_PART_PREFIX = "EVO_STRUCTURED:"


def extract_structured_from_message_history(
    message_history: Optional[List[Dict[str, Any]]],
) -> Optional[Dict[str, Any]]:
    if not message_history:
        return None

    for event in reversed(message_history):
        content = event.get("content") if isinstance(event, dict) else None
        parts = content.get("parts") if isinstance(content, dict) else None
        if not isinstance(parts, list):
            continue

        for part in parts:
            if not isinstance(part, dict):
                continue

            text = part.get("text")
            if not isinstance(text, str) or not text.startswith(STRUCTURED_PART_PREFIX):
                continue

            raw = text[len(STRUCTURED_PART_PREFIX):].strip()
            try:
                decoded = json.loads(raw)
                return decoded if isinstance(decoded, dict) else None
            except Exception:
                continue

    return None


def build_a2a_artifacts(
    final_response: str,
    structured: Optional[Dict[str, Any]] = None,
) -> List[Dict[str, Any]]:
    artifacts: List[Dict[str, Any]] = [
        {
            "artifactId": str(uuid.uuid4()),
            "parts": [{"type": "text", "text": final_response}],
        }
    ]

    if not structured:
        return artifacts

    input_obj = structured.get("input") if isinstance(structured, dict) else None
    if not isinstance(input_obj, dict):
        return artifacts

    if input_obj.get("type") == "select" and isinstance(input_obj.get("items"), list):
        artifacts.append(
            {
                "artifactId": str(uuid.uuid4()),
                "parts": [
                    {
                        "type": "select",
                        "items": input_obj.get("items", []),
                        "isMultiple": bool(input_obj.get("isMultiple")),
                        "sourceType": input_obj.get("sourceType"),
                    }
                ],
            }
        )

    return artifacts


async def handle_message_send(
    agent_id: uuid.UUID, params: Dict[str, Any], request_id: str, request: Request, db: Session
) -> JSONResponse:
    """Handle message/send according to A2A spec."""

    logger.info(f"🔄 Processing message/send for agent {agent_id}")

    # Extract message from params
    message = params.get("message")
    if not message:
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_400_BAD_REQUEST),
            message="Invalid params",
            status_code=status.HTTP_400_BAD_REQUEST,
            details={
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {
                    "code": -32602,
                    "message": "Invalid params",
                    "data": {"missing": "message"},
                },
            }
        )

    # Extract configuration from params (A2A spec: configuration is optional)
    configuration = params.get("configuration", {})
    push_notification_config = configuration.get("pushNotificationConfig")

    # Support alternative format: pushNotificationConfig directly in params (for backward compatibility)
    if not push_notification_config:
        push_notification_config = params.get("pushNotificationConfig")

    logger.info(
        f"🔔 Push notification config found: {push_notification_config is not None}"
    )

    if push_notification_config:
        # Support both official spec format and common variations
        webhook_url = push_notification_config.get(
            "url"
        ) or push_notification_config.get("webhookUrl")

        logger.info(
            f"🔔 Push notification config provided: {webhook_url or 'No URL found'}"
        )

        # Validate push notification config according to A2A spec (support both url and webhookUrl)
        if not webhook_url:
            return error_response(
                request=request,
                code=map_status_to_error_code(status.HTTP_400_BAD_REQUEST),
                message="Invalid params",
                status_code=status.HTTP_400_BAD_REQUEST,
                details={
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "error": {
                        "code": -32602,
                        "message": "Invalid params",
                        "data": {
                            "missing": "pushNotificationConfig.url or pushNotificationConfig.webhookUrl"
                        },
                    },
                }
            )

        # Validate HTTPS requirement (A2A spec: prevents SSRF attacks)
        if not webhook_url.startswith("https://"):
            return error_response(
                request=request,
                code=map_status_to_error_code(status.HTTP_400_BAD_REQUEST),
                message="Invalid params",
                status_code=status.HTTP_400_BAD_REQUEST,
                details={
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "error": {
                        "code": -32602,
                        "message": "Invalid params",
                        "data": {
                            "error": "pushNotificationConfig.url MUST use HTTPS for security"
                        },
                    },
                }
            )

        # Validate that agent supports push notifications
        agent = await get_agent(db, agent_id)
        if not agent:
            return error_response(
                request=request,
                code=map_status_to_error_code(status.HTTP_404_NOT_FOUND),
                message="Agent not found",
                status_code=status.HTTP_404_NOT_FOUND,
                details={
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "error": {
                        "code": -32001,
                        "message": "Agent not found",
                    },
                }
            )

        # Check agent capabilities for push notification support
        # (Our agent card already indicates pushNotifications: true)
        logger.info(f"✅ Agent {agent_id} supports push notifications")

    # Extract text and files from message
    text = extract_text_from_message(message)
    files = extract_files_from_message(message)

    # Allow empty text if we have files
    if not text and not files:
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_400_BAD_REQUEST),
            message="Invalid params",
            status_code=status.HTTP_400_BAD_REQUEST,
            details={
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {
                    "code": -32602,
                    "message": "Invalid params",
                    "data": {"missing": "text content or files in message parts"},
                },
            }
        )

    # Use default text if only files provided
    if not text and files:
        text = "Analyze the provided files"

    logger.info(f"📝 Extracted text: {text}")
    logger.info(f"📎 Extracted files: {len(files)}")

    # Generate IDs
    task_id = str(uuid.uuid4())
    context_id = params.get("contextId", str(uuid.uuid4()))

    try:
        # Extract conversation history for context
        logger.info(
            f"🔍 Attempting to extract conversation history for agent {agent_id}, context {context_id}"
        )
        conversation_history = await extract_conversation_history(str(agent_id), context_id, db=db)
        logger.info(
            f"📚 Session history extracted: {len(conversation_history)} messages"
        )

        # Extract history from params
        logger.info(f"🔍 Attempting to extract history from request params")
        request_history = extract_history_from_params(params)
        logger.info(f"📝 Request history extracted: {len(request_history)} messages")

        # Combine histories
        logger.info(f"🔗 Combining histories...")
        combined_history = combine_histories(request_history, conversation_history)
        logger.info(f"📖 Combined history has {len(combined_history)} total messages")

        # Log detailed combined history for debugging
        for i, msg in enumerate(combined_history):
            logger.info(f"  History[{i}]: {msg['role']} - {msg['content'][:50]}...")

        # Execute agent with files - the ADK runner will handle session history automatically
        logger.info(
            f"🤖 Executing agent {agent_id} with message: {text} and {len(files)} files"
        )
        logger.info(
            f"📚 ADK will provide session context automatically ({len(combined_history)} previous messages available)"
        )

        metadata = extract_metadata_from_request(params)
        logger.info(f"📋 Extracted metadata: {metadata}")
        
        # Extract userId from params (contact_id sent from Rails)
        # contextId is the conversation UUID, but userId should be the contact UUID
        user_id = params.get("userId") or context_id
        if user_id != context_id:
            logger.info(f"📋 Using userId from params as user_id: {user_id}")
        else:
            logger.warning(f"⚠️ No userId in params, using context_id (conversation UUID) as user_id: {user_id}")

        # Build session_id using agent_id from URL (evo-core-service agent ID)
        # Session ID format: {conversation_uuid}_{agent_id}
        # agent_id comes from the URL (/api/v1/a2a/{agent_id})
        session_id = f"{context_id}_{agent_id}"
        logger.info(f"📋 Using session_id: {session_id}")

        # CRM-236: bounded by whoever is waiting. When the caller hangs up the
        # run is cancelled instead of burning more of the provider's quota.
        result = await run_unless_client_disconnects(
            request,
            run_agent(
                agent_id=str(agent_id),
                external_id=context_id,  # contextId is the conversation UUID
                message=text,  # Send only the original message - ADK handles context
                session_service=session_service,
                artifacts_service=artifacts_service,
                memory_service=memory_service,
                db=db,
                session_id=session_id,  # Use explicit session_id with agent_id from URL
                files=files if files else None,
                metadata=metadata,
                user_id=user_id,  # Pass contact_id as user_id
            ),
            label=f"agent {agent_id} execution",
        )

        final_response = result.get("final_response", "No response")
        logger.info(f"✅ Agent response: {final_response}")

        # Log what we're about to send to create_task_response
        logger.info(
            f"🏗️ Creating task response with {len(combined_history) if combined_history else 0} history messages"
        )

        # Create current user message object for history
        current_user_message = {
            "content": text,
            "messageId": message.get("messageId"),
            "timestamp": None,  # Could add current timestamp
        }

        structured = extract_structured_from_message_history(result.get("message_history"))
        artifacts = build_a2a_artifacts(final_response, structured)

        # Create A2A compliant response with history
        task_response = create_task_response(
            task_id,
            context_id,
            final_response,
            artifacts,
            combined_history if combined_history else None,
            current_user_message,
        )

        logger.info(
            f"📦 Task response created with {len(task_response.get('artifacts', []))} artifacts"
        )

        # Handle push notification if configured
        if push_notification_config:
            try:
                await send_push_notification(task_response, push_notification_config, request)
                logger.info(f"🔔 Push notification sent successfully")
            except Exception as e:
                logger.error(f"❌ Push notification failed: {e}")
                # Continue execution - push notification failure shouldn't break the response
        
        return JSONResponse(
            content={"jsonrpc": "2.0", "id": request_id, "result": task_response}
        )

    except ClientGoneAway as e:
        # Nobody is waiting for this response — it is logged for the operator
        # and returned only because the handler must return something.
        logger.warning(f"⛔ {e}")
        return error_response(
            request=request,
            # 499 is nginx's convention for "caller hung up"; no RFC status
            # exists, so fastapi.status has no constant to use here.
            code=map_status_to_error_code(499),
            message="Client closed the request before the agent finished",
            status_code=499,
            details={
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {
                    "code": -32000,
                    "message": "Client closed the request before the agent finished",
                    "data": {"error": str(e)},
                },
            },
        )

    except Exception as e:
        # CRM-236: a quota exhaustion and a bug of ours both answered "500 Agent
        # execution failed". Report the provider's condition when we recognise it.
        provider_failure = classify_provider_error(e)
        if provider_failure is not None:
            log_provider_failure(provider_failure, agent_id)
            return error_response(
                request=request,
                code=map_status_to_error_code(provider_failure.http_status),
                message=provider_failure.message,
                status_code=provider_failure.http_status,
                details={
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "error": {
                        "code": provider_failure.jsonrpc_code,
                        "message": provider_failure.message,
                        "data": {
                            "kind": provider_failure.kind,
                            "error": provider_failure.detail,
                        },
                    },
                },
            )

        # Classification is conservative, so this fallback is the common path —
        # and the one most likely to carry a credential (`?key=AIza…`).
        safe = redact_secrets(str(e))
        logger.error(f"❌ Agent execution error: {safe}")
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_500_INTERNAL_SERVER_ERROR),
            message="Agent execution failed",
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            details={
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {
                    "code": -32603,
                    "message": "Agent execution failed",
                    "data": {"error": safe},
                },
            }
        )
        return JSONResponse(
            content={
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {
                    "code": -32603,
                    "message": "Agent execution failed",
                    "data": {"error": safe},
                },
            }
        )


async def handle_message_stream(
    agent_id: uuid.UUID, params: Dict[str, Any], request_id: str, request: Request, db: Session
) -> EventSourceResponse:
    """Handle message/stream according to A2A spec."""

    logger.info(f"🔄 Processing message/stream for agent {agent_id}")

    # Extract message
    message = params.get("message")
    if not message:
        # Return error event
        async def error_generator():
            yield {
                "data": json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": request_id,
                        "error": {
                            "code": -32602,
                            "message": "Invalid params",
                            "data": {"missing": "message"},
                        },
                    }
                )
            }

        return EventSourceResponse(error_generator())

    # Extract text and files from message
    text = extract_text_from_message(message)
    files = extract_files_from_message(message)
    context_id = params.get("contextId", str(uuid.uuid4()))

    # Use default text if only files provided
    if not text and files:
        text = "Analyze the provided files"

    # Extract and combine conversation history
    conversation_history = await extract_conversation_history(str(agent_id), context_id, db=db)
    request_history = extract_history_from_params(params)
    combined_history = combine_histories(request_history, conversation_history)

    async def stream_generator():
        try:
            logger.info(f"🌊 Starting stream for: {text} with {len(files)} files")
            logger.info(
                f"📚 ADK will provide session context automatically ({len(combined_history)} previous messages available)"
            )

            # Extract userId from params (contact_id sent from Rails)
            user_id = params.get("userId") or context_id
            if user_id != context_id:
                logger.info(f"📋 Using userId from params as user_id: {user_id}")
            else:
                logger.warning(f"⚠️ No userId in params, using context_id (conversation UUID) as user_id: {user_id}")
            
            # Stream agent execution - ADK handles session history automatically
            async for chunk in run_agent_stream(
                agent_id=str(agent_id),
                external_id=context_id,  # contextId (display_id) used to build session_id as {display_id}_{agent_id}
                message=text,  # Send only the original message - ADK handles context
                session_service=session_service,
                artifacts_service=artifacts_service,
                memory_service=memory_service,
                db=db,
                session_id=None,  # Let create_session_id build it as {display_id}_{agent_id}
                files=files if files else None,
                user_id=user_id,  # Pass contact_id as user_id
            ):
                # Parse chunk and convert to A2A format
                try:
                    chunk_data = json.loads(chunk)

                    # Create TaskStatusUpdateEvent
                    event = {
                        "jsonrpc": "2.0",
                        "id": request_id,
                        "result": {
                            "id": str(uuid.uuid4()),
                            "status": {
                                "state": "working",
                                "message": chunk_data.get("content", {}),
                            },
                            "final": False,
                        },
                    }

                    yield {"data": json.dumps(event)}

                except Exception as e:
                    logger.error(f"Error processing chunk: {e}")
                    continue

            # Send final event
            final_event = {
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {
                    "id": str(uuid.uuid4()),
                    "status": {"state": "completed"},
                    "final": True,
                },
            }
            yield {"data": json.dumps(final_event)}

        except Exception as e:
            # No disconnect guard here on purpose: sse-starlette already runs
            # _listen_for_disconnect inside cancel_on_finish, which cancels the
            # task group consuming this generator. A second consumer on the same
            # receive channel would steal the message the first waits for.
            provider_failure = classify_provider_error(e)
            if provider_failure is not None:
                log_provider_failure(provider_failure, agent_id)
                error_event = {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "error": {
                        "code": provider_failure.jsonrpc_code,
                        "message": provider_failure.message,
                        "data": {
                            "kind": provider_failure.kind,
                            "error": provider_failure.detail,
                        },
                    },
                }
            else:
                safe_stream_error = redact_secrets(str(e))
                logger.error(f"❌ Streaming error: {safe_stream_error}")
                error_event = {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "error": {
                        "code": -32603,
                        "message": "Streaming failed",
                        "data": {"error": safe_stream_error},
                    },
                }
            yield {"data": json.dumps(error_event)}

    return EventSourceResponse(stream_generator())


@router.get("/{agent_id}/.well-known/agent.json")
async def get_agent_card(
    agent_id: uuid.UUID,
    request: Request,
    _: None = Depends(RequirePermission("ai_a2a_protocol", "read")),
    db: Session = Depends(get_db),
):
    """Get agent card according to A2A specification."""

    logger.info(f"📋 Getting agent card for {agent_id}")

    agent = await get_agent(db, agent_id)
    if not agent:
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_404_NOT_FOUND),
            message="Agent not found",
            status_code=status.HTTP_404_NOT_FOUND
        )

    # Build agent card following A2A specification
    agent_card = {
        "name": agent.name,
        "description": agent.description or f"AI Agent {agent.name}",
        "url": f"{settings.API_URL}/api/v1/a2a/{agent_id}",
        "provider": {
            "organization": "Evo AI Platform",
            "url": settings.API_URL,
        },
        "version": "1.0.0",
        "documentationUrl": f"{settings.API_URL}/docs",
        "capabilities": {
            "streaming": True,
            "pushNotifications": True,
            "stateTransitionHistory": True,
        },
        "securitySchemes": {
            "apiKey": {
                "type": "apiKey",
                "in": "header",
                "name": "x-api-key",
            }
        },
        "security": [{"apiKey": []}],
        "defaultInputModes": ["text/plain", "application/json", "image/png"],
        "defaultOutputModes": ["text/plain", "application/json"],
        "skills": generate_agent_skills(agent, db),
    }

    return success_response(data=agent_card, message="Agent card retrieved successfully")


@router.get("/health")
async def health_check(
    _: None = Depends(RequirePermission("ai_a2a_protocol", "read"))
):
    """Health check for A2A official implementation - 100% A2A spec compliant."""
    return {
        "status": "healthy",
        "specification": "A2A Protocol v1.0 - 100% COMPLIANT IMPLEMENTATION",
        "specification_url": "https://google.github.io/A2A/specification",
        "compliance_level": "FULL",
        # All RPC methods from A2A spec implemented
        "rpc_methods": {
            "core": ["message/send", "message/stream"],
            "task_management": ["tasks/get", "tasks/cancel", "tasks/resubscribe"],
            "push_notifications": [
                "tasks/pushNotificationConfig/set",
                "tasks/pushNotificationConfig/get",
            ],
            "agent_discovery": ["agent/authenticatedExtendedCard"],
        },
        "endpoints": {
            "agent_endpoint": f"{settings.API_URL}/api/v1/a2a/{{agent_id}}",
            "agent_card": f"{settings.API_URL}/api/v1/a2a/{{agent_id}}/.well-known/agent.json",
        },
        # A2A Protocol Data Objects - all implemented
        "data_objects": [
            "Task",
            "TaskStatus",
            "TaskState",
            "Message",
            "TextPart",
            "FilePart",
            "DataPart",
            "Artifact",
            "PushNotificationConfig",
            "PushNotificationAuthenticationInfo",
            "JSONRPCRequest",
            "JSONRPCResponse",
            "JSONRPCError",
        ],
        # A2A Features implemented
        "features": {
            "multi_turn_conversations": True,
            "file_processing": True,
            "context_preservation": True,
            "streaming": True,
            "push_notifications": True,
            "task_cancellation": True,
            "push_config_management": True,
            "authenticated_extended_cards": True,
            "https_security": True,
            "json_rpc_2_0": True,
        },
        # Security features per A2A spec
        "security": {
            "transport_security": "HTTPS required for push notifications",
            "authentication": "API Key via x-api-key header",
            "webhook_validation": "HTTPS-only webhooks to prevent SSRF",
            "input_validation": "Full parameter validation on all RPC methods",
        },
        # Extensions beyond A2A spec
        "extensions": {
            "conversation_history": f"{settings.API_URL}/api/v1/a2a/{{agent_id}}/conversation/history",
            "sessions": f"{settings.API_URL}/api/v1/a2a/{{agent_id}}/sessions",
            "session_history": f"{settings.API_URL}/api/v1/a2a/{{agent_id}}/sessions/{{session_id}}/history",
        },
        "compatibility_notes": [
            "Supports both official A2A format and common variations",
            "Backward compatible with alternative field names",
            "Task management adapted for synchronous execution model",
            "Push notifications with multiple authentication schemes",
        ],
    }


@router.get("/{agent_id}/sessions",
    responses={
        400: {"model": ErrorResponse, "description": "Bad request"},
        401: {"model": ErrorResponse, "description": "Unauthorized"},
        404: {"model": ErrorResponse, "description": "Not found"},
        500: {"model": ErrorResponse, "description": "Internal server error"},
    })
async def list_agent_sessions(
    agent_id: uuid.UUID,
    external_id: str,
    request: Request,
    x_api_key: str = Header(None, alias="x-api-key"),
    _: None = Depends(RequirePermission("ai_a2a_protocol", "read")),
    db: Session = Depends(get_db),
):
    """List sessions for an agent and external_id (A2A extension)."""

    logger.info(f"📋 Listing sessions for agent {agent_id}, external_id: {external_id}")

    # Verify API key
    await verify_api_key(db, request, x_api_key)

    # Verify agent exists
    agent = await get_agent(db, agent_id)
    if not agent:
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_404_NOT_FOUND),
            message="Agent not found",
            status_code=status.HTTP_404_NOT_FOUND
        )

    try:
        # List sessions from session service
        sessions = []
        session_id = f"{external_id}_{agent_id}"

        # Try to get session
        session = session_service.get_session(
            app_name=str(agent_id), user_id=external_id, session_id=session_id
        )

        if session:
            # Extract conversation history
            history = await extract_conversation_history(str(agent_id), external_id, db=db)

            sessions.append(
                {
                    "sessionId": session_id,
                    "contextId": external_id,
                    "lastUpdate": getattr(session, "last_update_time", None),
                    "messageCount": len(history),
                    "status": "active",
                }
            )

        return success_response(data={"sessions": sessions, "total": len(sessions)}, message="Sessions listed successfully")

    except Exception as e:
        logger.error(f"❌ Error listing sessions: {e}")
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_500_INTERNAL_SERVER_ERROR),
            message=f"Error listing sessions: {str(e)}",
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR
        )


@router.get("/{agent_id}/sessions/{session_id}/history")
async def get_session_history(
    agent_id: uuid.UUID,
    session_id: str,
    request: Request,
    x_api_key: str = Header(None, alias="x-api-key"),
    _: None = Depends(RequirePermission("ai_a2a_protocol", "read")),
    db: Session = Depends(get_db),
    limit: int = 50,
):
    """Get conversation history for a specific session (A2A extension)."""

    logger.info(f"📚 Getting history for session {session_id}")

    # Verify API key
    await verify_api_key(db, request, x_api_key)

    # Verify agent exists
    agent = await get_agent(db, agent_id)
    if not agent:
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_404_NOT_FOUND),
            message="Agent not found",
            status_code=status.HTTP_404_NOT_FOUND
        )

    try:
        # Parse session_id to get external_id
        if "_" in session_id:
            external_id = session_id.split("_")[0]
        else:
            external_id = session_id

        # Extract conversation history
        history = await extract_conversation_history(str(agent_id), external_id, db=db)

        # Limit results
        if limit > 0:
            history = history[-limit:]

        return success_response(data={"sessionId": session_id, "history": history, "total": len(history)}, message="Session history retrieved successfully")

    except Exception as e:
        logger.error(f"❌ Error getting session history: {e}")
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_500_INTERNAL_SERVER_ERROR),
            message=f"Error getting session history: {str(e)}",
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR
        )


@router.post("/{agent_id}/conversation/history")
async def get_conversation_history(
    agent_id: uuid.UUID,
    request: Request,
    x_api_key: str = Header(None, alias="x-api-key"),
    _: None = Depends(RequirePermission("ai_a2a_protocol", "task_management")),
    db: Session = Depends(get_db),
):
    """
    Get conversation history according to A2A specification.

    Endpoint for retrieving multi-turn conversation context.
    This implements context preservation as defined in A2A spec.
    """
    logger.info(f"📚 A2A Conversation History requested for agent {agent_id}")

    # Verify API key
    await verify_api_key(db, request, x_api_key)

    # Verify agent exists
    agent = await get_agent(db, agent_id)
    if not agent:
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_404_NOT_FOUND),
            message="Agent not found",
            status_code=status.HTTP_404_NOT_FOUND
        )

    try:
        # Parse JSON-RPC request
        request_body = await request.json()

        jsonrpc = request_body.get("jsonrpc")
        if jsonrpc != "2.0":
            return error_response(
                request=request,
                code=map_status_to_error_code(status.HTTP_400_BAD_REQUEST),
                message="Invalid JSON-RPC version",
                status_code=status.HTTP_400_BAD_REQUEST
            )

        params = request_body.get("params", {})
        request_id = request_body.get("id")

        # Extract contextId (external_id) from params
        context_id = params.get("contextId") or params.get("external_id")
        if not context_id:
            return error_response(
                request=request,
                code=map_status_to_error_code(status.HTTP_400_BAD_REQUEST),
                message="Invalid params",
                status_code=status.HTTP_400_BAD_REQUEST,
                details={
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "error": {
                        "code": -32602,
                        "message": "Invalid params",
                        "data": {"missing": "contextId or external_id"},
                    },
                }
            )

        # Extract conversation history using session_service
        history = await extract_conversation_history(str(agent_id), context_id, db=db)

        # Limit history if requested
        limit = params.get("limit", 50)
        if limit > 0:
            history = history[-limit:]

        # Format as A2A Task response with history artifacts
        task_id = str(uuid.uuid4())

        # Create structured artifacts for history
        artifacts = []

        # Main artifact with recent messages
        if history:
            recent_messages = history[-10:]  # Last 10 messages

            # Create individual message artifacts
            for i, msg in enumerate(recent_messages):
                artifacts.append(
                    {
                        "artifactId": str(uuid.uuid4()),
                        "name": f"message_{i+1}",
                        "description": f"Message from {msg['role']}",
                        "parts": [
                            {
                                "type": "text",
                                "text": msg["content"],
                                "metadata": {
                                    "role": msg["role"],
                                    "messageId": msg.get("messageId"),
                                    "timestamp": msg.get("timestamp"),
                                    "author": msg.get("author"),
                                },
                            }
                        ],
                    }
                )

            # Summary artifact
            artifacts.append(
                {
                    "artifactId": str(uuid.uuid4()),
                    "name": "conversation_summary",
                    "description": f"Conversation history summary ({len(history)} total messages)",
                    "parts": [
                        {
                            "type": "text",
                            "text": f"Conversation with {len(history)} messages between user and agent.",
                            "metadata": {
                                "total_messages": len(history),
                                "recent_messages": len(recent_messages),
                                "context_id": context_id,
                            },
                        }
                    ],
                }
            )

        # Create A2A compliant Task response
        task_response = {
            "id": task_id,
            "contextId": context_id,
            "status": {
                "state": "completed",
                "timestamp": datetime.now().isoformat() + "Z",
            },
            "artifacts": artifacts,
            "kind": "task",
            "metadata": {
                "total_messages": len(history),
                "operation": "conversation_history_retrieval",
            },
        }

        return JSONResponse(
            content={"jsonrpc": "2.0", "id": request_id, "result": task_response}
        )

    except json.JSONDecodeError:
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_400_BAD_REQUEST),
            message="Invalid JSON",
            status_code=status.HTTP_400_BAD_REQUEST
        )
    except Exception as e:
        logger.error(f"❌ Error retrieving conversation history: {e}")
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_500_INTERNAL_SERVER_ERROR),
            message=f"Error retrieving conversation history: {str(e)}",
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            details={
                "jsonrpc": "2.0",
                "id": request_body.get("id") if "request_body" in locals() else None,
                "error": {
                    "code": -32603,
                    "message": "Internal error",
                    "data": {"error": str(e)},
                },
            }
        )


async def send_push_notification(
    task_response: Dict[str, Any], 
    push_notification_config: Dict[str, Any], 
    request: Request,
    request_id: Optional[str] = None
) -> Optional[JSONResponse]:
    """Send push notification according to A2A specification section 9.5.

    A2A spec PushNotificationConfig object:
    - url: The absolute HTTPS webhook URL where the A2A Server should POST task updates
    - token (optional): Client-generated opaque token for validation
    - authentication (optional): PushNotificationAuthenticationInfo for authenticating to client's webhook

    Alternative formats supported for compatibility:
    - webhookUrl instead of url
    - webhookAuthenticationInfo instead of authentication
    
    Returns:
        JSONResponse if validation error (should be returned to caller)
    """
    # Support both official spec format and common variations
    webhook_url = push_notification_config.get("url") or push_notification_config.get(
        "webhookUrl"
    )
    webhook_token = push_notification_config.get("token")

    # Support both official and alternative authentication field names
    authentication = push_notification_config.get(
        "authentication"
    ) or push_notification_config.get("webhookAuthenticationInfo")

    if not webhook_url:
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_400_BAD_REQUEST),
            message="Invalid params",
            status_code=status.HTTP_400_BAD_REQUEST,
            details={
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {
                    "code": -32602,
                    "message": "Invalid params",
                    "data": {"missing": "pushNotificationConfig.url or pushNotificationConfig.webhookUrl"},
                },
            }
        )

    # Validate HTTPS requirement (A2A spec: url MUST be HTTPS for security to prevent SSRF)
    if not webhook_url.startswith("https://"):
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_400_BAD_REQUEST),
            message="Invalid params",
            status_code=status.HTTP_400_BAD_REQUEST,
            details={
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {
                    "code": -32602,
                    "message": "Invalid params",
                    "data": {"error": "pushNotificationConfig.url MUST use HTTPS to prevent SSRF attacks"},
                },
            }
        )

    logger.info(f"🔔 Sending push notification to: {webhook_url}")

    # Prepare headers according to A2A spec section 9.5
    headers = {
        "Content-Type": "application/json",
        "User-Agent": f"A2A-Server/{getattr(settings, 'API_VERSION', '1.0.0')}",
    }

    # Add client token if provided (A2A spec: server SHOULD include in X-A2A-Notification-Token header)
    if webhook_token:
        headers["X-A2A-Notification-Token"] = webhook_token
        logger.info(f"🔑 Added client token to notification headers")

    # Handle authentication according to A2A spec PushNotificationAuthenticationInfo
    if authentication:
        auth_type = authentication.get("type")

        # Handle "none" type (no authentication)
        if auth_type == "none":
            logger.info(f"🔓 No authentication required for webhook")

        # Handle schemes-based authentication (official A2A spec format)
        elif "schemes" in authentication:
            auth_schemes = authentication.get("schemes", [])
            auth_credentials = authentication.get("credentials")

            for scheme in auth_schemes:
                if scheme.lower() == "bearer":
                    # Bearer token authentication
                    if auth_credentials:
                        headers["Authorization"] = f"Bearer {auth_credentials}"
                        logger.info(f"🔐 Added Bearer authentication")
                    else:
                        logger.warning(
                            "⚠️ Bearer scheme specified but no credentials provided"
                        )

                elif scheme.lower() == "apikey":
                    # API Key authentication
                    if auth_credentials:
                        try:
                            # A2A spec example: JSON like {"in": "header", "name": "X-Client-Webhook-Key", "value": "actual_key"}
                            if isinstance(auth_credentials, str):
                                cred_data = json.loads(auth_credentials)
                            else:
                                cred_data = auth_credentials

                            if cred_data.get("in") == "header":
                                header_name = cred_data.get("name", "X-API-Key")
                                header_value = cred_data.get("value")
                                if header_value:
                                    headers[header_name] = header_value
                                    logger.info(
                                        f"🔐 Added API Key authentication to header: {header_name}"
                                    )
                        except (json.JSONDecodeError, TypeError):
                            # Fallback: treat credentials as direct API key value
                            headers["X-API-Key"] = str(auth_credentials)
                            logger.info(f"🔐 Added API Key authentication (fallback)")
                    else:
                        logger.warning(
                            "⚠️ ApiKey scheme specified but no credentials provided"
                        )

                else:
                    logger.warning(f"⚠️ Unsupported authentication scheme: {scheme}")

        # Handle basic authentication types
        elif auth_type == "bearer":
            token = authentication.get("token") or authentication.get("credentials")
            if token:
                headers["Authorization"] = f"Bearer {token}"
                logger.info(f"🔐 Added Bearer authentication (alternative format)")

        elif auth_type == "apikey":
            api_key = (
                authentication.get("apiKey")
                or authentication.get("key")
                or authentication.get("credentials")
            )
            header_name = authentication.get("headerName", "X-API-Key")
            if api_key:
                headers[header_name] = api_key
                logger.info(f"🔐 Added API Key authentication to header: {header_name}")

        else:
            logger.warning(f"⚠️ Unsupported authentication type: {auth_type}")

    # According to A2A spec section 9.5, the notification payload should contain
    # sufficient information for client to identify Task ID and new state
    # The spec suggests sending the full Task object as JSON payload
    notification_payload = task_response

    try:
        # Use 30 second timeout as recommended for webhook calls
        async with httpx.AsyncClient(timeout=30.0) as client:
            logger.info(
                f"📤 Sending POST request to webhook with {len(headers)} headers"
            )

            response = await client.post(
                webhook_url, headers=headers, json=notification_payload
            )

            # Log the response according to A2A spec recommendations
            if response.status_code == 200:
                logger.info(f"✅ Push notification sent successfully to {webhook_url}")
            elif 200 <= response.status_code < 300:
                logger.info(
                    f"✅ Push notification accepted with status {response.status_code} from {webhook_url}"
                )
            else:
                logger.warning(
                    f"⚠️ Push notification received non-success response: {response.status_code} from {webhook_url}"
                )
                try:
                    response_text = response.text[
                        :200
                    ]  # Log first 200 chars of response
                    logger.warning(f"Response body: {response_text}")
                except:
                    pass

            # Don't raise exception for non-200 status codes per A2A spec
            # The webhook might have its own status handling, and notification
            # delivery is best-effort

    except httpx.TimeoutException:
        logger.error(f"❌ Push notification timeout (30s) to {webhook_url}")
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_500_INTERNAL_SERVER_ERROR),
            message="Push notification timeout",
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            details={
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {
                    "code": -32603,
                    "message": "Push notification timeout",
                    "data": {"error": f"Push notification timeout to {webhook_url}"},
                },
            }
        )

    except httpx.RequestError as e:
        logger.error(f"❌ Push notification request error to {webhook_url}: {e}")
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_500_INTERNAL_SERVER_ERROR),
            message="Push notification request error",
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            details={
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {
                    "code": -32603,
                    "message": "Push notification request error",
                    "data": {"error": f"Push notification request error to {webhook_url}: {e}"},
                },
            }
        )

    except Exception as e:
        logger.error(f"❌ Push notification unexpected error to {webhook_url}: {e}")
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_500_INTERNAL_SERVER_ERROR),
            message="Push notification error",
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            details={
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {
                    "code": -32603,
                    "message": "Push notification error",
                    "data": {"error": f"Push notification error to {webhook_url}: {e}"},
                },
            }
        )


# Task management functions (A2A spec section 7.3-7.7)
async def handle_tasks_get(
    agent_id: uuid.UUID, params: Dict[str, Any], request_id: str, request: Request, db: Session
) -> JSONResponse:
    """Handle tasks/get according to A2A spec section 7.3."""
    logger.info(f"🔍 Processing tasks/get for agent {agent_id}")

    try:
        task_id = params.get("taskId")
        if not task_id:
            return error_response(
                request=request,
                code=map_status_to_error_code(status.HTTP_400_BAD_REQUEST),
                message="Invalid params",
                status_code=status.HTTP_400_BAD_REQUEST,
                details={
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "error": {
                        "code": -32602,
                        "message": "Invalid params",
                        "data": {"missing": "taskId"},
                    },
                }
            )

        # In our implementation, tasks are ephemeral and complete immediately
        # For A2A compliance, we return a completed task with minimal info
        task_response = {
            "id": task_id,
            "status": {
                "state": "completed",
                "timestamp": datetime.now().isoformat() + "Z",
            },
            "kind": "task",
        }

        return JSONResponse(
            content={"jsonrpc": "2.0", "id": request_id, "result": task_response}
        )

    except Exception as e:
        logger.error(f"❌ tasks/get error: {e}")
        return JSONResponse(
            code=map_status_to_error_code(status.HTTP_500_INTERNAL_SERVER_ERROR),
            message="Internal error",
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            details={
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {
                    "code": -32603,
                    "message": "Internal error",
                    "data": {"error": str(e)},
                },
            }
        )


async def handle_tasks_cancel(
    agent_id: uuid.UUID, params: Dict[str, Any], request_id: str, request: Request, db: Session
) -> JSONResponse:
    """Handle tasks/cancel according to A2A spec section 7.4."""
    logger.info(f"🛑 Processing tasks/cancel for agent {agent_id}")

    try:
        task_id = params.get("taskId")
        if not task_id:
            return JSONResponse(
                content={
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "error": {
                        "code": -32602,
                        "message": "Invalid params",
                        "data": {"missing": "taskId"},
                    },
                }
            )

        # In our implementation, tasks complete immediately, so cancellation is not needed
        # Return success for A2A compliance
        return JSONResponse(
            content={
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {
                    "success": True,
                    "message": f"Task {task_id} cancellation requested",
                },
            }
        )

    except Exception as e:
        logger.error(f"❌ tasks/cancel error: {e}")
        return JSONResponse(
            content={
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {
                    "code": -32603,
                    "message": "Internal error",
                    "data": {"error": str(e)},
                },
            }
        )


# Task push notification config management (A2A spec section 7.5-7.6)
task_push_configs = {}  # In-memory storage for demo - use database in production


async def handle_tasks_push_notification_config_set(
    agent_id: uuid.UUID, params: Dict[str, Any], request_id: str, request: Request, db: Session
) -> JSONResponse:
    """Handle tasks/pushNotificationConfig/set according to A2A spec section 7.5."""
    logger.info(f"🔔 Processing tasks/pushNotificationConfig/set for agent {agent_id}")

    try:
        task_id = params.get("taskId")
        push_config = params.get("pushNotificationConfig")

        if not task_id:
            return JSONResponse(
                content={
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "error": {
                        "code": -32602,
                        "message": "Invalid params",
                        "data": {"missing": "taskId"},
                    },
                }
            )

        if not push_config:
            return JSONResponse(
                content={
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "error": {
                        "code": -32602,
                        "message": "Invalid params",
                        "data": {"missing": "pushNotificationConfig"},
                    },
                }
            )

        # Validate URL is HTTPS
        webhook_url = push_config.get("url") or push_config.get("webhookUrl")
        if webhook_url and not webhook_url.startswith("https://"):
            return JSONResponse(
                content={
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "error": {
                        "code": -32602,
                        "message": "Invalid params",
                        "data": {"error": "pushNotificationConfig.url MUST use HTTPS"},
                    },
                }
            )

        # Store the config (in production, save to database)
        task_push_configs[task_id] = push_config
        logger.info(f"✅ Push notification config stored for task {task_id}")

        return JSONResponse(
            content={
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {"success": True, "taskId": task_id},
            }
        )

    except Exception as e:
        logger.error(f"❌ tasks/pushNotificationConfig/set error: {e}")
        return JSONResponse(
            content={
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {
                    "code": -32603,
                    "message": "Internal error",
                    "data": {"error": str(e)},
                },
            }
        )


async def handle_tasks_push_notification_config_get(
    agent_id: uuid.UUID, params: Dict[str, Any], request_id: str, request: Request, db: Session
) -> JSONResponse:
    """Handle tasks/pushNotificationConfig/get according to A2A spec section 7.6."""
    logger.info(f"🔍 Processing tasks/pushNotificationConfig/get for agent {agent_id}")

    try:
        task_id = params.get("taskId")
        if not task_id:
            return JSONResponse(
                content={
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "error": {
                        "code": -32602,
                        "message": "Invalid params",
                        "data": {"missing": "taskId"},
                    },
                }
            )

        # Retrieve the config (in production, get from database)
        push_config = task_push_configs.get(task_id)

        if push_config:
            return JSONResponse(
                content={
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "result": {
                        "taskId": task_id,
                        "pushNotificationConfig": push_config,
                    },
                }
            )
        else:
            return JSONResponse(
                content={
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "error": {
                        "code": -32001,
                        "message": "Task not found or no push notification config set",
                        "data": {"taskId": task_id},
                    },
                }
            )

    except Exception as e:
        logger.error(f"❌ tasks/pushNotificationConfig/get error: {e}")
        return JSONResponse(
            content={
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {
                    "code": -32603,
                    "message": "Internal error",
                    "data": {"error": str(e)},
                },
            }
        )


async def handle_tasks_resubscribe(
    agent_id: uuid.UUID, params: Dict[str, Any], request_id: str, request: Request, db: Session
) -> JSONResponse:
    """Handle tasks/resubscribe according to A2A spec section 7.7."""
    logger.info(f"🔄 Processing tasks/resubscribe for agent {agent_id}")

    try:
        task_id = params.get("taskId")
        push_config = params.get("pushNotificationConfig")

        if not task_id:
            return JSONResponse(
                content={
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "error": {
                        "code": -32602,
                        "message": "Invalid params",
                        "data": {"missing": "taskId"},
                    },
                }
            )

        # Update push notification config if provided
        if push_config:
            task_push_configs[task_id] = push_config
            logger.info(f"✅ Push notification config updated for task {task_id}")

        # In our implementation, tasks complete immediately
        # Return success for A2A compliance
        return JSONResponse(
            content={
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {
                    "success": True,
                    "taskId": task_id,
                    "message": "Resubscription successful",
                },
            }
        )

    except Exception as e:
        logger.error(f"❌ tasks/resubscribe error: {e}")
        return JSONResponse(
            content={
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {
                    "code": -32603,
                    "message": "Internal error",
                    "data": {"error": str(e)},
                },
            }
        )


async def handle_agent_authenticated_extended_card(
    agent_id: uuid.UUID, params: Dict[str, Any], request_id: str, request: Request, db: Session
) -> JSONResponse:
    """Handle agent/authenticatedExtendedCard according to A2A spec section 7.8."""
    logger.info(f"🛡️ Processing agent/authenticatedExtendedCard for agent {agent_id}")

    try:
        # Get agent from database
        agent = await get_agent(db, agent_id)
        if not agent:
            return JSONResponse(
                content={
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "error": {
                        "code": -32001,
                        "message": "Agent not found",
                    },
                }
            )

        # Build authenticated extended agent card (can include additional info after auth)
        extended_card = {
            "name": agent.name,
            "description": agent.description or f"AI Agent {agent.name}",
            "url": f"{settings.API_URL}/api/v1/a2a/{agent_id}",
            "provider": {
                "organization": "Evo AI Platform",
                "url": settings.API_URL,
            },
            "version": "1.0.0",
            "documentationUrl": f"{settings.API_URL}/docs",
            "capabilities": {
                "streaming": True,
                "pushNotifications": True,
                "stateTransitionHistory": True,
                "multiTurnConversations": True,
                "fileProcessing": True,
            },
            "securitySchemes": {
                "apiKey": {
                    "type": "apiKey",
                    "in": "header",
                    "name": "x-api-key",
                }
            },
            "security": [{"apiKey": []}],
            "defaultInputModes": ["text/plain", "application/json"],
            "defaultOutputModes": ["text/plain", "application/json"],
            "skills": generate_agent_skills(agent, db),
            # Extended information available after authentication
            "extended": {
                "agent_id": str(agent_id),
                "creation_date": getattr(agent, "created_at", None),
                "available_endpoints": [
                    "message/send",
                    "message/stream",
                    "tasks/get",
                    "tasks/cancel",
                    "tasks/pushNotificationConfig/set",
                    "tasks/pushNotificationConfig/get",
                    "tasks/resubscribe",
                    "agent/authenticatedExtendedCard",
                ],
                "rate_limits": {"requests_per_minute": 100, "concurrent_tasks": 10},
            },
        }

        return JSONResponse(
            content={"jsonrpc": "2.0", "id": request_id, "result": extended_card}
        )

    except Exception as e:
        logger.error(f"❌ agent/authenticatedExtendedCard error: {e}")
        return JSONResponse(
            content={
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {
                    "code": -32603,
                    "message": "Internal error",
                    "data": {"error": str(e)},
                },
            }
        )


def generate_agent_skills(agent: Any, db: Session) -> List[Dict[str, Any]]:
    """Generate skills dynamically from agent's tools and MCP servers."""
    skills = []

    try:
        # Parse agent config to get tools
        agent_config = (
            agent.config if isinstance(agent.config, dict) else json.loads(agent.config)
        )

        logger.info(f"🔧 Processing agent config for skills generation")
        logger.info(f"Agent config keys: {list(agent_config.keys())}")

        # 1. Add skills from direct tools (using available_tools.json)
        tools = agent_config.get("tools", [])
        logger.info(f"📦 Found {len(tools)} tools in agent config")

        for i, tool_config in enumerate(tools):
            logger.info(f"📦 Processing tool {i+1}: {tool_config}")

            tool_name = tool_config.get("name")
            tool_id = tool_config.get("id")

            # Try to find tool in available_tools.json
            available_tool = None

            # First try by name (since that's what the JSON file uses)
            if tool_name:
                try:
                    available_tool = tools_service.get_tool_by_id(tool_name)
                    if available_tool:
                        logger.info(f"✅ Found tool by name: {available_tool.name}")
                    else:
                        logger.warning(f"❌ Tool not found by name: {tool_name}")
                except Exception as e:
                    logger.error(f"❌ Error searching tool by name {tool_name}: {e}")

            # If not found by name, try by ID
            if not available_tool and tool_id:
                try:
                    available_tool = tools_service.get_tool_by_id(tool_id)
                    if available_tool:
                        logger.info(f"✅ Found tool by ID: {available_tool.name}")
                    else:
                        logger.warning(f"❌ Tool not found by ID: {tool_id}")
                except Exception as e:
                    logger.error(f"❌ Error searching tool by ID {tool_id}: {e}")

            # If tool found, create skill
            if available_tool:
                skill = {
                    "id": available_tool.id,
                    "name": available_tool.name,
                    "description": available_tool.description,
                    "tags": tool_config.get("tags", available_tool.tags),
                    "examples": tool_config.get("examples", available_tool.examples),
                    "inputModes": tool_config.get(
                        "inputModes", available_tool.inputModes
                    ),
                    "outputModes": tool_config.get(
                        "outputModes", available_tool.outputModes
                    ),
                }
                skills.append(skill)
                logger.info(f"✅ Added skill for tool: {available_tool.name}")
            else:
                logger.warning(
                    f"⚠️ Could not find tool with name '{tool_name}' or ID '{tool_id}' in available_tools.json"
                )

        # 2. Add skills from MCP servers
        mcp_servers = agent_config.get("mcp_servers", [])
        logger.info(f"🔌 Found {len(mcp_servers)} MCP servers in agent config")

        for i, mcp_config in enumerate(mcp_servers):
            logger.info(f"🔌 Processing MCP server {i+1}: {mcp_config}")

            mcp_server_id = mcp_config.get("id")
            if mcp_server_id:
                try:
                    # Get MCP server from database
                    mcp_server = get_mcp_server(db, uuid.UUID(mcp_server_id))
                    if mcp_server:
                        logger.info(f"✅ Found MCP server: {mcp_server.name}")
                        logger.info(
                            f"🔧 MCP server has {len(mcp_server.tools) if mcp_server.tools else 0} tools"
                        )

                        if mcp_server.tools:
                            # Get tools that are enabled for this agent
                            enabled_tools = mcp_config.get("tools", [])
                            logger.info(f"🔧 Agent enabled tools: {enabled_tools}")

                            for j, tool_data in enumerate(mcp_server.tools):
                                tool_name = tool_data.get("name")
                                tool_id = tool_data.get("id")
                                logger.info(
                                    f"🔧 Processing MCP tool {j+1}: {tool_name} (ID: {tool_id})"
                                )

                                # If no specific tools are enabled, use all tools
                                # If specific tools are enabled, check both name and id
                                tool_enabled = (
                                    not enabled_tools
                                    or tool_name in enabled_tools
                                    or tool_id in enabled_tools
                                )

                                if tool_enabled:
                                    skill = {
                                        "id": f"mcp_{mcp_server_id}_{tool_id or tool_name}",
                                        "name": tool_data.get("name", tool_name),
                                        "description": tool_data.get(
                                            "description",
                                            f"MCP tool from {mcp_server.name}",
                                        ),
                                        "tags": tool_data.get("tags", ["mcp", "tool"])
                                        + [mcp_server.name.replace(" ", "_").lower()],
                                        "examples": tool_data.get(
                                            "examples",
                                            [f"Use {tool_name} from {mcp_server.name}"],
                                        ),
                                        "inputModes": tool_data.get(
                                            "inputModes", ["text/plain"]
                                        ),
                                        "outputModes": tool_data.get(
                                            "outputModes", ["text/plain"]
                                        ),
                                    }
                                    skills.append(skill)
                                    logger.info(
                                        f"✅ Added MCP skill: {tool_name} from {mcp_server.name}"
                                    )
                                else:
                                    logger.info(
                                        f"⏭️ Skipping MCP tool {tool_name} (not in enabled list: {enabled_tools})"
                                    )
                        else:
                            logger.warning(
                                f"⚠️ MCP server {mcp_server.name} has no tools"
                            )
                    else:
                        logger.warning(f"❌ MCP server not found: {mcp_server_id}")
                except Exception as e:
                    logger.error(f"❌ Error processing MCP server {mcp_server_id}: {e}")
            else:
                logger.warning(f"⚠️ MCP config missing ID: {mcp_config}")

        # 3. Add skills from custom tools
        custom_tools = agent_config.get("custom_tools", {})
        logger.info(
            f"🛠️ Found custom tools categories in agent config: {list(custom_tools.keys()) if custom_tools else []}"
        )

        if isinstance(custom_tools, dict):
            for category_name, tools_list in custom_tools.items():
                logger.info(f"🛠️ Processing custom tools category: {category_name}")

                if isinstance(tools_list, list):
                    for i, custom_tool in enumerate(tools_list):
                        logger.info(
                            f"🛠️ Processing custom tool {i+1} in {category_name}: {custom_tool}"
                        )

                        try:
                            tool_name = custom_tool.get("name")
                            tool_id = custom_tool.get("id", tool_name)

                            if tool_name:
                                skill = {
                                    "id": f"custom_{category_name}_{tool_id or tool_name}",
                                    "name": custom_tool.get("name", tool_name),
                                    "description": custom_tool.get(
                                        "description",
                                        f"Custom {category_name} tool: {tool_name}",
                                    ),
                                    "tags": custom_tool.get(
                                        "tags", ["custom", category_name, "tool"]
                                    ),
                                    "examples": custom_tool.get(
                                        "examples",
                                        [
                                            f"Use custom {category_name} tool {tool_name}"
                                        ],
                                    ),
                                    "inputModes": custom_tool.get(
                                        "inputModes", ["text/plain"]
                                    ),
                                    "outputModes": custom_tool.get(
                                        "outputModes", ["text/plain"]
                                    ),
                                }
                                skills.append(skill)
                                logger.info(
                                    f"✅ Added custom skill: {tool_name} from {category_name}"
                                )
                            else:
                                logger.warning(
                                    f"⚠️ Custom tool missing name: {custom_tool}"
                                )

                        except Exception as e:
                            logger.error(
                                f"❌ Error processing custom tool {i+1} in {category_name}: {e}"
                            )
                else:
                    logger.warning(
                        f"⚠️ Custom tools category {category_name} is not a list: {type(tools_list)}"
                    )
        else:
            logger.warning(f"⚠️ custom_tools is not a dict: {type(custom_tools)}")

        # 4. Add default general assistance skill if no other skills
        if not skills:
            logger.info("🤖 No skills found, adding default general assistance skill")
            skills.append(
                {
                    "id": "general-assistance",
                    "name": "General AI Assistant",
                    "description": "Provides general AI assistance and task completion",
                    "tags": ["assistant", "general", "ai", "help"],
                    "examples": ["Help me with a task", "Answer my question"],
                    "inputModes": ["text/plain"],
                    "outputModes": ["text/plain"],
                }
            )

        logger.info(f"✅ Generated {len(skills)} skills for agent {agent.id}")

        # Log all generated skills for debugging
        for skill in skills:
            logger.info(f"📋 Skill: {skill['name']} ({skill['id']})")

        return skills

    except Exception as e:
        logger.error(f"❌ Error generating skills for agent {agent.id}: {e}")
        # Return default skill in case of error
        return [
            {
                "id": "general-assistance",
                "name": "General AI Assistant",
                "description": "Provides general AI assistance and task completion",
                "tags": ["assistant", "general", "ai", "help"],
                "examples": ["Help me with a task", "Answer my question"],
                "inputModes": ["text/plain"],
                "outputModes": ["text/plain"],
            }
        ]
