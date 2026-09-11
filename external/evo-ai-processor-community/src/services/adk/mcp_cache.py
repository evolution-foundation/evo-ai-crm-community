"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: mcp_cache.py                                                          │
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

import json
import os
import hashlib
import redis
import pickle
from typing import Any, Dict, List, Optional, Tuple
from src.utils.logger import setup_logger
from src.config.redis import get_redis_config
from src.config.settings import settings
from src.services.adk.lazy_mcp_tool import LazyMCPTool

logger = setup_logger(__name__)

# Prefixes for cache keys
MCP_SERVER_TOOLS_PREFIX = "mcp:server:tools:"
MCP_AGENT_TOOLS_PREFIX = "mcp:agent:tools:"


class MCPToolCache:
    """Cache for MCP tools using Redis.

    This class manages the MCP tool cache to avoid loading them repeatedly,
    improving performance.
    """

    def __init__(self):
        """Initializes the MCP tool cache."""
        logger.info(
            f"Initializing MCPToolCache. Configuration: TOOLS_CACHE_ENABLED={settings.TOOLS_CACHE_ENABLED}"
        )
        self.enabled = settings.TOOLS_CACHE_ENABLED

        if not self.enabled:
            logger.info("MCP tool cache is disabled")
            return

        try:
            redis_config = get_redis_config()
            logger.debug(
                f"Redis configuration: host={redis_config['host']}, port={redis_config['port']}, db={redis_config['db']}"
            )

            self.redis = redis.Redis(
                host=redis_config["host"],
                port=redis_config["port"],
                db=redis_config["db"],
                password=redis_config["password"],
                ssl=redis_config["ssl"],
                decode_responses=False,  # We need bytes for pickle
            )

            # Test Redis connection
            try:
                ping_result = self.redis.ping()
                logger.debug(f"Redis connection tested: {ping_result}")
            except Exception as e:
                logger.error(f"Failed to test Redis connection: {e}")

            self.ttl = settings.TOOLS_CACHE_TTL
            logger.info(f"MCP tool cache initialized, TTL: {self.ttl}s")
        except Exception as e:
            logger.error(f"Error initializing MCP tool cache: {e}")
            import traceback

            logger.error(f"Traceback: {traceback.format_exc()}")
            self.enabled = False

    def _get_server_key(self, server_config: Dict[str, Any]) -> str:
        """Generates a unique key for the MCP server.

        Args:
            server_config: MCP server configuration

        Returns:
            Unique key based on the server configuration
        """
        # Generate a hash of the server configuration
        server_str = json.dumps(server_config, sort_keys=True)
        server_hash = hashlib.md5(server_str.encode()).hexdigest()
        return f"{MCP_SERVER_TOOLS_PREFIX}{server_hash}"

    def _get_agent_key(self, agent_id: str, server_id: str) -> str:
        """Generates a unique key for the agent tools.

        Args:
            agent_id: Agent ID
            server_id: MCP server ID

        Returns:
            Unique key based on the agent and server
        """
        return f"{MCP_AGENT_TOOLS_PREFIX}{agent_id}:{server_id}"

    async def get_server_tools(
        self, server_config: Dict[str, Any]
    ) -> Optional[List[LazyMCPTool]]:
        """Gets MCP server tools from cache.

        Args:
            server_config: MCP server configuration

        Returns:
            List of LazyMCPTool or None if not in cache
        """
        if not self.enabled:
            return None

        try:
            key = self._get_server_key(server_config)
            cached_data = self.redis.get(key)

            if cached_data:
                tools = pickle.loads(cached_data)
                logger.info(f"MCP tools loaded from cache: {len(tools)} tools")
                return tools

            return None
        except Exception as e:
            logger.error(f"Error getting tools from cache: {e}")
            return None

    async def set_server_tools(
        self, server_config: Dict[str, Any], tools: List[LazyMCPTool]
    ) -> bool:
        """Stores MCP server tools in cache.

        Args:
            server_config: MCP server configuration
            tools: List of LazyMCPTool

        Returns:
            True if stored successfully, False otherwise
        """
        if not self.enabled:
            logger.debug("Cache is disabled, not storing server tools")
            return False

        try:
            key = self._get_server_key(server_config)
            logger.debug(f"Storing {len(tools)} tools in Redis cache with key: {key}")

            # Server details for debugging
            server_name = server_config.get("name", "")
            server_url = server_config.get("url", "")
            logger.debug(f"Server details: name={server_name}, url={server_url}")

            serialized_tools = pickle.dumps(tools)
            logger.debug(f"Tools serialized, size: {len(serialized_tools)} bytes")

            # Store in Redis
            self.redis.setex(key, self.ttl, serialized_tools)
            logger.info(
                f"MCP tools stored in cache: {len(tools)} tools. TTL: {self.ttl}s"
            )
            return True
        except Exception as e:
            logger.error(f"Error storing tools in cache: {e}")
            import traceback

            logger.error(f"Traceback: {traceback.format_exc()}")
            return False

    async def get_agent_tools(
        self, agent_id: str, server_id: str, current_tools_count: int = None
    ) -> Optional[Tuple[List[LazyMCPTool], int]]:
        """Gets agent tools from cache.

        Args:
            agent_id: Agent ID
            server_id: MCP server ID
            current_tools_count: Current number of configured tools for the agent.
                If provided, it is used to check if the cache needs to be updated.

        Returns:
            Tuple with list of tools and count, or None if not in cache
            or if the number of tools has changed.
        """
        if not self.enabled:
            return None

        try:
            key = self._get_agent_key(agent_id, server_id)
            cached_data = self.redis.get(key)

            if cached_data:
                tools_data = pickle.loads(cached_data)
                cached_tools, cached_tools_count = tools_data

                # Check if the number of configured tools has changed
                if (
                    current_tools_count is not None
                    and cached_tools_count != current_tools_count
                ):
                    logger.info(
                        f"Agent tools number changed: cache={cached_tools_count}, actual={current_tools_count}. Invalidating cache."
                    )
                    # Invalidate cache and return None to force reload
                    await self.invalidate_agent_cache(agent_id, server_id)
                    return None

                logger.info(f"Agent tools loaded from cache: {len(cached_tools)} tools")
                return tools_data

            return None
        except Exception as e:
            logger.error(f"Error getting agent tools from cache: {e}")
            return None

    async def set_agent_tools(
        self, agent_id: str, server_id: str, tools: List[LazyMCPTool], tools_count: int
    ) -> bool:
        """Stores agent tools in cache.

        Args:
            agent_id: Agent ID
            server_id: MCP server ID
            tools: List of LazyMCPTool
            tools_count: Total number of available tools

        Returns:
            True if stored successfully, False otherwise
        """
        if not self.enabled:
            logger.debug("Cache is disabled, not storing agent tools")
            return False

        try:
            key = self._get_agent_key(agent_id, server_id)
            logger.debug(
                f"Storing {len(tools)} agent tools for {agent_id} in cache with key: {key}"
            )

            tools_data = (tools, tools_count)
            serialized_data = pickle.dumps(tools_data)
            logger.debug(f"Agent data serialized, size: {len(serialized_data)} bytes")

            # Store in Redis
            self.redis.setex(key, self.ttl, serialized_data)
            logger.info(
                f"Agent tools stored in cache: {len(tools)} tools. TTL: {self.ttl}s"
            )
            return True
        except Exception as e:
            logger.error(f"Error storing agent tools in cache: {e}")
            import traceback

            logger.error(f"Traceback: {traceback.format_exc()}")
            return False

    async def invalidate_server_cache(self, server_config: Dict[str, Any]) -> bool:
        """Invalidates the cache for a specific server.

        Args:
            server_config: MCP server configuration

        Returns:
            True if cache was invalidated successfully, False otherwise
        """
        if not self.enabled:
            return False

        try:
            key = self._get_server_key(server_config)
            self.redis.delete(key)
            logger.info(f"MCP server cache invalidated")
            return True
        except Exception as e:
            logger.error(f"Error invalidating server cache: {e}")
            return False

    async def invalidate_agent_cache(self, agent_id: str, server_id: str) -> bool:
        """Invalidates the cache for a specific agent.

        Args:
            agent_id: Agent ID
            server_id: MCP server ID

        Returns:
            True if cache was invalidated successfully, False otherwise
        """
        if not self.enabled:
            return False

        try:
            key = self._get_agent_key(agent_id, server_id)
            self.redis.delete(key)
            logger.info(f"MCP agent cache invalidated")
            return True
        except Exception as e:
            logger.error(f"Error invalidating agent cache: {e}")
            return False

    async def invalidate_all_caches(self) -> bool:
        """Invalidates all MCP tool caches.

        Returns:
            True if all caches were invalidated successfully, False otherwise
        """
        if not self.enabled:
            return False

        try:
            # Search all MCP cache keys
            server_keys = self.redis.keys(f"{MCP_SERVER_TOOLS_PREFIX}*")
            agent_keys = self.redis.keys(f"{MCP_AGENT_TOOLS_PREFIX}*")

            # Remove all found keys
            all_keys = server_keys + agent_keys
            if all_keys:
                self.redis.delete(*all_keys)

            logger.info(f"All MCP caches invalidated: {len(all_keys)} keys")
            return True
        except Exception as e:
            logger.error(f"Error invalidating all caches: {e}")
            return False


# Global cache instance
mcp_tool_cache = MCPToolCache()
