"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: preload_memory_tool.py                                                │
│ Developed by: Davidson Gomes                                                 │
│ Creation date: December 2025                                                  │
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

import uuid
from typing import Optional
import httpx
from google.adk.tools import FunctionTool, ToolContext
from src.config.settings import settings
from src.utils.logger import setup_logger

logger = setup_logger(__name__)


async def create_preload_memory_tool(
    memory_base_config_id: Optional[str] = None,
    default_max_results: int = 10,
) -> FunctionTool:
    """Factory function to create a memory preload tool

    Args:
        memory_base_config_id: Optional UUID of the memory base configuration to use
        default_max_results: Default maximum number of results to return
    """
    async def preload_memory_with_client(
        max_results: Optional[int] = None,
        tool_context: Optional[ToolContext] = None,
    ) -> dict:
        """Memory preload tool with embedded config_id
        
        This tool automatically loads medium-term memory summaries at the start of a conversation.
        It loads summaries without requiring a search query, providing context from previous conversations.
        """
        try:
            # Use default_max_results if max_results not provided
            effective_max_results = max_results if max_results is not None else default_max_results
            
            # Validate max_results
            if effective_max_results > 50:
                effective_max_results = 50
            elif effective_max_results < 1:
                effective_max_results = 1

            # Extract app_name and user_id from tool_context
            app_name = None
            user_id = None
            
            if tool_context:
                # Try to get from session
                if hasattr(tool_context, 'session') and tool_context.session:
                    app_name = getattr(tool_context.session, 'app_name', None)
                    user_id = getattr(tool_context.session, 'user_id', None)
                
                # Fallback: try to get from metadata
                if not app_name or not user_id:
                    metadata = getattr(tool_context, 'metadata', {})
                    if isinstance(metadata, dict):
                        app_name = metadata.get('app_name') or metadata.get('agent_id')
                        user_id = metadata.get('user_id') or metadata.get('client_id')
            
            if not app_name or not user_id:
                return {
                    "status": "error",
                    "message": "Could not determine app_name or user_id from context. This tool must be called during an active agent session.",
                    "memories": [],
                    "total": 0,
                }
            
            logger.info(
                f"Preloading memory for app '{app_name}', user '{user_id}'"
                + (f" using config {memory_base_config_id}" if memory_base_config_id else "")
            )

            # Call knowledge service HTTP API
            # KNOWLEDGE_SERVICE_URL already includes /api/v1
            base_url = settings.KNOWLEDGE_SERVICE_URL.rstrip("/")
            url = f"{base_url}/memory/load"
            
            # Use empty query for preload (loads medium_term summaries)
            params = {
                "app_name": app_name,
                "user_id": user_id,
                "query": "",  # Empty query loads medium_term summaries
                "max_results": effective_max_results,
            }
            
            # Build headers with memory_base_config_id and service token
            headers = {
                "Accept": "application/json",
            }
            
            # Add service token for service-to-service authentication
            if settings.KNOWLEDGE_SERVICE_API_TOKEN:
                headers["X-Service-Token"] = settings.KNOWLEDGE_SERVICE_API_TOKEN
                logger.debug("Added X-Service-Token header for memory preload request")
            else:
                logger.warning("KNOWLEDGE_SERVICE_API_TOKEN not configured - memory preload request may fail")
            
            if memory_base_config_id:
                headers["x-memory-base-config-id"] = str(memory_base_config_id)
            
            # Make HTTP request
            async with httpx.AsyncClient(timeout=30.0) as client:
                response = await client.get(url, params=params, headers=headers)
                
                if response.status_code == 200:
                    result = response.json()
                    memories = result.get("memories", [])
                    
                    if not memories:
                        return {
                            "status": "no_memories",
                            "message": "No memory summaries found for this conversation. This is normal for new conversations.",
                            "memories": [],
                            "total": 0,
                        }
                    
                    # Format memories for display
                    formatted_memories = []
                    for mem in memories:
                        formatted_memories.append({
                            "content": mem.get("content", ""),
                            "timestamp": mem.get("timestamp"),
                            "metadata": mem.get("metadata", {}),
                        })
                    
                    return {
                        "status": "success",
                        "message": f"Loaded {len(formatted_memories)} memory summaries from previous conversations",
                        "memories": formatted_memories,
                        "total": len(formatted_memories),
                    }
                elif response.status_code == 400:
                    error_detail = response.json().get("detail", "Bad request")
                    return {
                        "status": "error",
                        "message": f"Memory preload failed: {error_detail}",
                        "memories": [],
                        "total": 0,
                    }
                else:
                    error_detail = response.json().get("detail", f"HTTP {response.status_code}")
                    logger.error(f"HTTP error preloading memory: {response.status_code} - {error_detail}")
                    return {
                        "status": "error",
                        "message": f"Memory preload failed: {error_detail}",
                        "memories": [],
                        "total": 0,
                    }
                    
        except httpx.TimeoutException:
            logger.error("Timeout preloading memory")
            return {
                "status": "error",
                "message": "Timeout while preloading memory. The operation may have completed, but no response was received.",
                "memories": [],
                "total": 0,
            }
        except Exception as e:
            logger.error(f"Error preloading memory: {e}")
            return {
                "status": "error",
                "message": f"Error preloading memory: {str(e)}",
                "memories": [],
                "total": 0,
            }
    
    # Set function name and docstring for better tool description
    preload_memory_with_client.__name__ = "preload_memory"
    preload_memory_with_client.__doc__ = f"""Preload medium-term memory summaries from previous conversations.
    
    This tool automatically loads memory summaries at the start of a conversation to provide context.
    It loads medium-term summaries (compressed memories) without requiring a search query.
    
    Args:
        max_results: Maximum number of summaries to load (default: {default_max_results}, max: 50). If not provided, uses the configured default of {default_max_results}.
        tool_context: The tool context containing session information (automatically provided)
    
    Returns:
        Dictionary with preloaded memory summaries and status:
        {{
            "status": "success" | "no_memories" | "error",
            "message": "Human-readable message",
            "memories": List of memory summaries,
            "total": int
        }}
    """
    
    return FunctionTool(func=preload_memory_with_client)

