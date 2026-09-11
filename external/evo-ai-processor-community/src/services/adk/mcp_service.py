"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: mcp_service.py                                                        │
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

import os
import asyncio
from typing import Any, Dict, List, Optional, Tuple
from google.adk.tools.tool_context import ToolContext
from google.adk.tools.mcp_tool.mcp_toolset import MCPToolset
from google.adk.tools.mcp_tool.mcp_session_manager import SseServerParams
from mcp import StdioServerParameters
from contextlib import AsyncExitStack
from src.utils.logger import setup_logger
from src.services.mcp_server_service import get_mcp_server
from sqlalchemy.orm import Session
from src.services.adk.mcp_cache import mcp_tool_cache
from src.services.adk.mcp_context import mcp_context
from src.services.adk.lazy_mcp_tool import LazyMCPTool
from src.config.settings import settings

logger = setup_logger(__name__)


class MCPService:
    def __init__(self):
        self.tools = []
        self.exit_stack = AsyncExitStack()

    def _filter_incompatible_tools(self, tools: List[Any]) -> List[Any]:
        """Filters incompatible tools with the model."""
        problematic_tools = [
            "create_pull_request_review",  # This tool causes the 400 INVALID_ARGUMENT error
        ]

        filtered_tools = []
        removed_count = 0

        for tool in tools:
            if tool.name in problematic_tools:
                logger.warning(f"Removing incompatible tool: {tool.name}")
                removed_count += 1
            else:
                filtered_tools.append(tool)

        if removed_count > 0:
            logger.warning(f"Removed {removed_count} incompatible tools.")

        return filtered_tools

    def _filter_tools_by_agent(
        self, tools: List[Any], agent_tools: List[str]
    ) -> List[Any]:
        """Filters tools compatible with the agent."""
        if not agent_tools or len(agent_tools) == 0:
            return tools

        filtered_tools = []
        for tool in tools:
            logger.info(f"Tool: {tool.name}")
            if tool.name in agent_tools:
                filtered_tools.append(tool)
        return filtered_tools

    async def execute_tool(
        self,
        server_config: Dict[str, Any],
        tool_name: str,
        args: Dict[str, Any],
        tool_context: Optional[ToolContext] = None,
        timeout: int = None,
    ) -> Any:
        """Execute a specific tool directly, connecting and disconnecting automatically.

        Args:
            server_config: Configuration for the MCP server
            tool_name: Name of the tool to execute
            args: Arguments to pass to the tool
            tool_context: Tool context for execution (optional)
            timeout: Optional timeout in seconds (default: 30s)

        Returns:
            Result from the tool execution
        """
        if tool_context is None:
            tool_context = ToolContext()

        # Use provided timeout or default from mcp_context
        current_timeout = timeout

        logger.info(f"Executing tool {tool_name} with dynamic connection")

        async with mcp_context(server_config, timeout=current_timeout) as tools:
            # Find the tool
            tool = next((t for t in tools if t.name == tool_name), None)
            if not tool:
                raise RuntimeError(f"Tool {tool_name} not found in MCP server")

            # Execute the tool
            logger.info(f"Found and executing tool: {tool_name}")
            result = await tool.run_async(args=args, tool_context=tool_context)

            logger.info(f"Tool {tool_name} execution completed and connection closed")
            return result

    async def build_lazy_tools(
        self, mcp_config: Dict[str, Any], db: Session, agent_id: str = None
    ) -> List[LazyMCPTool]:
        """Builds a list of lazy proxy tools from multiple MCP servers.

        This method discovers the available tools in each MCP server but
        returns proxy objects that extend MCPTool and connect only on demand,
        saving resources by not keeping connections open.

        Args:
            mcp_config: Configuration for MCP servers
            db: Database session
            agent_id: Optional agent ID for caching agent-specific tools

        Returns:
            List of lazy MCP tools
        """
        lazy_tools = []

        try:
            # Process MCP servers from configuration (code-based, not database)
            mcp_servers = mcp_config.get("mcp_servers", [])
            logger.info(f"Processing {len(mcp_servers) if mcp_servers else 0} MCP servers from config")
            if mcp_servers:
                for server in mcp_servers:
                    try:
                        # Get server name/type from config
                        server_name = server.get("name", "").lower()
                        server_id = str(server.get("id", "")).lower()
                        server_url = server.get("url", "")
                        
                        # Determine server type from name, id, or URL
                        server_type = None
                        if "github" in server_name or "github" in server_id or "github" in server_url or "githubcopilot.com" in server_url:
                            server_type = "github"
                        elif "notion" in server_name or "notion" in server_id or "notion" in server_url or "mcp.notion.com" in server_url:
                            server_type = "notion"
                        elif "stripe" in server_name or "stripe" in server_id or "stripe" in server_url or "mcp.stripe.com" in server_url:
                            server_type = "stripe"
                        elif "linear" in server_name or "linear" in server_id or "linear" in server_url or "mcp.linear.app" in server_url:
                            server_type = "linear"
                        elif "monday" in server_name or "monday" in server_id or "monday" in server_url or "mcp.monday.com" in server_url:
                            server_type = "monday"
                        elif "atlassian" in server_name or "atlassian" in server_id or "atlassian" in server_url or "mcp.atlassian.com" in server_url:
                            server_type = "atlassian"
                        elif "asana" in server_name or "asana" in server_id or "asana" in server_url or "mcp.asana.com" in server_url:
                            server_type = "asana"
                        elif "hubspot" in server_name or "hubspot" in server_id or "hubspot" in server_url or "mcp.hubspot.com" in server_url:
                            server_type = "hubspot"
                        elif "supabase" in server_name or "supabase" in server_id or "supabase" in server_url or "mcp.supabase.com" in server_url:
                            server_type = "supabase"
                        elif "canva" in server_name or "canva" in server_id or "canva" in server_url or "mcp.canva.com" in server_url:
                            server_type = "canva"
                        elif "paypal" in server_name or "paypal" in server_id or "paypal" in server_url or "mcp.paypal.com" in server_url:
                            server_type = "paypal"
                        
                        # Load server configuration from code
                        server_config = None
                        if server_type == "github":
                            if agent_id:
                                from src.services.adk.mcp_servers.github import get_github_mcp_config
                                server_config = await get_github_mcp_config(
                                    agent_id=agent_id,
                                    mcp_url=server_url,
                                    db=db
                                )
                            else:
                                logger.warning(
                                    f"GitHub MCP server requires agent_id. Skipping."
                                )
                                continue
                        elif server_type == "notion":
                            if agent_id:
                                from src.services.adk.mcp_servers.notion import get_notion_mcp_config
                                server_config = await get_notion_mcp_config(
                                    agent_id=agent_id,
                                    mcp_url=server_url,
                                    db=db
                                )
                            else:
                                logger.warning(
                                    f"Notion MCP server requires agent_id. Skipping."
                                )
                                continue
                        elif server_type == "stripe":
                            if agent_id:
                                from src.services.adk.mcp_servers.stripe import get_stripe_mcp_config
                                server_config = await get_stripe_mcp_config(
                                    agent_id=agent_id,
                                    mcp_url=server_url,
                                    db=db
                                )
                            else:
                                logger.warning(
                                    f"Stripe MCP server requires agent_id. Skipping."
                                )
                                continue
                        elif server_type == "linear":
                            if agent_id:
                                from src.services.adk.mcp_servers.linear import get_linear_mcp_config
                                server_config = await get_linear_mcp_config(
                                    agent_id=agent_id,
                                    mcp_url=server_url,
                                    db=db
                                )
                            else:
                                logger.warning(
                                    f"Linear MCP server requires agent_id. Skipping."
                                )
                                continue
                        elif server_type == "monday":
                            if agent_id:
                                from src.services.adk.mcp_servers.monday import get_monday_mcp_config
                                logger.info(f"Loading Monday MCP config for agent {agent_id}")
                                server_config = await get_monday_mcp_config(
                                    agent_id=agent_id,
                                    mcp_url=server_url,
                                    db=db
                                )
                                logger.info(
                                    f"Monday MCP config loaded: url={server_config.get('url')}, "
                                    f"has_token={bool(server_config.get('headers', {}).get('Authorization'))}, "
                                    f"selected_tools={len(server_config.get('tools', []))}, "
                                    f"headers_keys={list(server_config.get('headers', {}).keys())}"
                                )
                            else:
                                logger.warning(
                                    f"Monday MCP server requires agent_id. Skipping."
                                )
                                continue
                        elif server_type == "atlassian":
                            if agent_id:
                                from src.services.adk.mcp_servers.atlassian.config import get_atlassian_mcp_config
                                server_config = await get_atlassian_mcp_config(
                                    agent_id=agent_id,
                                    db=db
                                )
                            else:
                                logger.warning(
                                    f"Atlassian MCP server requires agent_id. Skipping."
                                )
                                continue
                        elif server_type == "asana":
                            if agent_id:
                                from src.services.adk.mcp_servers.asana import get_asana_mcp_config
                                logger.info(f"Loading Asana MCP config for agent {agent_id}")
                                server_config = await get_asana_mcp_config(
                                    agent_id=agent_id,
                                    mcp_url=server_url,
                                    db=db
                                )
                                logger.info(
                                    f"Asana MCP config loaded: "
                                    f"url={server_config.get('url')}, "
                                    f"has_auth={bool(server_config.get('headers', {}).get('Authorization'))}, "
                                    f"tools_count={len(server_config.get('tools', []))}"
                                )
                            else:
                                logger.warning(
                                    f"Asana MCP server requires agent_id. Skipping."
                                )
                                continue
                        elif server_type == "hubspot":
                            if agent_id:
                                from src.services.adk.mcp_servers.hubspot.config import get_hubspot_mcp_config
                                logger.info(f"Loading HubSpot MCP config for agent {agent_id}")
                                server_config_dict = await get_hubspot_mcp_config(
                                    agent_id=agent_id,
                                    db=db
                                )
                                if server_config_dict:
                                    server_config = server_config_dict
                                    logger.info(
                                        f"HubSpot MCP config loaded: "
                                        f"url={server_config.get('url')}, "
                                        f"has_auth={bool(server_config.get('headers', {}).get('Authorization'))}, "
                                        f"tools_count={len(server_config.get('tools', []))}"
                                    )
                                else:
                                    logger.warning(f"HubSpot MCP config not found for agent {agent_id}")
                                    continue
                            else:
                                logger.warning(
                                    f"HubSpot MCP server requires agent_id. Skipping."
                                )
                                continue
                        elif server_type == "supabase":
                            if agent_id:
                                from src.services.adk.mcp_servers.supabase import get_supabase_mcp_config
                                logger.info(f"Loading Supabase MCP config for agent {agent_id}")
                                server_config = await get_supabase_mcp_config(
                                    agent_id=agent_id,
                                    mcp_url=server_url,
                                    db=db
                                )
                                logger.info(
                                    f"Supabase MCP config loaded: "
                                    f"url={server_config.get('url')}, "
                                    f"has_auth={bool(server_config.get('headers', {}).get('Authorization'))}, "
                                    f"tools_count={len(server_config.get('tools', []))}"
                                )
                            else:
                                logger.warning(
                                    f"Supabase MCP server requires agent_id. Skipping."
                                )
                                continue
                        elif server_type == "canva":
                            if agent_id:
                                from src.services.adk.mcp_servers.canva import get_canva_mcp_config
                                logger.info(f"Loading Canva MCP config for agent {agent_id}")
                                server_config = await get_canva_mcp_config(
                                    agent_id=agent_id,
                                    mcp_url=server_url,
                                    db=db
                                )
                                logger.info(
                                    f"Canva MCP config loaded: "
                                    f"url={server_config.get('url')}, "
                                    f"has_auth={bool(server_config.get('headers', {}).get('Authorization'))}, "
                                    f"tools_count={len(server_config.get('tools', []))}"
                                )
                            else:
                                logger.warning(
                                    f"Canva MCP server requires agent_id. Skipping."
                                )
                                continue
                        elif server_type == "paypal":
                            if agent_id:
                                from src.services.adk.mcp_servers.paypal import get_paypal_mcp_config
                                logger.info(f"Loading PayPal MCP config for agent {agent_id}")
                                server_config = await get_paypal_mcp_config(
                                    agent_id=agent_id,
                                    mcp_url=server_url,
                                    db=db
                                )
                                logger.info(
                                    f"PayPal MCP config loaded: "
                                    f"url={server_config.get('url')}, "
                                    f"has_auth={bool(server_config.get('headers', {}).get('Authorization'))}, "
                                    f"tools_count={len(server_config.get('tools', []))}"
                                )
                            else:
                                logger.warning(
                                    f"PayPal MCP server requires agent_id. Skipping."
                                )
                                continue
                        else:
                            logger.warning(
                                f"Unknown MCP server type: {server_name or server_id}. Skipping."
                            )
                            continue
                        
                        if not server_config:
                            logger.warning(f"Failed to load configuration for MCP server: {server_name or server_id}")
                            continue

                        # ⚠️ The key is `environments`, not `envs`: the screen
                        # writes `environments` and the core persists the entry
                        # as {id, environments, tools}, so a guard on `envs`
                        # never fires for an agent configured through the UI.
                        if server.get("environments") or server.get("envs"):
                            if "env" not in server_config:
                                server_config["env"] = {}
                            server_config["env"].update(_resolve_mcp_envs(server, db))

                        # Get tools from server_config (which comes from integration config) 
                        # or fallback to server.get("tools") for backward compatibility
                        agent_tools = server_config.get("tools", []) or server.get("tools", [])
                        logger.info(
                            f"MCP server {server_name or server_id}: "
                            f"tools from integration={len(server_config.get('tools', []))}, "
                            f"tools from server config={len(server.get('tools', []))}, "
                            f"using {len(agent_tools)} tools"
                        )
                        # Use server name/type as identifier for caching
                        server_id = server_type or server_name or server_id or "unknown"
                        cached_tools = None

                        if agent_id:
                            cached_agent_data = await mcp_tool_cache.get_agent_tools(
                                agent_id,
                                server_id,
                                len(agent_tools) if agent_tools else 0,
                            )

                            if cached_agent_data:
                                cached_agent_tools, cached_tool_count = (
                                    cached_agent_data
                                )
                                logger.info(
                                    f"Using tools in cache for agent {agent_id} and server {server_name or server_type or 'unknown'}"
                                )
                                lazy_tools.extend(cached_agent_tools)
                                continue

                        if not cached_tools:
                            # Log Monday-specific details
                            if server_type == "monday":
                                logger.info(
                                    f"Monday MCP: Attempting to discover tools. "
                                    f"URL: {server_config.get('url')}, "
                                    f"Has Authorization header: {bool(server_config.get('headers', {}).get('Authorization'))}, "
                                    # Header NAMES only: dumping the map put bearer
                                    # tokens in the logs.
                                    f"Header names: {list(server_config.get('headers', {}).keys())}"
                                )
                            
                            cached_tools = await mcp_tool_cache.get_server_tools(
                                server_config
                            )

                            if cached_tools:
                                if server_type == "monday":
                                    logger.info(f"Monday MCP: Found {len(cached_tools)} tools in cache")
                                logger.info(
                                    f"Using tools in cache for the server {server_name or server_type or 'unknown'}"
                                )
                                if agent_tools:
                                    filtered_tools = self._filter_tools_by_agent(
                                        cached_tools, agent_tools
                                    )
                                    if agent_id:
                                        await mcp_tool_cache.set_agent_tools(
                                            agent_id,
                                            server_id,
                                            filtered_tools,
                                            len(agent_tools),
                                        )
                                    lazy_tools.extend(filtered_tools)
                                else:
                                    lazy_tools.extend(cached_tools)
                                continue

                        # Check if server requires authentication but doesn't have it
                        has_auth = bool(server_config.get('headers', {}).get('Authorization'))
                        server_url = server_config.get('url', '')
                        
                        # Skip discovery for servers that require auth but don't have it
                        # This prevents 401 errors and cancel scope issues
                        if not has_auth and server_url:
                            # Some servers require auth (like GitHub Copilot)
                            requires_auth_servers = [
                                'api.githubcopilot.com',
                                'mcp.github.com',
                                'github.com'
                            ]
                            if any(domain in server_url for domain in requires_auth_servers):
                                logger.warning(
                                    f"Skipping discovery for {server_name or server_type or 'unknown'} "
                                    f"(url={server_url}): Server requires authentication but no access_token provided"
                                )
                                continue
                        
                        logger.info(
                            f"Discovering tools from MCP server: {server_name or server_type or 'unknown'} "
                            f"(url={server_url}, has_auth={has_auth})"
                        )
                        
                        # Monday-specific logging
                        if server_type == "monday":
                            logger.info(
                                f"Monday MCP: About to connect. "
                                f"Config: url={server_url}, "
                                f"header_names={list(server_config.get('headers', {}).keys())}, "
                                f"tool_filter={agent_tools}"
                            )

                        # Temporarily connect to discover available tools
                        # Use a shorter timeout and better error handling to avoid breaking agent build
                        try:
                            # Use the same timeout as _discover_async (30s) for consistency
                            discovery_timeout = min(settings.MCP_DISCOVERY_TIMEOUT, 30)
                            
                            # Create a task to isolate the MCP context from parent cancellation
                            async def discover_tools_task():
                                async with mcp_context(
                                    server_config,
                                    timeout=discovery_timeout,
                                    tool_filter=agent_tools,
                                ) as tools:
                                    return tools
                            
                            # Run discovery in a separate task to avoid cancellation issues
                            # Wrap in try-except to catch any exceptions from the task
                            discovery_task = None
                            tools = None
                            
                            try:
                                discovery_task = asyncio.create_task(discover_tools_task())
                                
                                # Add a callback to handle task exceptions silently
                                def handle_task_exception(task):
                                    try:
                                        if task.exception():
                                            # Task raised an exception, but we'll ignore it
                                            pass
                                    except (RuntimeError, Exception):
                                        # Ignore any errors in exception handling, especially RuntimeError from anyio
                                        pass
                                
                                discovery_task.add_done_callback(handle_task_exception)
                                
                                # Wait for discovery with timeout
                                tools = await asyncio.wait_for(
                                    discovery_task, 
                                    timeout=discovery_timeout + 5
                                )
                            except asyncio.TimeoutError:
                                # Cancel the task if timeout
                                if discovery_task and not discovery_task.done():
                                    discovery_task.cancel()
                                try:
                                    if discovery_task:
                                        await asyncio.wait_for(discovery_task, timeout=0.5)
                                except (asyncio.CancelledError, asyncio.TimeoutError, RuntimeError, Exception):
                                    # Silently ignore all cleanup errors
                                    pass
                                logger.warning(
                                    f"MCP discovery timeout for {server_name or server_type or 'unknown'} "
                                    f"after {discovery_timeout + 5}s. Skipping this server."
                                )
                                continue
                            except asyncio.CancelledError:
                                # If task is cancelled, try to clean up
                                if discovery_task and not discovery_task.done():
                                    discovery_task.cancel()
                                try:
                                    if discovery_task:
                                        await asyncio.wait_for(discovery_task, timeout=0.5)
                                except (asyncio.CancelledError, asyncio.TimeoutError, RuntimeError, Exception):
                                    # Silently ignore all cleanup errors
                                    pass
                                logger.warning(
                                    f"MCP discovery cancelled for {server_name or server_type or 'unknown'}. "
                                    f"Skipping this server."
                                )
                                continue
                            except RuntimeError as e:
                                # Catch RuntimeError from anyio cancel scope issues
                                if "cancel scope" in str(e).lower() or "different task" in str(e).lower():
                                    if discovery_task and not discovery_task.done():
                                        discovery_task.cancel()
                                    try:
                                        if discovery_task:
                                            await asyncio.wait_for(discovery_task, timeout=0.5)
                                    except (asyncio.CancelledError, asyncio.TimeoutError, RuntimeError, Exception):
                                        # Silently ignore all cleanup errors
                                        pass
                                    logger.warning(
                                        f"MCP discovery encountered cancel scope error for {server_name or server_type or 'unknown'}: {e}. "
                                        f"This is a known issue with anyio task groups during agent build. Skipping this server."
                                    )
                                    continue
                                raise
                            except Exception as discovery_error:
                                # Catch any other errors during discovery
                                if discovery_task and not discovery_task.done():
                                    discovery_task.cancel()
                                try:
                                    if discovery_task:
                                        await asyncio.wait_for(discovery_task, timeout=0.5)
                                except (asyncio.CancelledError, asyncio.TimeoutError, RuntimeError, Exception):
                                    # Silently ignore all cleanup errors
                                    pass
                                logger.warning(
                                    f"MCP discovery error for {server_name or server_type or 'unknown'}: {discovery_error}. "
                                    f"Skipping this server."
                                )
                                continue
                            
                            # Process discovered tools
                            if not tools:
                                if server_type == "monday":
                                    logger.error(
                                        f"Monday MCP: No tools discovered! "
                                        f"URL: {server_config.get('url')}, "
                                        f"Has auth: {bool(server_config.get('headers', {}).get('Authorization'))}"
                                    )
                                logger.warning(
                                    f"No tools discovered in MCP server {server_name or server_type or 'unknown'} "
                                    f"(url={server_config.get('url')}). "
                                    f"This could indicate: 1) Server is not responding, 2) Authentication failed, 3) Server has no tools available"
                                )
                                continue
                            
                            if server_type == "monday":
                                logger.info(
                                    f"Monday MCP: Successfully discovered {len(tools)} tools: "
                                    f"{[tool.name for tool in tools[:10]]}"
                                )
                            
                            logger.info(
                                f"Discovered {len(tools)} tools from MCP server {server_name or server_type or 'unknown'}: "
                                f"{[tool.name for tool in tools[:5]]}{'...' if len(tools) > 5 else ''}"
                            )

                            # Filter out incompatible tools
                            filtered_tools = self._filter_incompatible_tools(tools)

                            # Create the list of lazy tools
                            server_lazy_tools = []
                            for tool in filtered_tools:
                                # Try to extract the input schema
                                input_schema = None
                                if hasattr(tool, "_mcp_tool") and tool._mcp_tool:
                                    if hasattr(tool._mcp_tool, "inputSchema"):
                                        input_schema = tool._mcp_tool.inputSchema
                                        logger.debug(
                                            f"Extracted schema for {tool.name}"
                                        )

                                # Create a proxy with the basic info and schema
                                lazy_tool = LazyMCPTool(
                                    server_config,
                                    tool.name,
                                    getattr(tool, "description", ""),
                                    input_schema,
                                )

                                # Add the tool to our list
                                server_lazy_tools.append(lazy_tool)

                            # Store all server tools in cache
                            await mcp_tool_cache.set_server_tools(
                                server_config, server_lazy_tools
                            )

                            # Filter by agent's allowed tools if specified
                            if agent_tools:
                                agent_specific_tools = self._filter_tools_by_agent(
                                    server_lazy_tools, agent_tools
                                )

                                # Store in agent-specific cache if an ID was provided
                                if agent_id:
                                    await mcp_tool_cache.set_agent_tools(
                                        agent_id,
                                        server_id,
                                        agent_specific_tools,
                                        len(agent_tools),
                                    )

                                lazy_tools.extend(agent_specific_tools)
                                logger.info(
                                    f"Added {len(agent_specific_tools)} tools from MCP server {server_name or server_type or 'unknown'} "
                                    f"(filtered from {len(server_lazy_tools)} total tools)"
                                )
                            else:
                                lazy_tools.extend(server_lazy_tools)
                                logger.info(
                                    f"Added {len(server_lazy_tools)} tools from MCP server {server_name or server_type or 'unknown'} "
                                    f"(no filtering, all tools included)"
                                )
                        except asyncio.CancelledError:
                            logger.warning(
                                f"MCP discovery for {server_name or server_type or 'unknown'} was cancelled. "
                                f"This is normal if the agent build is interrupted. Skipping this server."
                            )
                            # Don't fail the entire agent build if discovery is cancelled
                            continue
                        except RuntimeError as runtime_error:
                            # Catch RuntimeError from anyio cancel scope issues
                            if "cancel scope" in str(runtime_error).lower():
                                logger.warning(
                                    f"MCP discovery encountered cancel scope error for {server_name or server_type or 'unknown'}: {runtime_error}. "
                                    f"This is a known issue with anyio task groups during agent build. Skipping this server."
                                )
                                continue
                            # Re-raise other RuntimeErrors
                            raise
                        except Exception as context_error:
                            if server_type == "monday":
                                logger.error(
                                    f"Monday MCP: Connection error! "
                                    f"URL: {server_config.get('url')}, "
                                    f"Error: {context_error}",
                                    exc_info=True
                                )
                            logger.error(
                                f"Error connecting to MCP server {server_name or server_type or 'unknown'} "
                                f"(url={server_config.get('url')}): {context_error}",
                                exc_info=True
                            )
                            # Don't fail the entire agent build if one MCP server fails
                            continue

                    except Exception as e:
                        logger.error(
                            f"Error processing MCP server {server.get('id', 'unknown')}: {e}"
                        )
                        continue

            # Process custom MCP server IDs - fetch from database
            custom_mcp_server_ids = mcp_config.get("custom_mcp_server_ids", [])
            if custom_mcp_server_ids:
                from src.services import custom_mcp_server_service
                import uuid

                logger.info(
                    f"Processing {len(custom_mcp_server_ids)} custom MCP server IDs"
                )

                for server_id_str in custom_mcp_server_ids:
                    try:
                        # Convert to UUID and get from database
                        server_id = uuid.UUID(server_id_str)
                        custom_server = custom_mcp_server_service.get_custom_mcp_server(
                            db, server_id
                        )

                        if not custom_server:
                            logger.warning(
                                f"Custom MCP server not found: {server_id_str}"
                            )
                            continue

                        # A credential_refs entry replaces the header of the
                        # same name with the decrypted secret; the inline header
                        # stays the fallback.
                        server_config = {
                            "url": custom_server.url,
                            "headers": _resolve_mcp_headers(custom_server, db),
                        }

                        logger.info(
                            f"Discovering tools from custom MCP server (ID: {server_id_str}): {custom_server.url}"
                        )

                        # Check cache first
                        cached_tools = await mcp_tool_cache.get_server_tools(
                            server_config
                        )
                        if cached_tools:
                            logger.info(
                                f"Using tools in cache for custom server {server_id_str}"
                            )
                            lazy_tools.extend(cached_tools)
                            continue

                        # Temporarily connect to discover available tools
                        async with mcp_context(
                            server_config, timeout=settings.MCP_DISCOVERY_TIMEOUT
                        ) as tools:
                            if not tools:
                                logger.warning(
                                    f"No tools discovered from custom MCP server {server_id_str}"
                                )
                                continue

                            # Filter out incompatible tools
                            filtered_tools = self._filter_incompatible_tools(tools)

                            # Create the lazy tools
                            custom_lazy_tools = []
                            for tool in filtered_tools:
                                # Try to extract the input schema
                                input_schema = None
                                if hasattr(tool, "_mcp_tool") and tool._mcp_tool:
                                    if hasattr(tool._mcp_tool, "inputSchema"):
                                        input_schema = tool._mcp_tool.inputSchema
                                        logger.debug(
                                            f"Extracted schema for {tool.name}"
                                        )

                                # Create a proxy with the basic info and schema
                                lazy_tool = LazyMCPTool(
                                    server_config,
                                    tool.name,
                                    getattr(tool, "description", ""),
                                    input_schema,
                                )

                                # Add the tool to our list
                                custom_lazy_tools.append(lazy_tool)

                            # Store custom tools in cache
                            await mcp_tool_cache.set_server_tools(
                                server_config, custom_lazy_tools
                            )

                            # Add to the list of tools
                            lazy_tools.extend(custom_lazy_tools)
                            logger.info(
                                f"Added {len(custom_lazy_tools)} lazy tools from custom MCP server {server_id_str}"
                            )

                    except Exception as e:
                        logger.error(
                            f"Error processing custom MCP server ID {server_id_str}: {e}"
                        )
                        continue

            # Process custom MCP servers (full configurations)
            custom_mcp_servers = mcp_config.get("custom_mcp_servers", [])
            if custom_mcp_servers:
                for server in custom_mcp_servers:
                    if not server:
                        logger.warning(
                            "Empty server configuration found in custom_mcp_servers"
                        )
                        continue

                    try:
                        server_id = server.get("id", server.get("url", "unknown"))
                        logger.info(
                            f"Discovering tools from custom MCP server: {server.get('url', 'unknown')}"
                        )

                        # Check if there is cache for this server
                        if agent_id:
                            # Check agent-specific cache first
                            agent_tools = mcp_config.get("tools", [])
                            cached_agent_data = await mcp_tool_cache.get_agent_tools(
                                agent_id,
                                server_id,
                                len(agent_tools) if agent_tools else 0,
                            )

                            if cached_agent_data:
                                cached_agent_tools, _ = cached_agent_data
                                logger.info(
                                    f"Using tools in cache for agent {agent_id} and custom server {server_id}"
                                )
                                lazy_tools.extend(cached_agent_tools)
                                continue

                        # Check general server cache if there is no agent-specific cache
                        cached_tools = await mcp_tool_cache.get_server_tools(server)

                        if cached_tools:
                            logger.info(
                                f"Using tools in cache for the custom server {server_id}"
                            )
                            if agent_id and agent_tools:
                                # Filter tools for the agent
                                agent_specific_tools = self._filter_tools_by_agent(
                                    cached_tools, agent_tools
                                )
                                # Store in agent-specific cache
                                await mcp_tool_cache.set_agent_tools(
                                    agent_id,
                                    server_id,
                                    agent_specific_tools,
                                    len(agent_tools),
                                )
                                lazy_tools.extend(agent_specific_tools)
                            else:
                                lazy_tools.extend(cached_tools)
                            continue

                        # Temporarily connect to discover available tools
                        async with mcp_context(
                            server, timeout=settings.MCP_DISCOVERY_TIMEOUT
                        ) as tools:
                            if not tools:
                                logger.warning(
                                    "No tools discovered from custom MCP server"
                                )
                                continue

                            # Filter out incompatible tools
                            filtered_tools = self._filter_incompatible_tools(tools)

                            # Create the lazy tools
                            custom_lazy_tools = []
                            for tool in filtered_tools:
                                # Try to extract the input schema
                                input_schema = None
                                if hasattr(tool, "_mcp_tool") and tool._mcp_tool:
                                    if hasattr(tool._mcp_tool, "inputSchema"):
                                        input_schema = tool._mcp_tool.inputSchema
                                        logger.debug(
                                            f"Extracted schema for {tool.name}"
                                        )

                                # Create a proxy with the basic info and schema
                                lazy_tool = LazyMCPTool(
                                    server,
                                    tool.name,
                                    getattr(tool, "description", ""),
                                    input_schema,
                                )

                                # Add the tool to our list
                                custom_lazy_tools.append(lazy_tool)

                            # Store custom tools in cache
                            await mcp_tool_cache.set_server_tools(
                                server, custom_lazy_tools
                            )

                            # If we have agent-specific tools, filter and store in agent cache
                            if agent_id and agent_tools:
                                agent_specific_tools = self._filter_tools_by_agent(
                                    custom_lazy_tools, agent_tools
                                )
                                await mcp_tool_cache.set_agent_tools(
                                    agent_id,
                                    server_id,
                                    agent_specific_tools,
                                    len(agent_tools),
                                )
                                lazy_tools.extend(agent_specific_tools)
                            else:
                                # Add to the list of tools
                                lazy_tools.extend(custom_lazy_tools)

                            logger.info(
                                f"Added {len(custom_lazy_tools)} lazy tools from custom MCP server"
                            )

                    except Exception as e:
                        logger.error(f"Error processing custom MCP server: {e}")
                        continue

            logger.info(f"Created {len(lazy_tools)} lazy MCP tools in total")

        except Exception as e:
            logger.error(f"Error building lazy MCP tools: {e}")

        logger.info(f"build_lazy_tools returning {len(lazy_tools)} total lazy MCP tools")
        return lazy_tools

    # DEPRECATED: This method keeps connections open. Use build_lazy_tools instead.
    async def build_tools(
        self, mcp_config: Dict[str, Any], db: Session
    ) -> Tuple[List[Any], AsyncExitStack]:
        """Builds a list of tools from multiple MCP servers."""
        raise DeprecationWarning(
            "build_tools is deprecated and keeps connections open. Use build_lazy_tools instead."
        )


def _resolve_mcp_envs(server, db):
    """Resolves the env vars of an OFFICIAL MCP server against the vault.

    The reference map lives on the AGENT's entry because the catalog column
    `evo_core_mcp_servers.environments` is a schema of REQUIRED KEYS, never a
    value. An env var with no reference is copied verbatim.
    """
    # `environments` is what the pipeline persists; `envs` is tolerated for any
    # entry written before the naming was reconciled.
    envs = server.get("environments") or server.get("envs") or {}
    credential_refs = server.get("credential_refs", {}) or {}
    if not credential_refs:
        return envs

    from src.services.adk.integration_credentials import (
        DatabaseCredentialVault,
        resolve_credential_refs,
    )
    from src.utils.crypto import decrypt_api_key

    return resolve_credential_refs(
        envs,
        credential_refs,
        vault=DatabaseCredentialVault(db),
        decrypt=decrypt_api_key,
    )


def _resolve_mcp_headers(custom_server, db):
    """Resolves the headers of a remote MCP server against the credential vault.

    A vault outage, or an unresolvable reference with an inline value present,
    degrades to today's behaviour, so nothing breaks before the 2.6 migration.
    """
    headers = custom_server.headers or {}
    credential_refs = getattr(custom_server, "credential_refs", None) or {}
    if not credential_refs:
        return headers

    from src.services.adk.integration_credentials import (
        DatabaseCredentialVault,
        resolve_credential_refs,
    )
    from src.utils.crypto import decrypt_api_key

    return resolve_credential_refs(
        headers,
        credential_refs,
        vault=DatabaseCredentialVault(db),
        decrypt=decrypt_api_key,
    )
