"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: service_providers.py                                                  │
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
from google.adk.sessions import DatabaseSessionService
from dotenv import load_dotenv

load_dotenv()

from src.utils.logger import setup_logger

logger = setup_logger(__name__)


def get_async_db_url(db_url: str) -> str:
    """Convert PostgreSQL connection string to async format (postgresql+asyncpg://).

    asyncpg does not accept the libpq-style ``sslmode`` query parameter — it
    uses ``ssl`` instead. We rewrite the URL so a single DSN with
    ``sslmode=require`` (used by psycopg2 and the rest of the stack) still
    works when the async driver picks it up.

    Args:
        db_url: PostgreSQL connection string (postgresql://...)

    Returns:
        Async PostgreSQL connection string (postgresql+asyncpg://...) with
        any ``sslmode=`` rewritten to ``ssl=``.
    """
    if db_url.startswith("postgresql://"):
        result = db_url.replace("postgresql://", "postgresql+asyncpg://", 1)
    elif db_url.startswith("postgresql+asyncpg://"):
        result = db_url
    else:
        return db_url

    # asyncpg rejects `sslmode=`; translate it to `ssl=` keeping the value.
    return result.replace("?sslmode=", "?ssl=").replace("&sslmode=", "&ssl=")


# Initialize session service based on AI engine
# DatabaseSessionService requires async driver (asyncpg)
db_url = os.getenv("POSTGRES_CONNECTION_STRING")
async_db_url = get_async_db_url(db_url) if db_url else None

# DatabaseSessionService forwards **kwargs straight to create_async_engine, so we
# harden its pool here. Without this it uses SQLAlchemy defaults (no pre-ping, no
# recycle) and every agent turn reads/writes the ADK session through it — a
# connection reaped while idle (Docker Swarm/IPVS drops idle conntrack entries
# after ~15 min) then surfaces as an intermittent 500 on the next turn.
# pool_pre_ping revalidates a pooled connection before handing it out, so a dead
# one is transparently replaced instead of failing the request; pool_recycle
# retires connections before they can go stale. asyncpg does not accept libpq
# keepalive params, so pre_ping + recycle are the resilience levers here.
session_service = DatabaseSessionService(
    db_url=async_db_url,
    pool_pre_ping=True,
    pool_recycle=1800,
)


# Initialize artifacts service using the factory
from src.services.adk.artifacts.artifact_factory import get_artifact_service

artifacts_service = get_artifact_service()
logger.info(
    f"Initialized artifacts service: {type(artifacts_service).__name__} from module: {type(artifacts_service).__module__}"
)


# Initialize memory service with retention limits
from src.services.memory_service import memory_service
