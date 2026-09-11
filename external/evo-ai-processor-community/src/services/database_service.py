"""
Database service for async operations.

This service provides async database operations using asyncpg.
"""

import os
import logging
from typing import Any, Dict, List, Optional
import asyncpg

logger = logging.getLogger(__name__)


class DatabaseService:
    """Service for async database operations."""

    def __init__(self, connection_string: str):
        """
        Initialize database service.

        Args:
            connection_string: PostgreSQL connection string
        """
        self.connection_string = connection_string
        self._pool: Optional[asyncpg.Pool] = None

    async def get_pool(self) -> asyncpg.Pool:
        """Get or create connection pool."""
        if self._pool is None:
            # Pass the raw DSN straight to asyncpg: its DSN parser accepts libpq's
            # `sslmode` natively. Do NOT rewrite it to `ssl=` (what the SQLAlchemy
            # asyncpg dialect needs) — in a raw DSN asyncpg reads `ssl` as a server
            # GUC and raises CantChangeRuntimeParamError, which broke sslmode=require.
            #
            # max_inactive_connection_lifetime retires a pooled connection that
            # has sat idle for longer than this, so it is closed and reopened
            # before Docker Swarm/IPVS reaps the idle conntrack entry (~15 min)
            # and hands out a dead socket. 300s is asyncpg's default; we set it
            # explicitly so the resilience does not depend on an upstream default.
            self._pool = await asyncpg.create_pool(
                self.connection_string,
                min_size=1,
                max_size=10,
                command_timeout=60,
                max_inactive_connection_lifetime=300,
            )
        return self._pool

    async def execute(
        self,
        query: str,
        *args: Any
    ) -> str:
        """
        Execute a query that doesn't return results.

        Args:
            query: SQL query
            *args: Query parameters

        Returns:
            Result status string
        """
        pool = await self.get_pool()
        async with pool.acquire() as connection:
            return await connection.execute(query, *args)

    async def fetch_one(
        self,
        query: str,
        *args: Any
    ) -> Optional[Dict[str, Any]]:
        """
        Fetch a single row.

        Args:
            query: SQL query
            *args: Query parameters

        Returns:
            Dictionary with row data or None
        """
        pool = await self.get_pool()
        async with pool.acquire() as connection:
            row = await connection.fetchrow(query, *args)
            return dict(row) if row else None

    async def fetch_all(
        self,
        query: str,
        *args: Any
    ) -> List[Dict[str, Any]]:
        """
        Fetch all rows.

        Args:
            query: SQL query
            *args: Query parameters

        Returns:
            List of dictionaries with row data
        """
        pool = await self.get_pool()
        async with pool.acquire() as connection:
            rows = await connection.fetch(query, *args)
            return [dict(row) for row in rows]

    async def close(self):
        """Close the connection pool."""
        if self._pool:
            await self._pool.close()
            self._pool = None


# Global database service instance
_db_service: Optional[DatabaseService] = None


def get_database_service() -> DatabaseService:
    """Get or create global database service instance."""
    global _db_service

    if _db_service is None:
        connection_string = os.getenv(
            "POSTGRES_CONNECTION_STRING",
            "postgresql://postgres:root@localhost:5432/evoai-crm"
        )
        _db_service = DatabaseService(connection_string)

    return _db_service
