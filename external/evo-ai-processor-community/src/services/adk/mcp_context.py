"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: mcp_context.py                                                        │
│ Developed by: Davidson Gomes                                                 │
│ Creation date: May 20, 2025                                                  │
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

from contextlib import asynccontextmanager
import os
import asyncio
from google.adk.tools.mcp_tool.mcp_toolset import MCPToolset
from google.adk.tools.mcp_tool.mcp_session_manager import (
    SseConnectionParams,
    StreamableHTTPServerParams,
)
from typing import Any, Dict, List, Optional
from src.utils.logger import setup_logger
from src.config.settings import settings

logger = setup_logger(__name__)

# Default timeout for MCP connections from settings
MCP_CONNECTION_TIMEOUT = settings.MCP_CONNECTION_TIMEOUT


# Header names whose VALUE is safe to log, mirroring `safeHeaderNames` in the Go
# secretmerge package. The map is free-form, so a denylist misses `X-API-Key`,
# `X-Tenant-Auth` and every custom credential header; an allowlist fails closed.
_SAFE_HEADER_NAMES = frozenset(
    {
        "accept",
        "accept-encoding",
        "accept-language",
        "cache-control",
        "connection",
        "content-type",
        "user-agent",
        "x-request-id",
        "x-correlation-id",
    }
)


def _loggable_headers(headers):
    """Returns the header map with every non-safe VALUE replaced by a marker.

    The NAMES survive: knowing which headers were sent is the diagnostic value,
    and it carries no secret.
    """
    return {
        key: (value if key.lower() in _SAFE_HEADER_NAMES else "***masked***")
        for key, value in (headers or {}).items()
    }


@asynccontextmanager
async def mcp_context(
    server_cfg: Dict[str, Any],
    timeout: int = None,
    tool_filter: Optional[List[str]] = None,
):
    """Opens and automatically closes the MCP server connection with timeout.

    Args:
        server_cfg: Configuration for connecting to the MCP server
        timeout: Maximum time in seconds to wait for connection (default from settings)

    Yields:
        List of tools provided by the MCP server or empty list on timeout/error
    """
    # Use provided timeout or default from settings
    connection_timeout = timeout if timeout is not None else MCP_CONNECTION_TIMEOUT
    toolset = None

    if "url" in server_cfg:  # Remote server (SSE or StreamableHTTP)
        url = server_cfg.get("url", "")
        
        # Determine connection type based on URL pattern:
        # - URLs ending with /mcp use StreamableHTTP (e.g., GitHub Copilot, Notion, Linear)
        # - Stripe MCP requires /mcp endpoint suffix for StreamableHTTP
        # - PayPal MCP uses StreamableHTTP but without /mcp suffix
        # - Other URLs use SSE (Server-Sent Events)
        url_normalized = url.rstrip("/")
        
        # Stripe MCP requires /mcp endpoint for StreamableHTTP
        # If Stripe URL doesn't have /mcp, append it
        if "mcp.stripe.com" in url and not url_normalized.endswith("/mcp"):
            url = f"{url_normalized}/mcp"
            url_normalized = url.rstrip("/")
            logger.info(f"Stripe MCP URL adjusted to include /mcp endpoint: {url}")
        
        uses_streamable_http = (
            url_normalized.endswith("/mcp") or  # Standard MCP pattern (including Stripe with /mcp)
            "mcp.paypal.com" in url  # PayPal MCP exception
        )
        
        if uses_streamable_http:
            headers = server_cfg.get("headers", {})
            
            # Ensure required MCP headers are present
            if "Content-Type" not in headers:
                headers["Content-Type"] = "application/json"
            if "Accept" not in headers:
                headers["Accept"] = "application/json, text/event-stream"
            
            # Add Connection header for StreamableHTTP to maintain persistent connections
            # This helps prevent "Session terminated" errors
            if "Connection" not in headers:
                headers["Connection"] = "keep-alive"
            
            logger.info(
                f"Using StreamableHTTP for {url}. "
                f"Headers: {sorted(_loggable_headers(headers))}"
            )
            # Use adjusted URL (may include /mcp for Stripe)
            params = StreamableHTTPServerParams(
                url=url, headers=headers
            )
        else:
            headers = server_cfg.get("headers", {})
            logger.info(
                f"Using SSE for {url}. Headers: {list(headers.keys())}"
            )
            params = SseConnectionParams(
                url=server_cfg["url"], headers=headers
            )
    else:  # Local server (Stdio)
        command = server_cfg.get("command", "npx")
        args = server_cfg.get("args", [])
        env = server_cfg.get("env", {})

        # The env vars go to the CHILD process only, through StdioServerParameters.
        # Writing them into the processor's own os.environ was redundant and
        # never undone, so one agent's token leaked into every MCP subprocess
        # spawned afterwards — across tenants in the enterprise build.
        params = StdioServerParameters(command=command, args=args, env=env)

    try:
        # Apply timeout to the server connection
        url = server_cfg.get("url", "unknown")
        logger.info(f"Connecting to MCP server {url} with {connection_timeout}s timeout")
        try:
            # Create MCPToolset with the new structure
            toolset = MCPToolset(connection_params=params, tool_filter=tool_filter)

            # Get tools from the toolset with timeout
            logger.debug(f"Requesting tools from MCP server {url}...")
            tools_task = toolset.get_tools()
            tools = await asyncio.wait_for(tools_task, timeout=connection_timeout)
            
            logger.info(
                f"Successfully retrieved {len(tools)} tools from MCP server {url}"
            )

            try:
                yield tools
            finally:
                # Close the toolset properly
                if toolset:
                    try:
                        await toolset.close()
                        logger.debug(f"MCP context closed successfully for {url}")
                    except Exception as e:
                        logger.warning(f"Error closing MCP toolset for {url}: {e}")

        except asyncio.TimeoutError:
            logger.error(
                f"MCP server {url} connection timed out after {connection_timeout} seconds"
            )
            yield []  # Return empty list on timeout
        except asyncio.CancelledError:
            logger.warning(
                f"MCP context task was cancelled for {url}. "
                f"This may happen during agent build if tasks are cancelled. "
                f"Returning empty tools list to allow agent build to continue."
            )
            yield []  # Return empty list on cancellation to allow agent build to continue
    except Exception as e:
        import traceback
        error_msg = str(e)
        url = server_cfg.get('url', 'unknown')
        
        # Check if it's a session termination error (common with expired tokens)
        if "Session terminated" in error_msg or "session terminated" in error_msg.lower():
            logger.error(
                f"MCP server {url} rejected the connection: Session terminated. "
                f"This usually means the access token is invalid, expired, or lacks required permissions."
            )
            
            # For HubSpot specifically, provide additional guidance
            if "hubspot" in url.lower():
                logger.error(
                    "⚠️ HubSpot MCP 'Session terminated' troubleshooting:\n"
                    "1. Ensure the HubSpot app is INSTALLED in the HubSpot account before generating tokens\n"
                    "2. Verify the app is configured as User-Level App (isUserLevel: true)\n"
                    "3. Verify platformVersion >= 2025.2\n"
                    "4. Verify scopes match exactly between app config and requested scopes\n"
                    "5. Check if token has expired (verify expires_at in stored config)\n"
                    "6. Test token manually: curl -X GET 'https://api.hubapi.com/oauth/v1/access-tokens/TOKEN'"
                )
            
            # Log token info if available
            headers = server_cfg.get("headers", {})
            auth_header = headers.get("Authorization", "")
            if auth_header:
                # Extract token from Bearer format if present
                token = auth_header.replace("Bearer ", "") if auth_header.startswith("Bearer ") else auth_header
                token_preview = token[:15] + "..." + token[-10:] if len(token) > 25 else token
                token_starts_with = token[:4] if len(token) >= 4 else "N/A"
                logger.error(
                    f"Token preview: Bearer {token_preview}, "
                    f"Token starts with: {token_starts_with}, "
                    f"Token length: {len(token)}, "
                    f"Full auth header length: {len(auth_header)}"
                )
            
            # Log all headers being sent (masked)
            header_info = {}
            logger.error(
                f"Headers sent to MCP server: {sorted(_loggable_headers(headers))}"
            )
            
            # Try to extract more error details from the exception
            if hasattr(e, '__cause__') and e.__cause__:
                cause_msg = str(e.__cause__)
                if cause_msg and cause_msg != error_msg:
                    logger.error(f"Error cause: {cause_msg}")
            
            # Check if there's a response body in the exception
            if hasattr(e, 'response_body') and e.response_body:
                logger.error(f"MCP Error Response Body: {e.response_body}")
        else:
            logger.error(f"Error in MCP context for {url}: {e}")
        
        logger.error(traceback.format_exc())
        yield []  # Return empty list in case of error
    finally:
        # Ensure cleanup even if an exception occurred
        if toolset:
            try:
                await toolset.close()
            except Exception as e:
                logger.warning(f"Error in final cleanup: {e}")
