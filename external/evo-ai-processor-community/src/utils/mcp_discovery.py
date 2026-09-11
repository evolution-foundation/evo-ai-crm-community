"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Arley Peter                                                         │
│ @file: mcp_discovery.py                                                      │
│ Developed by: Arley Peter                                                    │
│ Creation date: May 05, 2025                                                  │
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

from typing import List, Dict, Any
import asyncio
import logging

logger = logging.getLogger(__name__)


async def _discover_async(config_json: Dict[str, Any]) -> List[Dict[str, Any]]:
    """Return a list[dict] with the tool metadata advertised by the MCP server."""

    from src.services.adk.mcp_context import mcp_context

    url = config_json.get("url", "unknown")
    headers = config_json.get("headers", {})
    auth_header = headers.get("Authorization", "")
    
    # Enhanced logging for Stripe
    if "stripe" in url.lower():
        token = auth_header.replace("Bearer ", "") if auth_header.startswith("Bearer ") else auth_header
        token_preview = f"{token[:10]}...{token[-10:]}" if len(token) > 20 else token[:20]
        logger.info(
            f"🔍 Stripe MCP Discovery - Starting tool discovery:\n"
            f"  - URL: {url}\n"
            f"  - Has Authorization header: {bool(auth_header)}\n"
            f"  - Token length: {len(token) if token else 0}\n"
            f"  - Token preview: {token_preview}\n"
            f"  - All headers: {list(headers.keys())}"
        )
    
    logger.debug(f"Discovering MCP tools from {url}")

    async with mcp_context(config_json, timeout=30) as tools:
        serialised = [
            (
                t.to_dict()
                if hasattr(t, "to_dict")
                else {
                    "id": t.name,
                    "name": t.name,
                    "description": getattr(t, "description", t.name),
                    "tags": getattr(t, "tags", []),
                    "examples": getattr(t, "examples", []),
                    "inputModes": getattr(t, "input_modes", ["text"]),
                    "outputModes": getattr(t, "output_modes", ["text"]),
                }
            )
            for t in tools
        ]
        return serialised


def discover_mcp_tools(config_json: Dict[str, Any]) -> List[Dict[str, Any]]:
    """Sync wrapper so we can call it from a sync service function."""
    return asyncio.run(_discover_async(config_json))
