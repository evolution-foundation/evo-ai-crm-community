"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: agent_utils.py                                                        │
│ Developed by: Davidson Gomes                                                 │
│ Creation date: May 17, 2025                                                  │
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

from typing import List, Tuple, Optional
import uuid
from google.adk.agents.llm_agent import LlmAgent
from src.services.adk.tools.exit_loop import ExitLoopAgent
from src.services.apikey_service import get_decrypted_api_key
from src.utils.logger import setup_logger
from src.utils.llm_model_routing import normalize_model_for_provider  # re-export
from src.core.exceptions import AgentNotFoundError
from src.services.agent_service import get_agent
from src.models.models import ApiKey
from sqlalchemy.orm import Session
from src.schemas.schemas import Agent

__all__ = [
    "get_sub_agents",
    "get_api_key",
    "normalize_model_for_provider",
    "sanitize_for_formatting",
]

logger = setup_logger(__name__)


async def get_sub_agents(
    db: Session,
    sub_agent_ids: List[str],
    parent_type: str = None,
    parent_config: dict = None,
    processed_agents: set = None,
) -> Tuple[List[LlmAgent], Optional[List[str]]]:
    """Get and create LLM sub-agents with circular reference protection."""
    # Initialize processed_agents set if not provided
    if processed_agents is None:
        processed_agents = set()

    sub_agents = []
    all_state_params = []

    for sub_agent_id in sub_agent_ids:
        sub_agent_id_str = str(sub_agent_id)

        # Check for circular reference
        if sub_agent_id_str in processed_agents:
            logger.warning(
                f"Circular reference detected for agent {sub_agent_id_str}, skipping"
            )
            continue

        # Add to processed agents to prevent circular references
        processed_agents.add(sub_agent_id_str)

        agent = await get_agent(db, sub_agent_id_str)

        if agent is None:
            logger.error(f"Sub-agent not found: {sub_agent_id_str}")
            # Remove from processed_agents since we couldn't process it
            processed_agents.discard(sub_agent_id_str)
            raise AgentNotFoundError(f"Agent with ID {sub_agent_id_str} not found")

        logger.debug(f"Sub-agent found: {agent.name} (type: {agent.type})")
        logger.debug(
            f"Parent type: {parent_type}, Parent config has agents_exit_loop: {'agents_exit_loop' in (parent_config or {})}"
        )

        # Enable exit_loop tool for LLM agents inside a LoopAgent or LLM agent
        # Two strategies:
        # 1. If agents_exit_loop is specified, use only those agents
        # 2. If not specified, auto-enable for all LLM sub-agents in loop/llm parents
        should_enable_exit_loop = False

        if parent_type in ["loop", "llm"] and agent.type == "llm":
            if parent_config and "agents_exit_loop" in parent_config:
                # Strategy 1: Explicit list
                agents_exit_loop = parent_config["agents_exit_loop"] or []
                should_enable_exit_loop = sub_agent_id_str in agents_exit_loop
                logger.debug(
                    f"Using explicit agents_exit_loop list: {agents_exit_loop}, agent {sub_agent_id_str} included: {should_enable_exit_loop}"
                )
            else:
                # Strategy 2: Auto-enable for all LLM sub-agents
                should_enable_exit_loop = True
                logger.debug(
                    f"Auto-enabling exit_loop for LLM sub-agent {agent.name} in {parent_type} parent"
                )

        if should_enable_exit_loop and not agent.config.get("enable_exit_loop"):
            # Add enable_exit_loop to the agent config temporarily
            if not agent.config:
                agent.config = {}
            agent.config["enable_exit_loop"] = True
            logger.info(
                f"✅ Enabled exit_loop tool for sub-agent {agent.name} (ID: {sub_agent_id_str}) in {parent_type} parent"
            )

        try:
            # Import builders here to avoid circular imports
            from .llm_agent_builder import LlmAgentBuilder
            from .a2a_agent_builder import A2AAgentBuilder
            from .workflow_agent_builder import WorkflowAgentBuilder
            from .task_agent_builder import TaskAgentBuilder
            from .external_agent_builder import ExternalAgentBuilder
            from .composite_agent_builder import CompositeAgentBuilder

            if agent.type == "llm":
                builder = LlmAgentBuilder(db)
                sub_agent, state_params = await builder.build_llm_agent(
                    agent, processed_agents
                )
            elif agent.type == "a2a":
                builder = A2AAgentBuilder(db)
                sub_agent, state_params = await builder.build_a2a_agent(
                    agent, processed_agents
                )
            elif agent.type == "workflow":
                builder = WorkflowAgentBuilder(db)
                sub_agent, state_params = await builder.build_workflow_agent(
                    agent, processed_agents
                )
            elif agent.type == "task":
                builder = TaskAgentBuilder(db)
                sub_agent, state_params = await builder.build_task_agent(
                    agent, processed_agents
                )
            elif agent.type == "external":
                builder = ExternalAgentBuilder(db)
                sub_agent, state_params = await builder.build_external_agent(
                    agent, processed_agents
                )
            elif agent.type == "sequential":
                builder = CompositeAgentBuilder(db)
                sub_agent, state_params = await builder.build_composite_agent(
                    agent, processed_agents
                )
            elif agent.type == "parallel":
                builder = CompositeAgentBuilder(db)
                sub_agent, state_params = await builder.build_composite_agent(
                    agent, processed_agents
                )
            elif agent.type == "loop":
                builder = CompositeAgentBuilder(db)
                sub_agent, state_params = await builder.build_composite_agent(
                    agent, processed_agents
                )
            else:
                raise ValueError(f"Invalid agent type: {agent.type}")

            sub_agents.append(sub_agent)
            all_state_params.extend(state_params)
            logger.debug(f"Sub-agent added: {agent.name}")

        except Exception as e:
            logger.error(f"Error building sub-agent {sub_agent_id_str}: {e}")
            # Remove from processed_agents since we couldn't process it successfully
            processed_agents.discard(sub_agent_id_str)
            raise

    if parent_type == "loop":
        sub_agents.append(ExitLoopAgent(name="exit_loop_agent"))

    logger.debug(f"Sub-agents created: {len(sub_agents)}")
    return sub_agents, all_state_params


async def get_api_key(db: Session, agent: Agent) -> Tuple[str, Optional[str]]:
    """Get the API key and provider for the agent.

    Returns:
        Tuple of (api_key, provider). `provider` is the stored value from
        ``evo_core_api_keys.provider`` when the agent references a stored key
        via ``api_key_id``; otherwise ``None`` (config-supplied raw keys carry
        no provider metadata). Needed by callers that route through LiteLLM —
        e.g. OpenRouter keys must be prefixed with ``openrouter/`` (EVO-1684).
    """
    api_key = None
    provider: Optional[str] = None

    # Get API key from api_key_id
    if hasattr(agent, "api_key_id") and agent.api_key_id:
        api_key_record = db.query(ApiKey).filter(ApiKey.id == agent.api_key_id).first()
        if api_key_record:
            provider = api_key_record.provider

        if decrypted_key := get_decrypted_api_key(db, agent.api_key_id):
            logger.info(f"Using stored API key for agent {agent.name}")
            api_key = decrypted_key
        else:
            logger.error(f"Stored API key not found for agent {agent.name}")
            raise ValueError(
                f"API key with ID {agent.api_key_id} not found or inactive"
            )
    else:
        # Check if there is an API key in the config (temporary field)
        config_api_key = agent.config.get("api_key") if agent.config else None
        if config_api_key:
            logger.info(f"Using config API key for agent {agent.name}")
            # Check if it is a UUID of a stored key
            try:
                key_id = uuid.UUID(config_api_key)
                if decrypted_key := get_decrypted_api_key(db, key_id):
                    logger.info("Config API key is a valid reference")
                    api_key = decrypted_key
                else:
                    # Use the key directly
                    api_key = config_api_key
            except (ValueError, TypeError):
                # It is not a UUID, use directly
                api_key = config_api_key
        else:
            logger.error(f"No API key configured for agent {agent.name}")
            raise ValueError(f"Agent {agent.name} does not have a configured API key")

    return api_key, provider


def sanitize_for_formatting(instruction: str) -> str:
    """
    Sanitize instruction for string formatting by escaping JSON-like braces.
    This is applied only during formatting, not when saving to database.
    """
    if not instruction:
        return instruction

    # Find and escape JSON-like structures
    def escape_json_blocks(text):
        result = []
        i = 0
        while i < len(text):
            if text[i] == "{":
                # Found opening brace, find matching closing brace
                brace_count = 1
                start = i
                i += 1

                # Look for content that suggests this is JSON (quotes, colons, commas)
                json_indicators = ['"', ":", ",", "[", "]"]
                has_json_content = False

                while i < len(text) and brace_count > 0:
                    if text[i] == "{":
                        brace_count += 1
                    elif text[i] == "}":
                        brace_count -= 1
                    elif text[i] in json_indicators:
                        has_json_content = True
                    i += 1

                if brace_count == 0 and has_json_content:
                    # This looks like JSON, escape it
                    json_block = text[start:i]
                    escaped_block = json_block.replace("{", "{{").replace("}", "}}")
                    result.append(escaped_block)
                else:
                    # Not JSON or malformed, keep as is
                    result.append(text[start:i])
            else:
                result.append(text[i])
                i += 1

        return "".join(result)

    return escape_json_blocks(instruction)
