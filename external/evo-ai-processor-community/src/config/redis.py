"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: redis.py                                                              │
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

"""
Redis configuration module.

This module defines the Redis connection settings and provides
function to create a Redis connection pool for the application.
"""

import os
import redis
from dotenv import load_dotenv
import logging

# Load environment variables
load_dotenv()

logger = logging.getLogger(__name__)


def get_redis_config():
    """
    Get Redis configuration from environment variables.

    Returns:
        dict: Redis configuration parameters
    """
    return {
        "host": os.getenv("REDIS_HOST", "localhost"),
        "port": int(os.getenv("REDIS_PORT", 6379)),
        "db": int(os.getenv("REDIS_DB", 0)),
        "password": os.getenv("REDIS_PASSWORD", None),
        "ssl": os.getenv("REDIS_SSL", "false").lower() == "true",
        "key_prefix": os.getenv("REDIS_KEY_PREFIX", "a2a:"),
        "default_ttl": int(os.getenv("REDIS_TTL", 3600)),
    }


def create_redis_pool(config=None):
    """
    Create and return a Redis connection pool.

    Args:
        config (dict, optional): Redis configuration. If None,
                                 configuration is loaded from environment

    Returns:
        redis.ConnectionPool: Redis connection pool
    """
    if config is None:
        config = get_redis_config()

    try:
        connection_pool = redis.ConnectionPool(
            host=config["host"],
            port=config["port"],
            db=config["db"],
            password=config["password"] if config["password"] else None,
            ssl=config["ssl"],
            decode_responses=True,
        )
        # Test the connection
        redis_client = redis.Redis(connection_pool=connection_pool)
        redis_client.ping()
        logger.info(
            f"Redis connection successful: {config['host']}:{config['port']}, "
            f"db={config['db']}, ssl={config['ssl']}"
        )
        return connection_pool
    except redis.RedisError as e:
        logger.error(f"Redis connection error: {e}")
        raise


def get_redis_connection(config=None):
    """
    Get a Redis connection instance.

    Args:
        config (dict, optional): Redis configuration. If None,
                                 configuration is loaded from environment

    Returns:
        redis.Redis: Redis client instance
    """
    if config is None:
        config = get_redis_config()

    try:
        redis_client = redis.Redis(
            host=config["host"],
            port=config["port"],
            db=config["db"],
            password=config["password"] if config["password"] else None,
            ssl=config["ssl"],
            decode_responses=True,
        )
        return redis_client
    except redis.RedisError as e:
        logger.error(f"Redis connection error: {e}")
        raise
