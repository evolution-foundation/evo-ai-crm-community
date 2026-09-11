"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: agent_service.py                                                      │
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

from sqlalchemy.orm import Session
from sqlalchemy.exc import SQLAlchemyError
from fastapi import HTTPException, status
from src.models.models import Agent
from typing import List, Optional, Union, Dict, Any
from src.services import custom_tool_service, custom_mcp_server_service
import uuid
import logging

logger = logging.getLogger(__name__)

# Committed onto a malformed agent coerced to llm, so a retired id here lands in
# the customer's data. Prefixed for LiteLLM; mirrors defaultRepairModel in core-service.
DEFAULT_REPAIR_MODEL = "openai/gpt-5.6-luna"


class AgentValidationError(Exception):
    """Raised when agent API key validation cannot be completed due to an
    infrastructure error (DB down, dead pooled connection, timeout) — NOT an
    invalid key. Callers MUST map this to a 5xx (retryable), never to a 401.

    EVO-2166: a transient DB blip used to be swallowed into {"valid": False},
    which the auth middleware turned into a silent, non-retryable 401 — the
    customer's message was dropped with no signal that it was transient.
    """

def generate_api_key() -> str:
    """Generate a secure API key"""
    # Format: sk-proj-{random 64 chars}

    return str(uuid.uuid4())


def _convert_uuid_to_str(obj):
    """
    Recursively convert all UUID objects to strings in a dictionary, list or scalar value.
    This ensures JSON serialize for complex nested objects.
    """
    if isinstance(obj, dict):
        return {key: _convert_uuid_to_str(value) for key, value in obj.items()}
    elif isinstance(obj, list):
        return [_convert_uuid_to_str(item) for item in obj]
    elif isinstance(obj, uuid.UUID):
        return str(obj)
    else:
        return obj


def _reconstruct_custom_configurations(db: Session, agent: Agent) -> None:
    """Expand the saved custom tool / MCP server IDs into the agent config.

    Synchronous: every lookup below is a sync ORM query, and get_agents_by_account
    (a sync function) calls this — as a coroutine it was never awaited there, so
    agents listed by account silently kept their tools unexpanded.

    In-memory only: the expansion hydrates the config that is handed to the API
    response and to the builders, and is never written back. Persisting it would
    freeze a copy of the tool (endpoint, headers, values) inside the agent, and
    the guards below — which skip the expansion once http_tools is populated —
    would then keep serving that copy forever, so editing or deleting the tool in
    the catalog would never reach the agent.
    """
    if not agent.config or not isinstance(agent.config, dict):
        return

    config = agent.config

    # Only expand if we have IDs but no corresponding configurations
    # This prevents expansion during config processing and only does it during agent retrieval

    # Reconstruct custom tools from IDs
    if (
        "custom_tool_ids" in config
        and config["custom_tool_ids"]
        and (
            "custom_tools" not in config
            or not config.get("custom_tools")
            or not config["custom_tools"].get("http_tools")
        )
    ):
        try:
            tool_ids = [
                uuid.UUID(str(tool_id)) for tool_id in config["custom_tool_ids"]
            ]

            # Convert to HTTPTool format
            http_tools = []
            for tool_id in tool_ids:
                tool = custom_tool_service.get_custom_tool(db, tool_id)
                if not tool:
                    logger.warning(
                        f"Custom tool not found: {tool_id} (agent {agent.id})"
                    )
                    continue
                http_tools.append(custom_tool_service.convert_to_http_tool(tool))

            # Update config with reconstructed tools
            if "custom_tools" not in config:
                config["custom_tools"] = {"http_tools": []}
            elif not config["custom_tools"]:
                config["custom_tools"] = {"http_tools": []}
            elif "http_tools" not in config["custom_tools"]:
                config["custom_tools"]["http_tools"] = []

            # Replace existing http_tools with reconstructed ones
            config["custom_tools"]["http_tools"] = http_tools

            logger.debug(
                f"Reconstructed {len(http_tools)} custom tools for agent {agent.id}"
            )

        except Exception as e:
            logger.warning(
                f"Error reconstructing custom tools for agent {agent.id}: {str(e)}"
            )

    # Reconstruct custom MCP servers from IDs
    if (
        "custom_mcp_server_ids" in config
        and config["custom_mcp_server_ids"]
        and ("custom_mcp_servers" not in config or not config.get("custom_mcp_servers"))
    ):
        try:
            server_ids = [
                uuid.UUID(str(server_id))
                for server_id in config["custom_mcp_server_ids"]
            ]
            custom_servers_from_ids = (
                custom_mcp_server_service.get_custom_mcp_servers_for_agent_config(
                    db, server_ids
                )
            )

            # Update config with reconstructed servers
            if "custom_mcp_servers" not in config:
                config["custom_mcp_servers"] = []

            # Replace existing custom_mcp_servers with reconstructed ones
            config["custom_mcp_servers"] = custom_servers_from_ids

            logger.debug(
                f"Reconstructed {len(custom_servers_from_ids)} custom MCP servers for agent {agent.id}"
            )

        except Exception as e:
            logger.warning(
                f"Error reconstructing custom MCP servers for agent {agent.id}: {str(e)}"
            )


async def validate_agent_api_key(db: Session, agent_id: Union[uuid.UUID, str], api_key: str) -> Optional[dict]:
    """
    Validate agent API key by comparing with stored key in database
    
    Args:
        db: Database session
        agent_id: UUID of the agent
        api_key: Hex API key to validate
        
    Returns:
        dict with validation result or None if invalid: {
            "valid": bool,
            "agent_id": str,
            "agent_name": str
        }
    """
    try:
        # Convert to UUID if it's a string
        if isinstance(agent_id, str):
            try:
                agent_id = uuid.UUID(agent_id)
            except ValueError:
                logger.warning(f"Invalid agent ID: {agent_id}")
                return {"valid": False, "agent_id": str(agent_id), "agent_name": None}

        agent = db.query(Agent).filter(Agent.id == agent_id).first()
        if not agent:
            logger.warning(f"Agent not found: {agent_id}")
            return {"valid": False, "agent_id": str(agent_id), "agent_name": None}

        # Get API key from agent config
        if not agent.config or not isinstance(agent.config, dict):
            logger.warning(f"Agent {agent_id} has no config")
            return {
                "valid": False,
                "agent_id": str(agent.id),
                "agent_name": agent.name
            }

        stored_api_key = agent.config.get("api_key")
        if not stored_api_key:
            logger.warning(f"Agent {agent_id} has no API key configured")
            return {
                "valid": False,
                "agent_id": str(agent.id),
                "agent_name": agent.name
            }

        # Compare API keys
        if api_key != stored_api_key:
            logger.warning(f"Invalid API key for agent {agent_id}")
            return {
                "valid": False,
                "agent_id": str(agent.id),
                "agent_name": agent.name
            }

        # Valid API key
        logger.debug(f"Valid API key for agent {agent.name}")
        return {
            "valid": True,
            "agent_id": str(agent.id),
            "agent_name": agent.name
        }

    except SQLAlchemyError as e:
        # EVO-2166: infrastructure error (dead pooled connection, DB down/timeout)
        # is NOT an authentication decision. Surface it as a retryable 5xx instead
        # of a silent 401 by raising rather than returning {"valid": False}.
        logger.error(f"Infra error validating API key for agent {agent_id}: {str(e)}")
        raise AgentValidationError(str(e)) from e
    except Exception as e:
        # Any other unexpected failure is likewise "could not determine", not
        # "invalid key" -> treat as infrastructure (5xx), never a 401. This
        # branch also swallows genuine code bugs into a "retryable" 5xx, so log
        # the traceback (exc_info) to keep such bugs diagnosable.
        logger.error(
            f"Unexpected error validating API key for agent {agent_id}: {str(e)}",
            exc_info=True,
        )
        raise AgentValidationError(str(e)) from e


async def get_agent_integrations(db: Session, agent_id: Union[uuid.UUID, str]) -> List[Dict[str, Any]]:
    """Get all integrations for an agent directly from database."""
    try:
        from sqlalchemy import text

        # Convert to UUID if needed
        if isinstance(agent_id, str):
            agent_id = uuid.UUID(agent_id)

        # Query integrations directly from database
        query = text("""
            SELECT
                provider,
                config::text as config_json
            FROM evo_core_agent_integrations
            WHERE agent_id = :agent_id
        """)

        result = db.execute(query, {"agent_id": str(agent_id)})
        rows = result.fetchall()

        integrations = []
        for row in rows:
            try:
                import json
                config = json.loads(row.config_json) if row.config_json else {}
                integrations.append({
                    "provider": row.provider,
                    "config": config
                })
            except Exception as e:
                logger.warning(f"Error parsing integration config for provider {row.provider}: {e}")
                continue

        logger.debug(f"Found {len(integrations)} integrations for agent {agent_id}")
        return integrations
    except Exception as e:
        logger.warning(f"Error fetching agent integrations from database: {e}")
        return []


async def get_agent_integration_by_provider(
    db: Session,
    agent_id: Union[uuid.UUID, str],
    provider: str
) -> Optional[Dict[str, Any]]:
    """Get a specific integration for an agent by provider, directly from database (without sanitization)."""
    try:
        from sqlalchemy import text
        import json

        # Convert to UUID if needed
        if isinstance(agent_id, str):
            agent_id = uuid.UUID(agent_id)

        # Query specific integration directly from database
        query = text("""
            SELECT config::text as config_json
            FROM evo_core_agent_integrations
            WHERE agent_id = :agent_id
            AND provider = :provider
            LIMIT 1
        """)

        result = db.execute(query, {
            "agent_id": str(agent_id),
            "provider": provider
        })
        row = result.fetchone()

        if not row:
            logger.debug(f"No integration found for provider {provider} and agent {agent_id}")
            return None

        config = json.loads(row.config_json) if row.config_json else {}
        logger.debug(f"Found integration {provider} for agent {agent_id} with config keys: {list(config.keys())}")
        return config
    except Exception as e:
        logger.error(f"Error fetching agent integration {provider} from database: {e}")
        return None


async def upsert_agent_integration(
    db: Session,
    agent_id: Union[uuid.UUID, str],
    provider: str,
    config: Dict[str, Any]
) -> bool:
    """Upsert an agent integration directly to database."""
    try:
        from sqlalchemy import text
        import json

        # Convert to UUID if needed
        if isinstance(agent_id, str):
            agent_id = uuid.UUID(agent_id)

        # Convert config to JSON string
        config_json = json.dumps(config)

        # Upsert integration using PostgreSQL ON CONFLICT
        # Use CAST() instead of ::jsonb for SQLAlchemy text() compatibility
        query = text("""
            INSERT INTO evo_core_agent_integrations (agent_id, provider, config, updated_at)
            VALUES (:agent_id, :provider, CAST(:config AS jsonb), NOW())
            ON CONFLICT (agent_id, provider)
            DO UPDATE SET
                config = CAST(:config AS jsonb),
                updated_at = NOW()
        """)

        db.execute(query, {
            "agent_id": str(agent_id),
            "provider": provider,
            "config": config_json
        })
        db.commit()
        
        logger.debug(f"Upserted integration {provider} for agent {agent_id}")
        return True
    except Exception as e:
        logger.error(f"Error upserting agent integration: {e}")
        db.rollback()
        return False


async def get_agent(db: Session, agent_id: Union[uuid.UUID, str]) -> Optional[Agent]:
    """Search for an agent by ID"""
    try:
        # Convert to UUID if it's a string
        if isinstance(agent_id, str):
            try:
                agent_id = uuid.UUID(agent_id)
            except ValueError:
                logger.warning(f"Invalid agent ID: {agent_id}")
                return None

        agent = db.query(Agent).filter(Agent.id == agent_id).first()
        if not agent:
            logger.warning(f"Agent not found: {agent_id}")
            return None

        # Reconstruct custom configurations from saved IDs
        _reconstruct_custom_configurations(db, agent)

        # Sanitize agent name if it contains spaces or special characters
        if agent.name and any(c for c in agent.name if not (c.isalnum() or c == "_")):
            agent.name = "".join(
                c if c.isalnum() or c == "_" else "_" for c in agent.name
            )
            # Update in database
            db.commit()

        # Sanitize agent configuration to prevent validation errors
        if agent.config and agent.type in ["sequential", "parallel", "loop"]:
            config_updated = False

            # Ensure sub_agents exists and is not empty
            if "sub_agents" not in agent.config or not agent.config["sub_agents"]:
                logger.warning(
                    f"Agent {agent.id} of type {agent.type} has empty or missing sub_agents. Updating to prevent validation error."
                )

                # Convert to llm type since it doesn't require sub_agents
                agent.type = "llm"

                # Set a default model if not present
                if not agent.model:
                    agent.model = DEFAULT_REPAIR_MODEL

                # Convert config to basic LLM config structure
                if not isinstance(agent.config, dict):
                    agent.config = {}

                # Keep existing config but ensure it has the required structure
                llm_config = {
                    "api_key": agent.config.get("api_key", ""),
                    "temperature": agent.config.get("temperature", 0.7),
                    "max_tokens": agent.config.get("max_tokens", 1000),
                    "tools": agent.config.get("tools", []),
                    "custom_tools": agent.config.get("custom_tools", []),
                    "mcp_servers": agent.config.get("mcp_servers", []),
                    "custom_mcp_servers": agent.config.get("custom_mcp_servers", []),
                }

                # Add any other existing config items that aren't conflicting
                for key, value in agent.config.items():
                    if key not in llm_config and key != "sub_agents":
                        llm_config[key] = value

                agent.config = llm_config
                config_updated = True

            # If we made changes, commit them to the database
            if config_updated:
                try:
                    db.commit()
                    logger.info(
                        f"Updated invalid agent {agent.id} configuration to prevent validation error"
                    )
                except Exception as e:
                    db.rollback()
                    logger.error(
                        f"Failed to update agent {agent.id} configuration: {str(e)}"
                    )

        return agent
    except SQLAlchemyError as e:
        logger.error(f"Error searching for agent {agent_id}: {str(e)}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Error searching for agent",
        )

def get_agents_by_account(
    db: Session,
    skip: int = 0,
    limit: int = 100,
    folder_id: Optional[uuid.UUID] = None,
    sort_by: str = "name",
    sort_direction: str = "asc",
) -> List[Agent]:
    """Search for agents with pagination and optional folder filter"""
    try:
        query = db.query(Agent)

        # Filter by folder if specified
        if folder_id is not None:
            query = query.filter(Agent.folder_id == folder_id)

        # Apply sorting
        if sort_by == "name":
            if sort_direction.lower() == "desc":
                query = query.order_by(Agent.name.desc())
            else:
                query = query.order_by(Agent.name)
        elif sort_by == "created_at":
            if sort_direction.lower() == "desc":
                query = query.order_by(Agent.created_at.desc())
            else:
                query = query.order_by(Agent.created_at)

        agents = query.offset(skip).limit(limit).all()

        # Sanitize agent data before returning
        for agent in agents:
            # Reconstruct custom configurations from saved IDs
            _reconstruct_custom_configurations(db, agent)

            # Sanitize agent names if they contain spaces or special characters
            if agent.name and any(
                c for c in agent.name if not (c.isalnum() or c == "_")
            ):
                agent.name = "".join(
                    c if c.isalnum() or c == "_" else "_" for c in agent.name
                )
                # Update in database
                db.commit()

            # Sanitize agent configurations to prevent validation errors
            if agent.config and agent.type in ["sequential", "parallel", "loop"]:
                config_updated = False

                # Ensure sub_agents exists and is not empty
                if "sub_agents" not in agent.config or not agent.config["sub_agents"]:
                    logger.warning(
                        f"Agent {agent.id} of type {agent.type} has empty or missing sub_agents. Updating to prevent validation error."
                    )

                    # Convert to llm type since it doesn't require sub_agents
                    agent.type = "llm"

                    # Set a default model if not present
                    if not agent.model:
                        agent.model = DEFAULT_REPAIR_MODEL

                    # Convert config to basic LLM config structure
                    if not isinstance(agent.config, dict):
                        agent.config = {}

                    # Keep existing config but ensure it has the required structure
                    llm_config = {
                        "api_key": agent.config.get("api_key", ""),
                        "temperature": agent.config.get("temperature", 0.7),
                        "max_tokens": agent.config.get("max_tokens", 1000),
                        "tools": agent.config.get("tools", []),
                        "custom_tools": agent.config.get("custom_tools", []),
                        "mcp_servers": agent.config.get("mcp_servers", []),
                        "custom_mcp_servers": agent.config.get(
                            "custom_mcp_servers", []
                        ),
                    }

                    # Add any other existing config items that aren't conflicting
                    for key, value in agent.config.items():
                        if key not in llm_config and key != "sub_agents":
                            llm_config[key] = value

                    agent.config = llm_config
                    config_updated = True

                # If we made changes, commit them to the database
                if config_updated:
                    try:
                        db.commit()
                        logger.info(
                            f"Updated invalid agent {agent.id} configuration to prevent validation error"
                        )
                    except Exception as e:
                        db.rollback()
                        logger.error(
                            f"Failed to update agent {agent.id} configuration: {str(e)}"
                        )

        return agents
    except SQLAlchemyError as e:
        logger.error(f"Error searching for agents: {str(e)}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Error searching for agents",
        )

# Functions for agent folders
def get_accessible_agents_for_account(
    db: Session, user_email: str
) -> List[Agent]:
    """Get all agents accessible to a user (owned + from shared folders)"""
    try:
        from src.models.models import FolderShare

        # Get all agents
        owned_agents = db.query(Agent).all()

        # Get agents from shared folders that the user has access to
        shared_agents = (
            db.query(Agent)
            .join(FolderShare, Agent.folder_id == FolderShare.folder_id)
            .filter(
                FolderShare.shared_with_email == user_email,
                FolderShare.is_active == True,
                Agent.folder_id.isnot(None),  # Only agents that are in folders
            )
            .all()
        )

        # Combine and deduplicate (in case an agent is both owned and shared)
        all_agents = owned_agents + shared_agents

        # Remove duplicates by agent ID
        seen_ids = set()
        unique_agents = []
        for agent in all_agents:
            if agent.id not in seen_ids:
                seen_ids.add(agent.id)
                unique_agents.append(agent)

        logger.info(
            f"User {user_email} has access to {len(unique_agents)} agents ({len(owned_agents)} owned, {len(shared_agents)} shared)"
        )
        return unique_agents

    except SQLAlchemyError as e:
        logger.error(f"Error getting accessible agents for user {user_email}: {str(e)}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Error getting accessible agents",
        )
