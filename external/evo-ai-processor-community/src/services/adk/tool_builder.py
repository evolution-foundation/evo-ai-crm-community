"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: custom_tools.py                                                       │
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

from typing import Any, Container, Dict, List
from google.adk.tools import FunctionTool
import requests
import json
import urllib.parse
from src.utils.logger import setup_logger
from src.utils.tool_naming import sanitize_tool_name, unique_tool_name
from src.services.adk.custom_tools import (
    CustomToolBuilder,
    declare_body_params,
    normalize_body_param,
    strip_modes_meta,
)
from src.services.adk.tools import exit_loop
from src.services.adk.tools import create_text_to_speech_tool

logger = setup_logger(__name__)




def _nexus_credential_ref(config):
    """Adapts the Nexus dialog's scalar credential_id to the map shape the tool
    and MCP paths use."""
    credential_id = config.get("credential_id")
    return {"nexus_api_key": credential_id} if credential_id else {}

def _apply_vault_refs(tool_config, headers, _db=None):
    """Resolves headers that point at the credential vault.

    Opens its own short-lived session because neither tool builder carries one.
    Any failure falls back to the inline headers, so a vault outage degrades to
    today's behaviour instead of breaking the tool.
    """
    credential_refs = tool_config.get("credential_refs") or {}
    if not credential_refs:
        return headers

    from src.config.database import SessionLocal
    from src.services.adk.integration_credentials import (
        DatabaseCredentialVault,
        resolve_credential_refs,
    )
    from src.utils.crypto import decrypt_api_key

    session = SessionLocal()
    try:
        return resolve_credential_refs(
            headers,
            credential_refs,
            vault=DatabaseCredentialVault(session),
            decrypt=decrypt_api_key,
        )
    finally:
        session.close()

class ToolBuilder:
    def __init__(self):
        self.tools = []

    def _create_http_tool(
        self, tool_config: Dict[str, Any], taken_names: Container[str] = ()
    ) -> FunctionTool:
        """Create an HTTP tool based on the provided configuration.

        `taken_names` are the function names already registered on this agent, so
        two tools never answer to the same one.
        """
        name = tool_config["name"]
        description = tool_config["description"]
        endpoint = tool_config["endpoint"]
        method = tool_config["method"]
        headers = tool_config.get("headers", {})
        # Second header-injection path: hardening only one of the two would
        # leave the other echoing inline secrets.
        headers = _apply_vault_refs(tool_config, headers)
        parameters = tool_config.get("parameters", {}) or {}
        values = strip_modes_meta(tool_config.get("values"))
        error_handling = tool_config.get("error_handling", {})

        path_params = parameters.get("path_params") or {}
        query_params = parameters.get("query_params") or {}
        body_params = parameters.get("body_params") or {}

        def http_tool(**kwargs):
            try:
                # Combines default values with provided values
                all_values = {**values, **kwargs}

                # Substitutes placeholders in headers
                processed_headers = {
                    k: v.format(**all_values) if isinstance(v, str) else v
                    for k, v in headers.items()
                }

                # Processes path parameters
                url = endpoint
                for param, value in path_params.items():
                    if param in all_values:
                        # URL encode the value for URL safe characters
                        replacement_value = urllib.parse.quote(
                            str(all_values[param]), safe=""
                        )
                        url = url.replace(f"{{{param}}}", replacement_value)

                # Process query parameters
                query_params_dict = {}
                for param, value in query_params.items():
                    if isinstance(value, list):
                        # If the value is a list, join with comma
                        query_params_dict[param] = ",".join(value)
                    elif param in all_values:
                        # If the parameter is in the values, use the provided value
                        query_params_dict[param] = all_values[param]
                    else:
                        # Otherwise, use the default value from the configuration
                        query_params_dict[param] = value

                # Adds default values to query params if they are not present
                for param, value in values.items():
                    if param not in query_params_dict and param not in path_params:
                        query_params_dict[param] = value

                # Check body type from parameters
                body_type = parameters.get("body_type", "object")
                array_param = parameters.get("array_param")

                if body_type == "array" and array_param:
                    # Array-based body
                    if array_param in all_values:
                        # Ensure the value is a list/array
                        array_value = all_values[array_param]
                        if isinstance(array_value, str):
                            # If it's a string, try to parse as JSON array or split by comma
                            try:
                                array_value = json.loads(array_value)
                            except (json.JSONDecodeError, ValueError):
                                # Fallback: split by comma and strip whitespace
                                array_value = [
                                    item.strip() for item in array_value.split(",")
                                ]
                        elif not isinstance(array_value, list):
                            # Convert single value to list
                            array_value = [array_value]

                        request_body = array_value
                    else:
                        # No array parameter provided, send empty array
                        request_body = []

                    # Makes the HTTP request with array body
                    response = requests.request(
                        method=method,
                        url=url,
                        headers=processed_headers,
                        params=query_params_dict,
                        json=request_body,
                        timeout=error_handling.get("timeout", 30),
                    )
                else:
                    # Object-based body (existing behavior)
                    body_data = {}
                    for param, param_config in body_params.items():
                        if param in all_values:
                            body_data[param] = all_values[param]

                    # Adds default values to body if they are not present
                    for param, value in values.items():
                        if (
                            param not in body_data
                            and param not in query_params_dict
                            and param not in path_params
                        ):
                            body_data[param] = value

                    # Makes the HTTP request with object body
                    response = requests.request(
                        method=method,
                        url=url,
                        headers=processed_headers,
                        params=query_params_dict,
                        json=body_data if body_data else None,
                        timeout=error_handling.get("timeout", 30),
                    )

                if response.status_code >= 400:
                    raise requests.exceptions.HTTPError(
                        f"Error in the request: {response.status_code} - {response.text}"
                    )

                # Try to parse the response as JSON, if it fails, return the text content
                try:
                    return json.dumps(response.json())
                except ValueError:
                    # Response is not JSON, return the text content
                    return json.dumps({"content": response.text})

            except Exception as e:
                logger.error(f"Error executing tool {name}: {str(e)}")
                return json.dumps(
                    error_handling.get(
                        "fallback_response",
                        {"error": "tool_execution_error", "message": str(e)},
                    )
                )

        # Adds dynamic docstring based on the configuration
        param_docs = []

        # Adds path parameters
        for param, value in path_params.items():
            param_docs.append(f"{param}: {value}")

        # Adds query parameters
        for param, value in query_params.items():
            if isinstance(value, list):
                param_docs.append(f"{param}: List[{', '.join(value)}]")
            else:
                param_docs.append(f"{param}: {value}")

        # Adds body parameters
        for param, param_config in body_params.items():
            schema = normalize_body_param(param_config)
            required = "Required" if schema["required"] else "Optional"
            param_docs.append(
                f"{param} ({schema['type']}, {required}): {schema['description']}"
            )

        # Adds default values
        if values:
            param_docs.append("\nDefault values:")
            for param, value in values.items():
                param_docs.append(f"{param}: {value}")

        http_tool.__doc__ = f"""
        {description}

        Parameters:
        {chr(10).join(param_docs)}

        Returns:
        String containing the response in JSON format
        """

        # The name the ADK dispatches by, coerced to what the providers accept
        # (a space/accent in it breaks the whole turn). It has to be set before
        # FunctionTool reads it — the tool answers to the name captured there.
        http_tool.__name__ = unique_tool_name(name, taken_names)
        if http_tool.__name__ != name:
            logger.info(
                f"Custom tool '{name}' is exposed to the LLM as '{http_tool.__name__}'"
            )

        declare_body_params(http_tool, body_params)

        return FunctionTool(func=http_tool)

    def _create_exit_loop_tool(self) -> FunctionTool:
        """Create the exit_loop tool for LoopAgent."""
        return FunctionTool(func=exit_loop)

    def build_tools(
        self, agent_config: Dict[str, Any], db=None, agent_id=None
    ) -> List[FunctionTool]:
        """Builds a list of tools based on the provided configuration.

        Now supports both native tools and custom tools from database.
        Accepts both 'tools' and 'custom_tools' (with http_tools), plus 'custom_tool_ids'.
        """
        self.tools = []

        # First, process custom_tool_ids using CustomToolBuilder. It is handed the
        # IDs only: the http_tools below are the same tools expanded from those very
        # IDs (by get_agent, or by the core service when it saves the agent), so
        # letting CustomToolBuilder see them too would build each tool twice.
        built_from_ids = set()
        if agent_config.get("custom_tool_ids") and db:
            custom_tool_builder = CustomToolBuilder()
            custom_tools_from_ids = custom_tool_builder.build_tools(
                {"custom_tool_ids": agent_config["custom_tool_ids"]}, db
            )
            self.tools.extend(custom_tools_from_ids)
            built_from_ids = {tool.func.__name__ for tool in custom_tools_from_ids}
            logger.info(
                f"Added {len(custom_tools_from_ids)} tools from custom_tool_ids"
            )

        # Then process direct http_tools configurations
        http_tools = []
        if agent_config.get("http_tools"):
            http_tools = agent_config.get("http_tools", [])
        elif agent_config.get("custom_tools") and agent_config["custom_tools"].get(
            "http_tools"
        ):
            http_tools = agent_config["custom_tools"].get("http_tools", [])
        elif (
            agent_config.get("tools")
            and isinstance(agent_config["tools"], dict)
            and agent_config["tools"].get("http_tools")
        ):
            http_tools = agent_config["tools"].get("http_tools", [])

        taken_names = set(built_from_ids)
        for http_tool_config in http_tools:
            # An http_tool that carries the name of a tool already built from its ID
            # is that same tool, expanded into the config. The ID is the fresher
            # source — the expanded copy can be a stale snapshot — so skip it. The
            # comparison is on the sanitized name: that is the one the tool built
            # from the id ended up answering to.
            expanded_name = http_tool_config.get("name")
            if expanded_name and sanitize_tool_name(expanded_name) in built_from_ids:
                logger.debug(
                    f"Skipping http_tool '{expanded_name}': "
                    "already built from custom_tool_ids"
                )
                continue
            http_tool = self._create_http_tool(http_tool_config, taken_names)
            taken_names.add(http_tool.func.__name__)
            self.tools.append(http_tool)

        # Add exit_loop tool if specified in configuration
        if agent_config.get("enable_exit_loop", False):
            self.tools.append(self._create_exit_loop_tool())

        # Process CRM tools if enabled
        # Enable CRM tools if transfer_to_human, allow_reminders, allow_contact_edit, allow_pipeline_manipulation
        # or allow_manage_labels is enabled
        transfer_to_human_enabled = agent_config.get("transfer_to_human_enabled", False) or agent_config.get("transfer_to_human", False)
        allow_reminders = agent_config.get("allow_reminders", False)
        allow_contact_edit = agent_config.get("allow_contact_edit", False)
        allow_pipeline_manipulation = agent_config.get("allow_pipeline_manipulation", False)
        allow_manage_labels = agent_config.get("allow_manage_labels", False)
        allow_product_sales = agent_config.get("allow_product_sales", False)
        enable_crm_tools = (
            agent_config.get("enable_crm_tools", False)
            or transfer_to_human_enabled
            or allow_reminders
            or allow_contact_edit
            or allow_pipeline_manipulation
            or allow_manage_labels
            or allow_product_sales
        )

        if enable_crm_tools:
            from src.services.adk.tools.evo_crm import (
                create_transfer_to_human_tool,
                create_send_private_message_tool,
                create_update_contact_tool,
                create_pipeline_manipulation_tool,
                create_manage_conversation_labels_tool,
                create_link_product_to_pipeline_item_tool,
            )

            try:
                # Add transfer_to_human tool if enabled
                if transfer_to_human_enabled:
                    # Get transfer_rules from agent config
                    transfer_rules = agent_config.get("transfer_rules", [])
                    transfer_tool = create_transfer_to_human_tool(
                        transfer_rules=transfer_rules if isinstance(transfer_rules, list) else []
                    )
                    self.tools.append(transfer_tool)
                    logger.info(
                        f"Added transfer_to_human tool from CRM tools"
                        + (f" with {len(transfer_rules)} transfer rules" if transfer_rules else "")
                    )

                # Add send_private_message tool if reminders are enabled
                if allow_reminders:
                    private_message_tool = create_send_private_message_tool()
                    self.tools.append(private_message_tool)
                    logger.info(
                        f"Added send_private_message tool from CRM tools (reminders enabled)"
                    )

                # Add update_contact tool if enabled
                if allow_contact_edit:
                    update_contact_tool = create_update_contact_tool()
                    self.tools.append(update_contact_tool)
                    logger.info(
                        f"Added update_contact tool from CRM tools"
                    )

                # Add pipeline_manipulation tool if enabled
                if allow_pipeline_manipulation:
                    # Get pipeline_rules from agent config
                    pipeline_rules = agent_config.get("pipeline_rules", [])
                    pipeline_tool = create_pipeline_manipulation_tool(
                        pipeline_rules=pipeline_rules if isinstance(pipeline_rules, list) else []
                    )
                    self.tools.append(pipeline_tool)
                    logger.info(
                        f"Added pipeline_manipulation tool from CRM tools"
                        + (f" with {len(pipeline_rules)} pipeline rules" if pipeline_rules else "")
                    )

                # Add manage_conversation_labels tool if enabled
                if allow_manage_labels:
                    labels_tool = create_manage_conversation_labels_tool()
                    self.tools.append(labels_tool)
                    logger.info(
                        f"Added manage_conversation_labels tool from CRM tools"
                    )

                # Add link_product_to_pipeline_item tool if enabled
                if allow_product_sales:
                    product_link_tool = create_link_product_to_pipeline_item_tool()
                    self.tools.append(product_link_tool)
                    logger.info(
                        f"Added link_product_to_pipeline_item tool from CRM tools"
                    )

            except Exception as e:
                logger.error(f"Error loading CRM tools: {e}")

        # Process ElevenLabs integration (text_to_speech)
        integrations = agent_config.get("integrations", {})
        elevenlabs_config = integrations.get("elevenlabs")

        if elevenlabs_config and elevenlabs_config.get("apiKey"):
            try:
                # Convert frontend config to tool format
                # Stability and similarity come as 0-100 from frontend, need to convert to 0.0-1.0
                stability = elevenlabs_config.get("stability", 80) / 100.0
                similarity_boost = elevenlabs_config.get("similarity", 50) / 100.0

                # Get voice ID directly from config (now stores actual ElevenLabs voice_id)
                voice_id = elevenlabs_config.get("voice")

                if not voice_id:
                    logger.warning("No voice_id specified in ElevenLabs config, skipping text_to_speech tool creation")
                else:
                    # Create the text_to_speech tool
                    self.tools.append(
                        create_text_to_speech_tool(
                            eleven_labs_token=elevenlabs_config["apiKey"],
                            voice_id=voice_id,
                            model_id="eleven_multilingual_v2",  # Default model for best quality
                            stability=stability,
                            similarity_boost=similarity_boost,
                            style=0.0,  # Default style
                            use_speaker_boost=True,  # Enable speaker boost for better quality
                        )
                    )
                    logger.info(
                        f"Added text_to_speech tool from ElevenLabs integration "
                        f"(voice_id: {voice_id}, stability: {stability:.2f}, similarity: {similarity_boost:.2f})"
                    )
            except Exception as e:
                logger.error(f"Error creating text_to_speech tool from ElevenLabs integration: {e}")

        # Process Knowledge Nexus integration (knowledge_nexus_search)
        knowledge_nexus_config = integrations.get("knowledge-nexus") or integrations.get("knowledge_nexus")
        if knowledge_nexus_config and knowledge_nexus_config.get("connected"):
            try:
                base_url = (
                    knowledge_nexus_config.get("nexus_base_url")
                    or knowledge_nexus_config.get("baseUrl")
                )
                api_key = (
                    knowledge_nexus_config.get("nexus_api_key")
                    or knowledge_nexus_config.get("apiKey")
                )
                # Only the key goes to the vault: nexus_base_url and space_id
                # are the address, and keeping them out is what lets one
                # credential serve agents pointing at different spaces.
                api_key = _apply_vault_refs(
                    {"credential_refs": _nexus_credential_ref(knowledge_nexus_config)},
                    {"nexus_api_key": api_key},
                ).get("nexus_api_key")
                space_id = (
                    knowledge_nexus_config.get("space_id")
                    or knowledge_nexus_config.get("spaceId")
                )

                missing = [
                    name
                    for name, value in (
                        ("nexus_base_url", base_url),
                        ("nexus_api_key", api_key),
                        ("space_id", space_id),
                    )
                    if not value
                ]

                if missing:
                    logger.warning(
                        "knowledge-nexus integration is connected but missing required fields "
                        f"({', '.join(missing)}) — skipping tool creation."
                    )
                else:
                    from src.services.adk.tools.knowledge_nexus import (
                        create_knowledge_nexus_search_tool,
                    )

                    raw_top_k = knowledge_nexus_config.get("default_top_k", 10)
                    try:
                        default_top_k = int(raw_top_k)
                    except (TypeError, ValueError):
                        logger.warning(
                            f"knowledge-nexus: invalid 'default_top_k' value "
                            f"({raw_top_k!r}), falling back to 10."
                        )
                        default_top_k = 10

                    default_filters = knowledge_nexus_config.get("default_filters") or {}
                    if not isinstance(default_filters, dict):
                        logger.warning(
                            f"knowledge-nexus: 'default_filters' must be an object, got "
                            f"{type(default_filters).__name__} — using empty filters."
                        )
                        default_filters = {}

                    raw_timeout = knowledge_nexus_config.get("timeout_seconds", 15.0)
                    try:
                        timeout_seconds = float(raw_timeout)
                    except (TypeError, ValueError):
                        logger.warning(
                            f"knowledge-nexus: invalid 'timeout_seconds' value "
                            f"({raw_timeout!r}), falling back to 15.0."
                        )
                        timeout_seconds = 15.0

                    self.tools.append(
                        create_knowledge_nexus_search_tool(
                            nexus_base_url=base_url,
                            nexus_api_key=api_key,
                            space_id=space_id,
                            default_top_k=default_top_k,
                            default_filters=default_filters,
                            timeout_seconds=timeout_seconds,
                        )
                    )
                    logger.info(
                        f"Added knowledge_nexus_search tool "
                        f"(space_id={space_id}, top_k={default_top_k}, "
                        f"timeout={timeout_seconds}s)"
                    )
            except Exception as e:
                logger.error(f"Error creating knowledge_nexus_search tool: {e}")

        # Process Google Calendar integration
        logger.debug(f"Checking Google Calendar integration. Integrations keys: {list(integrations.keys()) if integrations else 'None'}")
        google_calendar_config = integrations.get("google-calendar") or integrations.get("google_calendar")
        google_calendar_credentials = integrations.get("google-calendar-credentials") or integrations.get("google_calendar_credentials")
        logger.debug(f"Google Calendar config: {google_calendar_config}")
        logger.debug(f"Google Calendar credentials available: {bool(google_calendar_credentials)}")

        if google_calendar_config and google_calendar_config.get("connected") and google_calendar_credentials:
            try:
                from src.services.adk.tools.google_calendar import (
                    create_check_availability_tool,
                    create_calendar_event_tool,
                    create_cancel_event_tool,
                    create_edit_event_tool,
                )

                # Use agent_id from parameter if available, otherwise try to get from config
                effective_agent_id = agent_id or agent_config.get("id") or agent_config.get("agent_id")

                if not effective_agent_id:
                    logger.warning("Cannot create Google Calendar tools: agent_id not available")
                else:
                    # Add check_availability tool with configs from agent.config.integrations
                    self.tools.append(
                        create_check_availability_tool(
                            agent_id=effective_agent_id,
                            calendar_config=google_calendar_config,
                            credentials_config=google_calendar_credentials,
                            db=db
                        )
                    )

                    # Add create_event tool with configs from agent.config.integrations
                    self.tools.append(
                        create_calendar_event_tool(
                            agent_id=effective_agent_id,
                            calendar_config=google_calendar_config,
                            credentials_config=google_calendar_credentials,
                            db=db
                        )
                    )

                    # Add cancel_event tool with configs from agent.config.integrations
                    self.tools.append(
                        create_cancel_event_tool(
                            agent_id=effective_agent_id,
                            calendar_config=google_calendar_config,
                            credentials_config=google_calendar_credentials,
                            db=db
                        )
                    )

                    # Add edit_event tool with configs from agent.config.integrations
                    self.tools.append(
                        create_edit_event_tool(
                            agent_id=effective_agent_id,
                            calendar_config=google_calendar_config,
                            credentials_config=google_calendar_credentials,
                            db=db
                        )
                    )

                    logger.info(
                        f"Added Google Calendar tools (check_availability, create_event, cancel_event, edit_event) "
                        f"for agent {effective_agent_id}"
                    )
            except Exception as e:
                logger.error(f"Error creating Google Calendar tools: {e}")
        elif google_calendar_config and google_calendar_config.get("connected"):
            logger.warning("Google Calendar integration connected but credentials not available")

        # Process Google Sheets integration
        logger.debug(f"Checking Google Sheets integration. Integrations keys: {list(integrations.keys()) if integrations else 'None'}")
        google_sheets_config = integrations.get("google-sheets") or integrations.get("google_sheets")
        google_sheets_credentials = integrations.get("google-sheets-credentials") or integrations.get("google_sheets_credentials")
        logger.debug(f"Google Sheets config: {google_sheets_config}")
        logger.debug(f"Google Sheets credentials available: {bool(google_sheets_credentials)}")

        if google_sheets_config and google_sheets_config.get("connected") and google_sheets_credentials:
            try:
                from src.services.adk.tools.google_sheets import (
                    create_read_spreadsheet_tool,
                    create_write_spreadsheet_tool,
                    create_append_spreadsheet_tool,
                    create_create_spreadsheet_tool,
                )

                # Use agent_id from parameter if available, otherwise try to get from config
                effective_agent_id = agent_id or agent_config.get("id") or agent_config.get("agent_id")

                if not effective_agent_id:
                    logger.warning("Cannot create Google Sheets tools: agent_id not available")
                else:
                    # Add read_spreadsheet tool
                    self.tools.append(
                        create_read_spreadsheet_tool(
                            agent_id=effective_agent_id,
                            sheets_config=google_sheets_config,
                            credentials_config=google_sheets_credentials,
                            db=db
                        )
                    )

                    # Add write_spreadsheet tool
                    self.tools.append(
                        create_write_spreadsheet_tool(
                            agent_id=effective_agent_id,
                            sheets_config=google_sheets_config,
                            credentials_config=google_sheets_credentials,
                            db=db
                        )
                    )

                    # Add append_spreadsheet tool
                    self.tools.append(
                        create_append_spreadsheet_tool(
                            agent_id=effective_agent_id,
                            sheets_config=google_sheets_config,
                            credentials_config=google_sheets_credentials,
                            db=db
                        )
                    )

                    # Add create_spreadsheet tool
                    self.tools.append(
                        create_create_spreadsheet_tool(
                            agent_id=effective_agent_id,
                            sheets_config=google_sheets_config,
                            credentials_config=google_sheets_credentials,
                            db=db
                        )
                    )

                    logger.info(
                        f"Added Google Sheets tools (read, write, append, create) "
                        f"for agent {effective_agent_id}"
                    )
            except Exception as e:
                logger.error(f"Error creating Google Sheets tools: {e}")
        elif google_sheets_config and google_sheets_config.get("connected"):
            logger.warning("Google Sheets integration connected but credentials not available")

        # Process native tools (text_to_speech)
        # Legacy support for old format
        if agent_config.get("tools"):
            for tool in agent_config["tools"]:
                if tool["name"] == "text_to_speech":
                    # Only add if not already added from integrations
                    if not elevenlabs_config or not elevenlabs_config.get("apiKey"):
                        tool_config = tool.get("config", {})
                        configured_values = tool_config.get("configured_values", {})
                        self.tools.append(
                            create_text_to_speech_tool(
                                configured_values["eleven_labs_token"],
                                configured_values["voice_id"],
                                configured_values["model_id"],
                                configured_values["stability"],
                                configured_values["similarity_boost"],
                                configured_values["style"],
                                configured_values["use_speaker_boost"],
                            )
                        )

        logger.info(f"Built {len(self.tools)} tools total (native + custom)")
        return self.tools
