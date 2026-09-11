"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: llm_agent_builder.py                                                  │
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


from typing import Any, Dict, List, Tuple, Optional
from functools import cached_property
import os
from google.adk.agents.llm_agent import LlmAgent
from google.adk.models.lite_llm import LiteLlm
from google.adk.tools.agent_tool import AgentTool
from google.adk.tools import load_artifacts
from google.adk.tools.load_memory_tool import load_memory_tool
from google.adk.agents.callback_context import CallbackContext
from google.adk.models.google_llm import Gemini
from google.adk.planners import PlanReActPlanner
from src.schemas.schemas import Agent
from src.utils.adk_utils import extract_state_params
from src.utils.logger import setup_logger
from src.services.agent_service import get_agent
from src.services.adk.tool_builder import ToolBuilder
from src.services.adk.mcp_service import MCPService
from src.utils.schema_utils import json_schema_to_pydantic, validate_output_schema
from google.adk.models.llm_response import LlmResponse
from sqlalchemy.orm import Session
from datetime import datetime
from zoneinfo import ZoneInfo
from .agent_utils import (
    get_sub_agents,
    get_api_key,
    normalize_model_for_provider,
    sanitize_for_formatting,
)

logger = setup_logger(__name__)


class GeminiWithApiKey(Gemini):
    api_key: str

    @cached_property
    def api_client(self):
        from google.genai import Client, types

        return Client(
            api_key=self.api_key,
            http_options=types.HttpOptions(headers=self._tracking_headers),
        )

    @cached_property
    def _live_api_client(self):
        from google.genai import Client, types

        api_version = "v1alpha"
        return Client(
            api_key=self.api_key,
            http_options=types.HttpOptions(
                headers=self._tracking_headers, api_version=api_version
            ),
        )


def get_datetime_in_timezone(timezone_str: Optional[str] = None) -> datetime:
    """Get current datetime in the specified timezone, or UTC if not specified."""
    if timezone_str:
        try:
            tz = ZoneInfo(timezone_str)
            return datetime.now(tz)
        except Exception as e:
            logger.warning(f"Invalid timezone '{timezone_str}': {e}, using UTC")
            return datetime.now(ZoneInfo("UTC"))
    return datetime.now(ZoneInfo("UTC"))


def _format_pipeline_rules_for_prompt(pipeline_rules: List[Dict[str, Any]]) -> List[str]:
    """Render the agent's pipeline rules as prompt lines, one per STAGE.

    The stages live inside each rule (``rule["stages"]``), not on the rule
    itself, and each line carries the ids the tool needs. A stage with no
    ``stageId`` is dropped: the model cannot call the tool without one, and
    listing it only invites an invented stage name.
    """
    lines: List[str] = []

    for rule in pipeline_rules or []:
        if not isinstance(rule, dict):
            continue

        pipeline_name = (
            rule.get("pipelineName")
            or rule.get("pipeline_name")
            or rule.get("pipelineId")
            or rule.get("pipeline_id")
            or "unknown pipeline"
        )
        pipeline_id = rule.get("pipelineId") or rule.get("pipeline_id")
        general = rule.get("generalInstructions") or rule.get("general_instructions") or ""

        header = f"- Pipeline: {pipeline_name}"
        if pipeline_id:
            header += f" (pipeline_id: {pipeline_id})"
        if general:
            header += f" — {general}"
        lines.append(header)

        stages = rule.get("stages")
        if isinstance(stages, list) and stages:
            for stage in stages:
                if not isinstance(stage, dict):
                    continue
                stage_id = stage.get("stageId") or stage.get("stage_id") or ""
                if not stage_id:
                    # Half-configured stage: the operator wrote the criteria and
                    # never picked the stage in the select.
                    logger.warning(f"pipeline rule stage without stageId, skipped: {stage}")
                    continue
                stage_name = stage.get("stageName") or stage.get("stage_name") or stage_id
                instructions = stage.get("instructions") or stage.get("description") or ""

                descriptor = f"    - Stage: {stage_name} (stage_id: {stage_id})"
                if instructions:
                    descriptor += f" — move here when: {instructions}"
                lines.append(descriptor)
            continue

        # Legacy flat rule: the stage sat on the rule itself. Without an id it is
        # unreachable anyway -- the tool resolves a name through rule["stages"].
        legacy_id = rule.get("stageId") or rule.get("stage_id") or ""
        legacy_name = rule.get("stageName") or rule.get("stage_name") or legacy_id
        legacy_instructions = rule.get("instructions") or rule.get("description") or ""
        if legacy_id:
            descriptor = f"    - Stage: {legacy_name} (stage_id: {legacy_id})"
            if legacy_instructions:
                descriptor += f" — move here when: {legacy_instructions}"
            lines.append(descriptor)

    return lines


def _pipeline_tool_instruction(rules_text: List[str]) -> str:
    """Instruction block for the pipeline tool when the agent has rules configured.

    CRM-238: says when to ACT, which action to pick and that the ids belong to
    the conversation context — prohibitions alone left the model idle, and an
    unstated card state made it add a conversation that already had one.
    """
    return (
        "Pipeline Manipulation Tool: Available. It acts on the CURRENT conversation.\n"
        "WHEN TO ACT: when the customer's message matches a stage's \"move here when\" "
        "description below, call the tool with that stage's stage_id. Acting is expected "
        "in that case — do not wait for the customer to ask to be moved.\n"
        "WHICH ACTION: use action=\"move_to_stage\" for a conversation that already has a card "
        "in the pipeline — the normal case for an ongoing conversation. Use "
        "action=\"add_to_pipeline\" only for a conversation that is not in any pipeline yet; "
        "if a move fails because the card does not exist, then add it.\n"
        "IDS: do NOT set conversation_id or contact_id — the conversation context "
        "supplies them and overrides anything you pass. Provide pipeline_id and stage_id.\n"
        f"Configured pipeline rules:\n{chr(10).join(rules_text)}\n"
        "Only use a stage listed above: never invent a stage name or id. If no stage's "
        "description matches the situation, leave the card where it is."
    )


def create_update_current_time_callback(timezone_str: Optional[str] = None):
    """Create a callback function that updates current time with the specified timezone."""
    async def update_current_time(callback_context: CallbackContext):
        """Update current time in callback context."""
        now = get_datetime_in_timezone(timezone_str)
        callback_context.state["_datetime"] = now.isoformat()
    return update_current_time


def create_update_contact_info_callback():
    """Create a callback function that updates contact information in the prompt."""
    async def update_contact_info(callback_context: CallbackContext):
        """Update contact information in callback context from metadata."""
        logger.info("[ContactInfo] Starting update_contact_info callback")
        
        # Log all state keys for debugging
        try:
            # Try to get all state keys (if possible)
            state_dict = dict(callback_context.state) if hasattr(callback_context.state, '__iter__') else {}
            logger.info(f"[ContactInfo] State keys available: {list(state_dict.keys()) if isinstance(state_dict, dict) else 'N/A'}")
        except Exception as e:
            logger.debug(f"[ContactInfo] Could not list state keys: {e}")
        
        # Extract contact info from metadata
        # The metadata is stored in state with keys like "evoai_crm_data", "contact", etc.
        
        # Try multiple ways to get contact data
        contact_data = None
        
        # 1. Check if contact is stored directly in state (most common case)
        try:
            contact_data = callback_context.state.get("contact")
            if contact_data:
                logger.info(f"[ContactInfo] ✅ Found contact directly in state: {contact_data.get('name', 'Unknown')}")
        except (AttributeError, TypeError) as e:
            logger.debug(f"[ContactInfo] Error accessing state.contact: {e}")
        
        # 2. Check if contact is inside evoai_crm_data
        if not contact_data:
            try:
                evoai_crm_data = callback_context.state.get("evoai_crm_data", {})
                logger.debug(f"[ContactInfo] evoai_crm_data type: {type(evoai_crm_data)}, keys: {list(evoai_crm_data.keys()) if isinstance(evoai_crm_data, dict) else 'N/A'}")
                if isinstance(evoai_crm_data, dict) and "contact" in evoai_crm_data:
                    contact_data = evoai_crm_data.get("contact")
                    logger.info(f"[ContactInfo] ✅ Found contact inside evoai_crm_data: {contact_data.get('name', 'Unknown') if isinstance(contact_data, dict) else 'N/A'}")
            except (AttributeError, TypeError) as e:
                logger.debug(f"[ContactInfo] Error accessing evoai_crm_data: {e}")
        
        # 3. Check if evoai_crm_data itself contains contact fields (flat structure)
        if not contact_data:
            try:
                evoai_crm_data = callback_context.state.get("evoai_crm_data", {})
                if isinstance(evoai_crm_data, dict) and evoai_crm_data.get("contactId"):
                    # Try to reconstruct contact from evoai_crm_data fields
                    if evoai_crm_data.get("contact"):
                        contact_data = evoai_crm_data.get("contact")
                        logger.info(f"[ContactInfo] ✅ Found contact in evoai_crm_data.contact: {contact_data.get('name', 'Unknown') if isinstance(contact_data, dict) else 'N/A'}")
            except (AttributeError, TypeError) as e:
                logger.debug(f"[ContactInfo] Error accessing evoai_crm_data.contact: {e}")
        
        # Ensure contact_data is a dict
        if not isinstance(contact_data, dict):
            contact_data = {}
        
        if contact_data:
            logger.debug(f"[ContactInfo] Processing contact data: {contact_data.get('name', 'Unknown')}")
            # Build contact info string with ALL available contact data
            contact_info_lines = ["Contact Information:"]
            
            # Basic information
            if contact_data.get("id"):
                contact_info_lines.append(f"  ID: {contact_data.get('id')}")
            
            if contact_data.get("name"):
                contact_info_lines.append(f"  Name: {contact_data.get('name')}")
            
            if contact_data.get("identifier"):
                contact_info_lines.append(f"  Identifier: {contact_data.get('identifier')}")
            
            if contact_data.get("email"):
                contact_info_lines.append(f"  Email: {contact_data.get('email')}")
            
            if contact_data.get("phone_number"):
                contact_info_lines.append(f"  Phone: {contact_data.get('phone_number')}")
            
            if contact_data.get("country_code"):
                contact_info_lines.append(f"  Country Code: {contact_data.get('country_code')}")
            
            if contact_data.get("type"):
                contact_info_lines.append(f"  Type: {contact_data.get('type')}")
            
            if contact_data.get("contact_type"):
                contact_info_lines.append(f"  Contact Type: {contact_data.get('contact_type')}")
            
            if contact_data.get("blocked") is not None:
                contact_info_lines.append(f"  Blocked: {contact_data.get('blocked')}")
            
            if contact_data.get("location"):
                contact_info_lines.append(f"  Location: {contact_data.get('location')}")
            
            if contact_data.get("industry"):
                contact_info_lines.append(f"  Industry: {contact_data.get('industry')}")
            
            if contact_data.get("website"):
                contact_info_lines.append(f"  Website: {contact_data.get('website')}")
            
            if contact_data.get("tax_id"):
                contact_info_lines.append(f"  Tax ID: {contact_data.get('tax_id')}")
            
            # Dates
            if contact_data.get("created_at"):
                contact_info_lines.append(f"  Created At: {contact_data.get('created_at')}")
            
            if contact_data.get("updated_at"):
                contact_info_lines.append(f"  Updated At: {contact_data.get('updated_at')}")
            
            if contact_data.get("last_activity_at"):
                contact_info_lines.append(f"  Last Activity At: {contact_data.get('last_activity_at')}")
            
            # Labels
            if contact_data.get("labels"):
                labels = contact_data.get("labels", [])
                if labels:
                    contact_info_lines.append(f"  Labels: {', '.join(labels)}")
            
            # Companies
            if contact_data.get("companies"):
                companies = contact_data.get("companies", [])
                if companies:
                    company_info = []
                    for company in companies:
                        company_id = company.get("id", "")
                        company_name = company.get("name", "")
                        if company_name:
                            company_info.append(f"{company_name}" + (f" (ID: {company_id})" if company_id else ""))
                    if company_info:
                        contact_info_lines.append(f"  Companies: {', '.join(company_info)}")
            
            # Pipeline Items
            pipeline_data = contact_data.get("pipelines") or contact_data.get("pipeline_items", [])
            if pipeline_data:
                pipeline_info_lines = []
                for pipeline_item in pipeline_data:
                    pipeline_id = pipeline_item.get("pipeline_id", "N/A")
                    pipeline_name = pipeline_item.get("pipeline_name", "N/A")
                    stage_id = pipeline_item.get("stage_id", "N/A")
                    stage_name = pipeline_item.get("stage_name", "N/A")
                    stage_position = pipeline_item.get("stage_position")
                    status = pipeline_item.get("status", "N/A")
                    entered_at = pipeline_item.get("entered_at")
                    completed_at = pipeline_item.get("completed_at")
                    
                    pipeline_info_lines.append(f"    - Pipeline: {pipeline_name} (ID: {pipeline_id})")
                    pipeline_info_lines.append(f"      Stage: {stage_name} (ID: {stage_id}" + (f", Position: {stage_position}" if stage_position is not None else "") + ")")
                    pipeline_info_lines.append(f"      Status: {status}")
                    
                    if entered_at:
                        pipeline_info_lines.append(f"      Entered At: {entered_at}")
                    if completed_at:
                        pipeline_info_lines.append(f"      Completed At: {completed_at}")
                    
                    # Custom fields
                    custom_fields = pipeline_item.get("custom_fields", {})
                    if custom_fields:
                        custom_fields_str = ", ".join([f"{k}: {v}" for k, v in custom_fields.items() if v])
                        if custom_fields_str:
                            pipeline_info_lines.append(f"      Custom Fields: {custom_fields_str}")
                    
                    # Tasks
                    tasks = pipeline_item.get("tasks", [])
                    if tasks:
                        tasks_info = []
                        for task in tasks:
                            task_id = task.get("id", "")
                            task_title = task.get("title", "")
                            task_status = task.get("status", "")
                            if task_title:
                                tasks_info.append(f"{task_title} ({task_status})" + (f" [ID: {task_id}]" if task_id else ""))
                        if tasks_info:
                            pipeline_info_lines.append(f"      Tasks: {', '.join(tasks_info)}")
                
                if pipeline_info_lines:
                    contact_info_lines.append("  Pipeline Items:")
                    contact_info_lines.extend(pipeline_info_lines)
            
            # Custom Attributes
            if contact_data.get("custom_attributes"):
                custom_attrs = contact_data.get("custom_attributes", {})
                if custom_attrs:
                    custom_attrs_str = ", ".join([f"{k}: {v}" for k, v in custom_attrs.items() if v])
                    if custom_attrs_str:
                        contact_info_lines.append(f"  Custom Attributes: {custom_attrs_str}")
            
            # Additional Attributes
            if contact_data.get("additional_attributes"):
                additional_attrs = contact_data.get("additional_attributes", {})
                if additional_attrs:
                    additional_attrs_str = ", ".join([f"{k}: {v}" for k, v in additional_attrs.items() if v])
                    if additional_attrs_str:
                        contact_info_lines.append(f"  Additional Attributes: {additional_attrs_str}")
            
            contact_info = "\n".join(contact_info_lines)
            callback_context.state["contact_info"] = contact_info
            logger.info(f"[ContactInfo] ✅ Generated complete contact info ({len(contact_info)} chars)")
            logger.debug(f"[ContactInfo] Contact info preview: {contact_info[:300]}...")
        else:
            # No contact data available
            logger.debug("[ContactInfo] No contact data found in state")
            callback_context.state["contact_info"] = ""
    
    return update_contact_info


async def update_current_time(callback_context: CallbackContext):
    """Update current time in callback context (default, uses UTC)."""
    now = get_datetime_in_timezone(None)
    callback_context.state["_datetime"] = now.isoformat()


async def advanced_usage_tracker(
    callback_context: CallbackContext, llm_response: LlmResponse
) -> Optional[LlmResponse]:
    """Track advanced usage of the model."""
    try:
        print("In advanced_usage_tracker callback context")
        usage = None
        if hasattr(llm_response, "usage_metadata"):
            usage = llm_response.usage_metadata
            # print(f"Found usage_metadata: {usage}")
        elif hasattr(llm_response, "metadata"):
            usage = llm_response.metadata
            # print(f"Found metadata: {llm_response.metadata}")

        # if hasattr(llm_response, "__dict__"):
        #     print(f"llm_response.__dict__: {llm_response.__dict__}")

        if usage:
            callback_context.state["usage_metadata"] = usage

        # Convert usage to a JSON-serializable format
        # usage_to_str = "null"
        # if usage:
        #     try:
        #         # Convert usage metadata to dict for JSON serialization
        #         if hasattr(usage, "model_dump"):
        #             usage_dict = usage.model_dump()
        #         elif hasattr(usage, "__dict__"):
        #             usage_dict = usage.__dict__
        #         else:
        #             usage_dict = str(usage)
        #         usage_to_str = json.dumps(usage_dict)
        #     except Exception as json_error:
        #         logger.warning(f"Failed to serialize usage metadata: {json_error}")
        #         usage_to_str = f'{{"error": "Failed to serialize: {str(json_error)}"}}'

        # original_text = ""
        # if llm_response.content and llm_response.content.parts:
        #     # Assuming simple text response for this example
        #     if llm_response.content.parts[0].text:
        #         original_text = llm_response.content.parts[0].text
        #         print(
        #             f"[Callback] Inspected original response text: '{original_text[:100]}...'"
        #         )  # Log snippet
        #     elif llm_response.content.parts[0].function_call:
        #         print(
        #             f"[Callback] Inspected response: Contains function call '{llm_response.content.parts[0].function_call.name}'. No text modification."
        #         )
        #         return None  # Don't modify tool calls in this example
        #     else:
        #         print("[Callback] Inspected response: No text content found.")
        #         return None
        # elif llm_response.error_message:
        #     print(
        #         f"[Callback] Inspected response: Contains error '{llm_response.error_message}'. No modification."
        #     )
        #     return None
        # else:
        #     print("[Callback] Inspected response: Empty LlmResponse.")
        #     return None  # Nothing to modify

        # modified_parts = [copy.deepcopy(part) for part in llm_response.content.parts]
        # modified_parts[0].text = f"{original_text}\n\nUSAGE METADATA: {usage_to_str}"
        # new_response = LlmResponse(
        #     content=types.Content(role="model", parts=modified_parts),
        #     # Copy other relevant fields if necessary, e.g., grounding_metadata
        #     grounding_metadata=llm_response.grounding_metadata,
        # )

        # return new_response
        return llm_response
    except Exception as e:
        logger.error(f"Error in advanced_usage_tracker: {e}")
        return llm_response


class LlmAgentBuilder:
    """Builder class for LLM agents."""

    def __init__(self, db: Session):
        self.db = db
        self.tool_builder = ToolBuilder()
        self.mcp_service = MCPService()

    async def _agent_tools_builder(
        self, agent: Agent, processed_agents: set = None
    ) -> List[AgentTool]:
        """Build agent tools from the agent configuration."""
        agent_tools_ids = agent.config.get("agent_tools")
        agent_tools = []

        if agent_tools_ids and isinstance(agent_tools_ids, list):
            logger.debug(
                f"Building {len(agent_tools_ids)} agent tools for agent {agent.name}"
            )

            for agent_tool_id in agent_tools_ids:
                agent_tool_id_str = str(agent_tool_id)

                # Check for circular reference
                if processed_agents and agent_tool_id_str in processed_agents:
                    logger.warning(
                        f"Circular reference detected for agent tool {agent_tool_id_str}, skipping"
                    )
                    continue

                try:
                    sub_agent = await get_agent(self.db, agent_tool_id_str)
                    if sub_agent:
                        # Create a copy of processed_agents to avoid modifying the original
                        tool_processed_agents = (
                            processed_agents.copy() if processed_agents else set()
                        )

                        # Build the LLM agent for the tool
                        llm_agent, _ = await self.build_llm_agent(
                            sub_agent, tool_processed_agents
                        )
                        if llm_agent:
                            agent_tools.append(AgentTool(agent=llm_agent))
                            logger.debug(f"Added agent tool: {sub_agent.name}")
                    else:
                        logger.warning(f"Agent tool {agent_tool_id_str} not found")
                except Exception as e:
                    logger.error(f"Error building agent tool {agent_tool_id_str}: {e}")
                    continue

            logger.debug(f"Successfully built {len(agent_tools)} agent tools")

        return agent_tools

    async def _create_llm_agent(
        self, agent: Agent, processed_agents: set = None, enabled_tools: List[str] = []
    ) -> Tuple[LlmAgent, Optional[List[str]]]:
        """Create an LLM agent from the agent data."""
        # Merge integrations from the dedicated `agent_integrations` table into
        # the in-memory agent.config so native tools (ElevenLabs, Knowledge Nexus,
        # Google Calendar, Google Sheets) gated by `integrations[*].connected`
        # also pick up config rows persisted via POST /agents/:id/integrations.
        # Existing entries in agent.config["integrations"] take precedence.
        merged_config = dict(agent.config) if agent.config else {}
        existing_integrations = dict(merged_config.get("integrations") or {})
        for item in getattr(agent, "_integrations", []) or []:
            provider = (item.get("provider") or "").replace("_", "-")
            if not provider:
                continue
            row_config = dict(item.get("config") or {})
            row_config.setdefault("connected", True)
            existing_integrations.setdefault(provider, row_config)
        merged_config["integrations"] = existing_integrations

        # Get custom tools from the configuration
        custom_tools = []
        custom_tools = self.tool_builder.build_tools(
            merged_config, self.db, str(agent.id)
        )

        # Get MCP tools from the configuration
        mcp_tools = []
        mcp_servers = agent.config.get("mcp_servers", []) or []
        custom_mcp_servers = agent.config.get("custom_mcp_servers", []) or []
        custom_mcp_server_ids = agent.config.get("custom_mcp_server_ids", []) or []
        
        # Check for connected integrations (Notion, Stripe, Linear, GitHub) and add them to mcp_servers
        # if they're not already there. This allows tools to load even if the agent wasn't saved
        # after connecting the integration.
        integration_mcps = []
        try:
            integration_providers = ["notion", "stripe", "linear", "monday", "atlassian", "asana", "hubspot", "github"]
            
            # Get integrations from agent object (loaded directly from database)
            integrations_list = getattr(agent, '_integrations', [])
            logger.info(
                f"Processing {len(integrations_list)} integrations for MCP providers "
                f"(loaded from database)"
            )
            
            mcp_urls = {
                "notion": "https://mcp.notion.com/mcp",
                "stripe": "https://mcp.stripe.com",  # Stripe does NOT use /mcp endpoint
                "linear": "https://mcp.linear.app/mcp",
                "monday": "https://mcp.monday.com/mcp",
                "atlassian": "https://mcp.atlassian.com/mcp",
                "asana": "https://mcp.asana.com/mcp",
                "hubspot": "https://mcp.hubspot.com/mcp",
                "github": "https://api.githubcopilot.com/mcp"
            }
            
            for integration in integrations_list:
                provider = integration.get("provider", "").lower()
                logger.debug(
                    f"Checking integration: provider={provider}, "
                    f"config={integration.get('config', {})}"
                )
                
                if provider in integration_providers:
                    logger.info(f"Integration {provider} is an MCP provider, processing...")
                    # Check if this integration is already in mcp_servers
                    already_added = any(
                        server.get("id", "").lower() == provider or 
                        provider in server.get("name", "").lower() or
                        provider in server.get("url", "").lower()
                        for server in mcp_servers
                    )
                    
                    if not already_added:
                        integration_config = integration.get("config", {})
                        is_connected = integration_config.get("connected") is True
                        has_access_token = bool(integration_config.get("access_token"))
                        logger.info(
                            f"Integration {provider}: connected={is_connected}, "
                            f"has_access_token={has_access_token}, "
                            f"mcp_url={integration_config.get('mcp_url')}, "
                            f"tools_count={len(integration_config.get('tools', []))}"
                        )
                        
                        if is_connected:
                            # Use mcp_url from integration config if available, otherwise use default
                            integration_mcp_url = integration_config.get("mcp_url") or mcp_urls.get(provider, "")
                            
                            # Add MCP server for this connected integration
                            integration_mcp = {
                                "id": provider,
                                "name": provider.capitalize(),
                                "type": "standard",
                                "url": integration_mcp_url,
                                "environments": {},
                                "tools": integration_config.get("tools", [])
                            }
                            integration_mcps.append(integration_mcp)
                            logger.info(
                                f"Found connected {provider} integration, adding to MCP servers. "
                                f"URL: {integration_mcp_url}, "
                                f"Tools: {integration_config.get('tools', [])}"
                            )
                        else:
                            logger.warning(
                                f"Integration {provider} is not connected (connected={is_connected}), skipping. "
                                f"Has access_token: {has_access_token}"
                            )
                    else:
                        logger.debug(
                            f"Integration {provider} already in mcp_servers, skipping"
                        )
                else:
                    logger.debug(
                        f"Integration {provider} is not an MCP provider (providers: {integration_providers}), skipping"
                    )
        except Exception as e:
            logger.warning(
                f"Error checking integration statuses: {type(e).__name__}: {e}",
                exc_info=True
            )
        
        # Add integration MCPs to the list if found
        if integration_mcps:
            mcp_servers = mcp_servers + integration_mcps
            logger.info(
                f"Added {len(integration_mcps)} integration MCPs to server list: "
                f"{[mcp['id'] for mcp in integration_mcps]}"
            )
        
        logger.info(
            f"Agent {agent.name} (ID: {agent.id}) MCP config check: "
            f"mcp_servers={len(mcp_servers)}, "
            f"custom_mcp_servers={len(custom_mcp_servers)}, "
            f"custom_mcp_server_ids={len(custom_mcp_server_ids)}"
        )
        
        if mcp_servers or custom_mcp_servers or custom_mcp_server_ids:
            # Create a modified config with the integration MCPs included
            modified_config = agent.config.copy()
            modified_config["mcp_servers"] = mcp_servers
            
            # Use lazy loading for MCP tools with agent ID for caching
            logger.info(f"Building lazy MCP tools for agent {agent.name} (ID: {agent.id})")
            mcp_tools = await self.mcp_service.build_lazy_tools(
                modified_config, self.db, str(agent.id)
            )
            logger.info(
                f"Added {len(mcp_tools)} lazy MCP tools for agent {agent.name}. "
                f"Tool types: {[type(t).__name__ for t in mcp_tools[:5]]}"
            )
        else:
            logger.info(f"No MCP servers configured for agent {agent.name} (ID: {agent.id})")
            mcp_tools = []  # Ensure mcp_tools is initialized even when no MCP servers

        # Get agent tools
        agent_tools = await self._agent_tools_builder(agent, processed_agents)

        # Combine all tools
        logger.info(
            f"Combining tools: custom={len(custom_tools)}, mcp={len(mcp_tools)}, "
            f"agent={len(agent_tools)}"
        )
        all_tools = custom_tools + mcp_tools + agent_tools
        logger.info(f"Total tools after combining: {len(all_tools)}")

        if enabled_tools:
            all_tools = [tool for tool in all_tools if tool.name in enabled_tools]
            logger.debug(
                f"Filtered tools by enabled list. Total tools: {len(all_tools)}"
            )

        # Get timezone from agent config
        timezone_str = agent.config.get("timezone")
        now = get_datetime_in_timezone(timezone_str)
        # ISO 8601 (YYYY-MM-DD) so the LLM never confuses day/month order.
        current_datetime = now.strftime("%Y-%m-%d %H:%M")
        current_day_of_week = now.strftime("%A")
        current_date_iso = now.strftime("%Y-%m-%d")
        current_time = now.strftime("%H:%M")

        state_params = extract_state_params(agent.instruction)

        # Substitute variables in the prompt with safe formatting
        format_vars = {
            "current_datetime": current_datetime,
            "current_day_of_week": current_day_of_week,
            "current_date_iso": current_date_iso,
            "current_time": current_time,
        }

        # Use safe string formatting that handles missing placeholders
        formatted_prompt = agent.instruction
        try:
            # First sanitize the instruction for safe formatting
            sanitized_instruction = sanitize_for_formatting(agent.instruction)
            # Then try normal formatting
            formatted_prompt = sanitized_instruction.format(**format_vars)
        except KeyError as e:
            # If formatting fails due to missing variables, use partial formatting
            logger.warning(f"Missing format variables in agent instruction: {e}")
            try:
                # Use string.Template for safer partial formatting
                from string import Template

                template = Template(
                    sanitized_instruction.replace("{", "${").replace("}", "}")
                )
                formatted_prompt = template.safe_substitute(**format_vars)
                # Convert back from Template format to regular format
                formatted_prompt = formatted_prompt.replace("${", "{").replace("}", "}")
            except Exception as template_error:
                logger.warning(
                    f"Template formatting also failed: {template_error}, using original instruction"
                )
                formatted_prompt = agent.instruction
        except Exception as e:
            logger.warning(
                f"Instruction formatting failed: {e}, using original instruction"
            )
            formatted_prompt = agent.instruction

        formatted_prompt = f"<instructions>\n{formatted_prompt}\n</instructions>\n\n"

        # Note: {_system_data} will be replaced dynamically in the callback
        # We use a placeholder that will be replaced with actual values
        # System-data will be added dynamically in the callback
        # We'll add it as a placeholder that gets replaced
        formatted_prompt = (
            formatted_prompt
            + "<system-data>\n{_system_data}\n</system-data>\n\n"
        )

        # Add agent configuration (timezone and use_emojis) to the prompt
        # Note: send_as_reply is handled at the Rails level, not in the prompt
        agent_config_sections = []
        
        # Add timezone if configured
        timezone = agent.config.get("timezone")
        if timezone:
            agent_config_sections.append(
                f"Agent Timezone: {timezone}. Use this timezone when referencing dates, times, scheduling appointments, or setting reminders. All time-related information should be interpreted and expressed according to this timezone."
            )
        
        # Add use_emojis instruction if enabled
        use_emojis = agent.config.get("use_emojis")
        if use_emojis:
            agent_config_sections.append(
                "Use emojis in your responses to make communication more friendly and engaging. Incorporate appropriate emojis naturally throughout your messages."
            )
        
        # Add CRM tools instructions if any CRM tools are enabled
        crm_tools_instructions = []
        
        # Check which CRM tools are available
        transfer_to_human_enabled = agent.config.get("transfer_to_human_enabled", False) or agent.config.get("transfer_to_human", False)
        allow_reminders = agent.config.get("allow_reminders", False)
        allow_contact_edit = agent.config.get("allow_contact_edit", False)
        allow_pipeline_manipulation = agent.config.get("allow_pipeline_manipulation", False)
        allow_manage_labels = agent.config.get("allow_manage_labels", False)
        allow_product_sales = agent.config.get("allow_product_sales", False)

        if transfer_to_human_enabled:
            transfer_rules = agent.config.get("transfer_rules", [])
            if transfer_rules:
                rules_text = []
                for rule in transfer_rules:
                    if rule.get("transferTo") == "human" and rule.get("userId"):
                        user_name = rule.get("userName", "agent")
                        instructions = rule.get("instructions", "")
                        rules_text.append(f"- Transfer to human ({user_name})" + (f": {instructions}" if instructions else ""))
                    elif rule.get("transferTo") == "team" and rule.get("teamId"):
                        team_name = rule.get("teamName", "team")
                        instructions = rule.get("instructions", "")
                        rules_text.append(f"- Transfer to team ({team_name})" + (f": {instructions}" if instructions else ""))
                
                if rules_text:
                    crm_tools_instructions.append(
                        f"Transfer to Human Tool: Available. Use this tool when the user requests human assistance or when escalation is needed. "
                        f"Transfer rules configured: {'; '.join(rules_text)}. "
                        f"The tool will automatically use the configured transfer rules, so you don't need to specify assignee_id or team_id unless overriding the rules."
                    )
            else:
                crm_tools_instructions.append(
                    "Transfer to Human Tool: Available. Use this tool when the user requests human assistance or when escalation is needed. "
                    "You must provide assignee_id or team_id when using this tool."
                )
        
        if allow_reminders:
            crm_tools_instructions.append(
                "Send Private Message Tool: Available. Use this tool to create private reminders or internal notes that are only visible to agents, not to customers. "
                "Use this when the user asks to set a reminder, create an internal note, or when you need to leave private context for other agents."
            )
        
        if allow_contact_edit:
            contact_edit_config = agent.config.get("contact_edit_config", {})
            editable_fields = contact_edit_config.get("editableFields", [])
            edit_instructions = contact_edit_config.get("instructions", "")

            fields_text = ", ".join(editable_fields) if editable_fields else "various fields"
            instructions_text = f" {edit_instructions}" if edit_instructions else ""

            crm_tools_instructions.append(
                f"Update Contact Tool: Available. Use this tool to update contact information when the user requests changes to their data. "
                f"You can edit the following fields: {fields_text}.{instructions_text} "
                f"The contact_id will be automatically extracted from the conversation context, so you don't need to provide it explicitly. "
                f"Simply call the tool with the fields you want to update (e.g., name, email, phone_number, etc.)."
            )

        if allow_pipeline_manipulation:
            pipeline_rules = agent.config.get("pipeline_rules", [])
            rules_text = (
                _format_pipeline_rules_for_prompt(pipeline_rules)
                if isinstance(pipeline_rules, list)
                else []
            )
            # Rules that render to nothing take the generic text: telling the
            # model "no rule matches" under an empty list disables the tool.
            if rules_text:
                crm_tools_instructions.append(_pipeline_tool_instruction(rules_text))
            else:
                crm_tools_instructions.append(
                    "Pipeline Manipulation Tool: Available. Use this tool to assign the current conversation to a pipeline or move it between stages when the conversation reaches a state that warrants it (e.g., qualified lead, sale closed, follow-up needed). "
                    "Use action=\"move_to_stage\" for a conversation that already has a card in the pipeline; use action=\"add_to_pipeline\" only for one that is not in any pipeline yet. "
                    "Do NOT set conversation_id or contact_id — the conversation context supplies them and overrides anything you pass. Provide the target pipeline_id and stage_id (or stage_name)."
                )

        if allow_manage_labels:
            crm_tools_instructions.append(
                "Manage Conversation Labels Tool: Available. Use this tool to tag the current conversation with short, lower-case labels (e.g. \"vip\", \"awaiting-payment\", \"followup\") so it can be filtered and routed in the CRM. "
                "Actions: action=\"list\" returns the current labels; action=\"add\" appends one or more labels preserving the existing ones; action=\"remove\" removes specific labels. "
                "Always prefer calling action=\"list\" first when you are unsure which labels are already attached, then decide whether to add or remove. "
                "Only manage labels when the user's request, the conversation state or your routing rules clearly justify it — do not invent random tags."
            )

        if allow_product_sales:
            crm_tools_instructions.append(
                "Link Product to Pipeline Item Tool: Available. Use this tool to record a sale on the current pipeline card when the user has confirmed they want to purchase one of the products listed in the <product-catalog> block. "
                "Required: product_id (the UUID from the catalog) and quantity (positive integer). Optional: product_variant_id (size/color) and notes. "
                "The pipeline_item_id is auto-extracted from context. The CRM snapshots the unit price at the moment of the call, so calling this prematurely (before purchase intent is confirmed) commits the sale incorrectly. "
                "Do NOT call this tool just because the user asked about a product — only call it when the purchase intent is explicit."
            )

        # Build a <product-catalog> block from the products attached to this agent.
        # The CRM populates `assigned_products` in agent.config via the
        # Ai::AgentProductSyncService whenever the user attaches/detaches a
        # product on the "Products" tab of the agent editor. We cap the list
        # at MAX_PRODUCTS_PER_PROMPT so we don't blow up the context window
        # on large catalogs (RAG / search tool is the path forward there).
        assigned_products = agent.config.get("assigned_products") or []
        max_products = int(os.getenv("MAX_PRODUCTS_PER_PROMPT", "50"))
        if isinstance(assigned_products, list) and assigned_products:
            truncated = False
            if len(assigned_products) > max_products:
                logger.warning(
                    f"product catalog truncated: {len(assigned_products)} -> {max_products}"
                )
                assigned_products = assigned_products[:max_products]
                truncated = True

            lines = []
            for product in assigned_products:
                if not isinstance(product, dict):
                    continue
                kind = product.get("kind") or "physical"
                name = product.get("name") or product.get("id") or "unknown"
                price = product.get("default_price")
                currency = product.get("currency") or "BRL"
                url = product.get("purchase_url") or ""
                description = (product.get("description") or "").strip()
                if len(description) > 200:
                    description = description[:200].rstrip() + "..."

                price_str = ""
                if price is not None:
                    try:
                        price_str = f"{currency} {float(price):.2f}"
                    except (TypeError, ValueError):
                        price_str = f"{currency} {price}"

                pieces = [f"[{kind}] {name}"]
                if price_str:
                    pieces.append(price_str)
                if url:
                    pieces.append(url)
                if description:
                    pieces.append(description)
                lines.append("- " + " — ".join(pieces))

            header = (
                "You can recommend the following catalog products during this conversation. "
                "Always cite the exact name and purchase link as listed below. "
                "Do not invent products that are not in this list."
            )
            footer = (
                "\n(Catalog truncated to the first {max} entries.)".format(max=max_products)
                if truncated else ""
            )
            agent_config_sections.append(
                "<product-catalog>\n"
                + header
                + "\n\n"
                + "\n".join(lines)
                + footer
                + "\n</product-catalog>"
            )

        # Check if Google Calendar integration is enabled
        integrations = agent.config.get("integrations", {})
        google_calendar_config = integrations.get("google-calendar") or integrations.get("google_calendar")

        if google_calendar_config and google_calendar_config.get("connected"):
            # Build instructions based on calendar settings
            calendar_settings = google_calendar_config.get("settings", {})

            calendar_instructions = []
            calendar_instructions.append(
                "Google Calendar Tools: Available for checking availability and creating calendar events."
            )

            # Add business hours info if configured
            business_hours = calendar_settings.get("businessHours", {})
            if business_hours and business_hours.get("enabled"):
                enabled_days = []
                for day in ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]:
                    day_config = business_hours.get(day, {})
                    if day_config.get("enabled"):
                        start = day_config.get("start", "09:00")
                        end = day_config.get("end", "18:00")
                        enabled_days.append(f"{day.capitalize()}: {start}-{end}")

                if enabled_days:
                    calendar_instructions.append(
                        f"Scheduling is restricted to business hours: {', '.join(enabled_days)}."
                    )

            # Add advance time restriction
            min_advance = calendar_settings.get("minAdvanceTime", {})
            if min_advance and min_advance.get("enabled"):
                value = min_advance.get("value", 1)
                unit = min_advance.get("unit", "hours")
                calendar_instructions.append(
                    f"Minimum advance time for scheduling: {value} {unit}."
                )

            # Add duration limit
            max_duration = calendar_settings.get("maxDuration", {})
            if max_duration:
                value = max_duration.get("value", 1)
                unit = max_duration.get("unit", "hours")
                calendar_instructions.append(
                    f"Maximum event duration: {value} {unit}."
                )

            # Add Google Meet info
            if calendar_settings.get("meetIntegration"):
                calendar_instructions.append(
                    "Events can include Google Meet links automatically."
                )

            # Add tool usage instructions
            calendar_instructions.append(
                "Use check_calendar_availability to find available time slots, "
                "and create_calendar_event to schedule meetings. All restrictions are "
                "enforced automatically by the tools."
            )

            crm_tools_instructions.append("\n".join(calendar_instructions))

        if crm_tools_instructions:
            agent_config_sections.append(
                "<available-tools>\n" + "\n\n".join(crm_tools_instructions) + "\n</available-tools>"
            )

        # Add agent configuration section if any configs are present
        if agent_config_sections:
            config_text = "\n".join(agent_config_sections)
            formatted_prompt = (
                formatted_prompt
                + f"<agent-configuration>\n{config_text}\n</agent-configuration>\n\n"
            )

        # add role on beginning of the prompt
        if agent.role:
            formatted_prompt = (
                f"<agent_role>{agent.role}</agent_role>\n\n{formatted_prompt}"
            )

        # add goal on beginning of the prompt
        if agent.goal:
            formatted_prompt = (
                f"<agent_goal>{agent.goal}</agent_goal>\n\n{formatted_prompt}"
            )

        # Check if load_memory is enabled
        if agent.config.get("load_memory"):
            from src.services.adk.tools.compress_memory_tool import (
                create_compress_memory_tool,
            )
            
            memory_tools = []
            memory_base_config_id = agent.config.get("memory_base_config_id")
            
            # Note: preload_memory is handled automatically in the runner, not as a tool
            # The runner will automatically load memory summaries when preload_memory is enabled
            
            # Always add load_memory_tool when load_memory is enabled
            memory_tools.append(load_memory_tool)
            logger.debug(
                f"Memory tools enabled for agent {agent.name}: load_memory"
                + (" (preload_memory will be handled automatically by runner)" if agent.config.get("preload_memory") else "")
            )
            
            # Add compress memory tool
            compress_memory_tool = await create_compress_memory_tool(
                memory_base_config_id=str(memory_base_config_id) if memory_base_config_id else None,
            )
            memory_tools.append(compress_memory_tool)
            logger.debug(
                f"Memory compression tool enabled for agent {agent.name}"
            )

            all_tools.extend(memory_tools)
        elif agent.config.get("preload_memory"):
            # Log warning if preload_memory is enabled without load_memory
            logger.warning(
                f"Agent {agent.name} has preload_memory enabled but load_memory is disabled. preload_memory requires load_memory to be enabled."
            )

        # Get API key (and provider, when stored) from api_key_id
        api_key, api_key_provider = await get_api_key(self.db, agent)

        # Get output_key from config if specified
        output_key = agent.config.get("output_key") if agent.config else None

        #all_tools.append(load_artifacts)

        logger.info(f"All tools loaded: {len(all_tools)}")

        # Create callbacks
        timezone_str = agent.config.get("timezone")
        update_time_callback = create_update_current_time_callback(timezone_str)
        update_contact_callback = create_update_contact_info_callback()
        
        # Combine callbacks
        async def combined_callback(callback_context: CallbackContext):
            """Combined callback that updates both time and contact info."""
            await update_time_callback(callback_context)
            await update_contact_callback(callback_context)
            
            # Format datetime for display in system-data
            current_datetime = callback_context.state.get("_datetime", "")
            contact_info = callback_context.state.get("contact_info", "")
            
            if current_datetime:
                try:
                    from datetime import datetime
                    dt = datetime.fromisoformat(current_datetime.replace('Z', '+00:00'))
                    # ISO 8601 + weekday so the LLM never confuses day/month order.
                    formatted_datetime = dt.strftime("%Y-%m-%d %H:%M (%A)")
                except:
                    formatted_datetime = current_datetime
            else:
                formatted_datetime = "N/A"
            
            # Build system-data content
            system_data = f"Current datetime: {formatted_datetime}"
            if contact_info:
                system_data += f"\n{contact_info}"
            
            # Store in state
            callback_context.state["_system_data"] = system_data
            
            # Try to replace placeholder in agent instruction dynamically
            # The ADK doesn't automatically replace placeholders, so we need to do it manually
            try:
                # Check if we can access and modify the agent's instruction
                if hasattr(callback_context, 'agent') and callback_context.agent:
                    agent_obj = callback_context.agent
                    logger.debug(f"[ContactInfo] Agent object type: {type(agent_obj)}")
                    logger.debug(f"[ContactInfo] Agent object attributes: {dir(agent_obj)}")
                    
                    # Try multiple ways to access and modify instruction
                    agent_instruction = None
                    
                    # Method 1: Try direct attribute access
                    if hasattr(agent_obj, 'instruction'):
                        agent_instruction = getattr(agent_obj, 'instruction', None)
                        logger.debug(f"[ContactInfo] Found instruction via hasattr: {type(agent_instruction)}, length: {len(agent_instruction) if isinstance(agent_instruction, str) else 'N/A'}")
                    
                    # Method 2: Try __dict__ access
                    if not agent_instruction and hasattr(agent_obj, '__dict__'):
                        agent_dict = agent_obj.__dict__
                        if 'instruction' in agent_dict:
                            agent_instruction = agent_dict['instruction']
                            logger.debug(f"[ContactInfo] Found instruction via __dict__: {type(agent_instruction)}")
                    
                    if agent_instruction and isinstance(agent_instruction, str) and "{_system_data}" in agent_instruction:
                        # Replace the placeholder with actual system data
                        updated_instruction = agent_instruction.replace("{_system_data}", system_data)
                        logger.info(f"[ContactInfo] Replacing placeholder in instruction (before: {len(agent_instruction)} chars, after: {len(updated_instruction)} chars)")
                        
                        # Try to update the instruction using multiple methods
                        updated = False
                        
                        # Method 1: Try setattr
                        try:
                            setattr(agent_obj, 'instruction', updated_instruction)
                            # Verify it was set
                            if getattr(agent_obj, 'instruction', None) == updated_instruction:
                                updated = True
                                logger.info(f"[ContactInfo] ✅ Updated agent instruction via setattr")
                        except Exception as setattr_error:
                            logger.debug(f"[ContactInfo] setattr failed: {setattr_error}")
                        
                        # Method 2: Try __dict__ modification
                        if not updated and hasattr(agent_obj, '__dict__'):
                            try:
                                agent_obj.__dict__['instruction'] = updated_instruction
                                updated = True
                                logger.info(f"[ContactInfo] ✅ Updated agent instruction via __dict__")
                            except Exception as dict_error:
                                logger.debug(f"[ContactInfo] __dict__ update failed: {dict_error}")
                        
                        if not updated:
                            logger.warning("[ContactInfo] ⚠️ Could not update agent instruction - instruction may be read-only")
                            logger.info(f"[ContactInfo] System data that should be in prompt ({len(system_data)} chars): {system_data[:300]}...")
                    elif agent_instruction:
                        logger.debug(f"[ContactInfo] Instruction found but no placeholder '{_system_data}' present")
                        logger.debug(f"[ContactInfo] Instruction preview: {agent_instruction[:200]}...")
                    else:
                        logger.debug("[ContactInfo] No instruction found in agent object")
                else:
                    logger.debug("[ContactInfo] No agent found in callback context")
                    logger.debug(f"[ContactInfo] Callback context attributes: {dir(callback_context) if hasattr(callback_context, '__dict__') else 'N/A'}")
            except Exception as e:
                logger.error(f"[ContactInfo] ❌ Error trying to update agent instruction: {e}")
                import traceback
                logger.error(f"[ContactInfo] Traceback: {traceback.format_exc()}")
                # Fallback: log the system data so we can debug
                logger.info(f"[ContactInfo] System data that should be in prompt ({len(system_data)} chars): {system_data[:300]}...")
        
        # Log tool details before passing to agent
        logger.info(
            f"Preparing to create LlmAgent with {len(all_tools)} tools. "
            f"Tool breakdown: custom={len(custom_tools)}, mcp={len(mcp_tools)}, agent={len(agent_tools)}"
        )
        if mcp_tools:
            logger.info(
                f"MCP tools sample (first 5): {[{'name': t.name, 'type': type(t).__name__, 'has_to_function_declaration': hasattr(t, 'to_function_declaration')} for t in mcp_tools[:5]]}"
            )
            # Test if to_function_declaration works for first MCP tool
            if len(mcp_tools) > 0:
                try:
                    first_tool = mcp_tools[0]
                    if hasattr(first_tool, 'to_function_declaration'):
                        test_declaration = first_tool.to_function_declaration()
                        logger.info(
                            f"✅ Test: to_function_declaration() works for {first_tool.name}. "
                            f"Declaration: name={test_declaration.name}, description={len(test_declaration.description or '')} chars"
                        )
                    else:
                        logger.warning(f"⚠️ Tool {first_tool.name} does not have to_function_declaration method")
                except Exception as e:
                    logger.error(f"❌ Error calling to_function_declaration() on {mcp_tools[0].name}: {e}")
        
        # Normalize model for provider routing (EVO-1684: OpenRouter keys must
        # use the `openrouter/` prefix or LiteLLM routes to the wrong vendor).
        litellm_model, litellm_extra_kwargs = normalize_model_for_provider(
            agent.model, api_key_provider
        )

        llm_agent_kwargs = {
            "name": agent.name,
            "model": LiteLlm(
                model=litellm_model, api_key=api_key, **litellm_extra_kwargs
            ),
            "instruction": formatted_prompt,
            "description": agent.description,
            "tools": all_tools,
            "before_agent_callback": combined_callback,
            # "after_model_callback": advanced_usage_tracker,
        }

        if (
            agent.model == "gemini/gemini-2.0-flash-exp"
            or agent.model == "gemini/gemini-2.0-flash-live-001"
            or agent.model == "gemini/gemini-2.5-flash-preview-native-audio-dialog"
            or agent.model == "gemini/gemini-2.5-flash-exp-native-audio-thinking-dialog"
        ):
            model_name = agent.model.replace("gemini/", "")
            llm_agent_kwargs["model"] = GeminiWithApiKey(
                model=model_name, api_key=api_key
            )

        # Add planner if enabled in config
        if agent.config.get("planner"):
            llm_agent_kwargs["planner"] = PlanReActPlanner()
            logger.debug(f"PlanReActPlanner enabled for agent {agent.name}")

        # Add output_schema if specified
        if agent.config.get("output_schema"):
            output_schema_dict = agent.config.get("output_schema")
            if validate_output_schema(output_schema_dict):
                dynamic_schema = json_schema_to_pydantic(
                    output_schema_dict, f"{agent.name.replace(' ', '_')}_OutputSchema"
                )
                if dynamic_schema:
                    logger.debug(
                        f"Output schema enabled for agent {agent.name} with fields: {list(output_schema_dict.keys())}"
                    )

                    prompt_instructions_by_schema = f"""
                    <output_schema>
                    <instructions>
                    ALWAYS use output_schema to generate the output, I only return the json with the output_schema.
                    </instructions>
                    {dynamic_schema.model_json_schema()}
                    </output_schema>
                    """
                    formatted_prompt = formatted_prompt + prompt_instructions_by_schema

                    llm_agent_kwargs["instruction"] = formatted_prompt
                else:
                    logger.warning(
                        f"Failed to create output schema for agent {agent.name}"
                    )
            else:
                logger.warning(f"Invalid output schema for agent {agent.name}")

        # Add output_key if specified
        if output_key:
            llm_agent_kwargs["output_key"] = output_key
            logger.debug(f"Agent {agent.name} will write to state key: {output_key}")

        return LlmAgent(**llm_agent_kwargs), state_params

    async def build_llm_agent(
        self,
        root_agent: Agent,
        processed_agents: set = None,
        enabled_tools: List[str] = [],
    ) -> Tuple[LlmAgent, Optional[List[str]]]:
        """Build an LLM agent with its sub-agents."""
        logger.debug("Creating LLM agent")

        sub_agents = []
        if root_agent.config.get("sub_agents"):
            # Import here to avoid circular import
            sub_agents, state_params = await get_sub_agents(
                self.db,
                root_agent.config.get("sub_agents"),
                root_agent.type,  # parent_type
                root_agent.config,  # parent_config
                processed_agents=processed_agents,
            )
            # Add after_model_callback to each sub agent with escalate_after
            # for sub_agent in sub_agents:
            #     sub_agent.after_model_callback = self.escalate_after

        root_llm_agent, state_params = await self._create_llm_agent(
            root_agent, processed_agents, enabled_tools
        )
        if sub_agents:
            root_llm_agent.sub_agents = sub_agents

        return root_llm_agent, state_params
