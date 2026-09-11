"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: AI Assistant                                                        │
│ @file: compress_memory_tool.py                                               │
│ Developed by: AI Assistant                                                   │
│ Creation date: January 2025                                                  │
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
from src.utils.logger import setup_logger
from src.config.settings import settings

logger = setup_logger(__name__)


async def create_compress_memory_tool(
    memory_base_config_id: Optional[str] = None,
) -> FunctionTool:
    """Factory function to create a memory compression tool.

    Args:
        memory_base_config_id: Optional UUID of the memory base configuration to use
    """
    async def compress_memory_with_client(
        force: bool = False,
        tool_context: Optional[ToolContext] = None,
    ) -> dict:
        """Compress short-term memory into medium-term summary
        
        This tool compresses accumulated short-term memory messages into a concise
        medium-term summary using AI. This helps maintain context while reducing
        memory usage.
        
        Args:
            force: If True, compress even if compression_interval is not reached.
                  If False, only compress when enough messages have accumulated.
            tool_context: The tool context containing session information (automatically provided)
        
        Returns:
            Dictionary with compression status and details:
            {
                "status": "success" | "no_messages" | "not_ready" | "error",
                "message": "Human-readable message",
                "messages_compressed": int,
                "summary_id": str (optional)
            }
        """
        try:
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
                    "messages_compressed": 0,
                }
            
            logger.info(
                f"Compressing memory for app '{app_name}', user '{user_id}' (force={force})"
            )
            
            # Call knowledge service HTTP API
            # KNOWLEDGE_SERVICE_URL already includes /api/v1
            base_url = settings.KNOWLEDGE_SERVICE_URL.rstrip("/")
            url = f"{base_url}/memory/compress"
            
            payload = {
                "app_name": str(app_name),
                "user_id": str(user_id),
                "force": force,
            }
            
            # Build headers with memory_base_config_id and service token
            headers = {
                "Content-Type": "application/json",
                "Accept": "application/json",
            }
            
            # Add service token for service-to-service authentication
            if settings.KNOWLEDGE_SERVICE_API_TOKEN:
                headers["X-Service-Token"] = settings.KNOWLEDGE_SERVICE_API_TOKEN
                logger.debug("Added X-Service-Token header for memory compression request")
            else:
                logger.warning("KNOWLEDGE_SERVICE_API_TOKEN not configured - compression request may fail")
            
            if memory_base_config_id:
                headers["x-memory-base-config-id"] = str(memory_base_config_id)
            
            # Make HTTP request
            async with httpx.AsyncClient(timeout=30.0) as client:
                response = await client.post(url, json=payload, headers=headers)
                
                if response.status_code == 200:
                    result = response.json()
                    return {
                        "status": "success" if result.get("success") else "error",
                        "message": result.get("message", "Memory compression completed"),
                        "messages_compressed": result.get("messages_compressed", 0),
                        "summary_id": result.get("summary_id"),
                        "summary_content": result.get("summary_content"),
                    }
                elif response.status_code == 400:
                    error_detail = response.json().get("detail", "Bad request")
                    return {
                        "status": "error",
                        "message": f"Compression failed: {error_detail}",
                        "messages_compressed": 0,
                    }
                else:
                    error_detail = response.json().get("detail", f"HTTP {response.status_code}")
                    logger.error(f"HTTP error compressing memory: {response.status_code} - {error_detail}")
                    return {
                        "status": "error",
                        "message": f"Compression failed: {error_detail}",
                        "messages_compressed": 0,
                    }
                    
        except httpx.TimeoutException:
            logger.error("Timeout compressing memory")
            return {
                "status": "error",
                "message": "Timeout while compressing memory. The operation may have completed, but no response was received.",
                "messages_compressed": 0,
            }
        except Exception as e:
            logger.error(f"Error compressing memory: {e}")
            return {
                "status": "error",
                "message": f"Error compressing memory: {str(e)}",
                "messages_compressed": 0,
            }
    
    # Set function name and docstring for better tool description
    compress_memory_with_client.__name__ = "compress_memory"
    compress_memory_with_client.__doc__ = """Compress accumulated short-term memory messages into a concise medium-term summary using AI.

Use this tool when:
- You want to consolidate recent conversation history into a summary
- Memory is accumulating and you want to reduce token usage
- You need to create a summary of important information from recent interactions

The compression uses AI to create a meaningful summary that preserves important context and information.
By default, compression only happens when enough messages have accumulated (based on compression_interval).
Use force=true to compress immediately regardless of message count.

Args:
    force: If True, compress even if compression_interval is not reached. If False, only compress when enough messages have accumulated.
    tool_context: The tool context containing session information (automatically provided)

Returns:
    Dictionary with compression status and details:
    {
        "status": "success" | "no_messages" | "not_ready" | "error",
        "message": "Human-readable message",
        "messages_compressed": int,
        "summary_id": str (optional),
        "summary_content": str (optional) - The content of the created summary
    }
"""
    
    return FunctionTool(func=compress_memory_with_client)

