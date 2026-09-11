"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: health_service.py                                                     │
│ Developed by: Danilo Leone                                                   │
│ Creation date: August 21, 2025                                               │
│ Contact: contato@evolution-api.com                                           │
├──────────────────────────────────────────────────────────────────────────────┤
│ @copyright © Evolution API 2024. All rights reserved.                        │
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

import asyncio
import time
import psutil
from datetime import datetime, timezone
from typing import List
from sqlalchemy import text
from sqlalchemy.orm import Session
from sqlalchemy.exc import SQLAlchemyError
from redis import Redis
from redis.exceptions import RedisError

from src.schemas.health import ComponentHealth, OverallHealth, HealthStatus
from src.config.database import get_db
from src.config.redis import get_redis_connection
from src.config.settings import settings
from src.utils.logger import setup_logger

logger = setup_logger(__name__)


class HealthService:
    """Service for performing health checks on system components"""

    def __init__(self):
        # Load settings from configuration
        self.db_health_timeout = settings.HEALTH_CHECK_TIMEOUT
        self.db_readiness_timeout = settings.READINESS_CHECK_TIMEOUT
        self.db_query = settings.DB_HEALTH_CHECK_QUERY
        self.db_conn_threshold_degraded = settings.DB_CONN_THRESHOLD_DEGRADED
        self.db_wait_count_threshold = settings.DB_WAIT_COUNT_THRESHOLD
        self.memory_threshold_warning = settings.MEMORY_THRESHOLD_WARNING
        self.memory_threshold_critical = settings.MEMORY_THRESHOLD_CRITICAL

    async def check_health(self) -> OverallHealth:
        """Perform comprehensive health checks"""
        start_time = time.time()
        
        components = []
        
        # Check database
        db_component = await self._check_database()
        components.append(db_component)
        
        # Check database connections
        db_connections_component = await self._check_database_connections()
        components.append(db_connections_component)
        
        # Check Redis
        redis_component = await self._check_redis()
        components.append(redis_component)
        
        # Check memory
        memory_component = await self._check_memory()
        components.append(memory_component)
        
        duration = time.time() - start_time
        overall_status = self._determine_overall_status(components)
        
        return OverallHealth(
            status=overall_status,
            timestamp=datetime.now(timezone.utc),
            duration=f"{duration:.3f}s",
            components=components
        )

    async def check_readiness(self) -> OverallHealth:
        """Perform readiness checks (lighter than health checks)"""
        start_time = time.time()
        
        components = []
        
        # Only check database ping for readiness
        db_ping_component = await self._check_database_ping()
        components.append(db_ping_component)
        
        # Quick Redis check
        redis_component = await self._check_redis()
        components.append(redis_component)
        
        duration = time.time() - start_time
        overall_status = self._determine_overall_status(components)
        
        return OverallHealth(
            status=overall_status,
            timestamp=datetime.now(timezone.utc),
            duration=f"{duration:.3f}s",
            components=components
        )

    async def _check_database(self) -> ComponentHealth:
        """Comprehensive database health check"""
        start_time = time.time()
        
        try:
            # Get database session
            db_gen = get_db()
            db: Session = next(db_gen)
            
            try:
                # Test connection with timeout
                future = asyncio.get_event_loop().run_in_executor(
                    None, 
                    lambda: db.execute(text(self.db_query)).scalar()
                )
                
                await asyncio.wait_for(future, timeout=self.db_health_timeout)
                
                duration = time.time() - start_time
                return ComponentHealth(
                    name="database",
                    status=HealthStatus.HEALTHY,
                    message="Database is healthy",
                    timestamp=datetime.now(timezone.utc),
                    duration=f"{duration:.3f}s"
                )
                
            except asyncio.TimeoutError:
                duration = time.time() - start_time
                return ComponentHealth(
                    name="database",
                    status=HealthStatus.UNHEALTHY,
                    message="Database query timeout",
                    timestamp=datetime.now(timezone.utc),
                    duration=f"{duration:.3f}s"
                )
                
            finally:
                db.close()
                
        except SQLAlchemyError as e:
            duration = time.time() - start_time
            return ComponentHealth(
                name="database",
                status=HealthStatus.UNHEALTHY,
                message=f"Database error: {str(e)}",
                timestamp=datetime.now(timezone.utc),
                duration=f"{duration:.3f}s"
            )
        except Exception as e:
            duration = time.time() - start_time
            logger.error(f"Unexpected error in database health check: {e}")
            return ComponentHealth(
                name="database",
                status=HealthStatus.UNHEALTHY,
                message=f"Unexpected database error: {str(e)}",
                timestamp=datetime.now(timezone.utc),
                duration=f"{duration:.3f}s"
            )

    async def _check_database_connections(self) -> ComponentHealth:
        """Check database connection pool health"""
        start_time = time.time()
        
        try:
            from src.config.database import engine
            
            pool = engine.pool
            
            # Get connection pool stats
            size = pool.size()
            checked_in = pool.checkedin()
            checked_out = pool.checkedout()
            overflow = pool.overflow()
            
            details = {
                "pool_size": size,
                "checked_in": checked_in,
                "checked_out": checked_out,
                "overflow": overflow,
                "total_connections": checked_in + checked_out
            }
            
            duration = time.time() - start_time
            
            # Check if connection pool is healthy using configured thresholds
            total_connections = checked_in + checked_out
            if total_connections > self.db_conn_threshold_degraded:
                return ComponentHealth(
                    name="database_connections",
                    status=HealthStatus.DEGRADED,
                    message=f"High number of database connections ({total_connections} > {self.db_conn_threshold_degraded})",
                    details=details,
                    timestamp=datetime.now(timezone.utc),
                    duration=f"{duration:.3f}s"
                )
            
            return ComponentHealth(
                name="database_connections",
                status=HealthStatus.HEALTHY,
                message="Database connections are healthy",
                details=details,
                timestamp=datetime.now(timezone.utc),
                duration=f"{duration:.3f}s"
            )
            
        except Exception as e:
            duration = time.time() - start_time
            logger.error(f"Error checking database connections: {e}")
            return ComponentHealth(
                name="database_connections",
                status=HealthStatus.UNHEALTHY,
                message=f"Failed to check database connections: {str(e)}",
                timestamp=datetime.now(timezone.utc),
                duration=f"{duration:.3f}s"
            )

    async def _check_database_ping(self) -> ComponentHealth:
        """Simple database ping for readiness"""
        start_time = time.time()
        
        try:
            db_gen = get_db()
            db: Session = next(db_gen)
            
            try:
                # Quick ping with shorter timeout
                future = asyncio.get_event_loop().run_in_executor(
                    None, 
                    lambda: db.execute(text("SELECT 1")).scalar()
                )
                
                await asyncio.wait_for(future, timeout=self.db_readiness_timeout)
                
                duration = time.time() - start_time
                return ComponentHealth(
                    name="database_ping",
                    status=HealthStatus.HEALTHY,
                    message="Database ping successful",
                    timestamp=datetime.now(timezone.utc),
                    duration=f"{duration:.3f}s"
                )
                
            except asyncio.TimeoutError:
                duration = time.time() - start_time
                return ComponentHealth(
                    name="database_ping",
                    status=HealthStatus.UNHEALTHY,
                    message="Database ping timeout",
                    timestamp=datetime.now(timezone.utc),
                    duration=f"{duration:.3f}s"
                )
                
            finally:
                db.close()
                
        except Exception as e:
            duration = time.time() - start_time
            return ComponentHealth(
                name="database_ping",
                status=HealthStatus.UNHEALTHY,
                message=f"Database ping failed: {str(e)}",
                timestamp=datetime.now(timezone.utc),
                duration=f"{duration:.3f}s"
            )

    async def _check_redis(self) -> ComponentHealth:
        """Check Redis connection"""
        start_time = time.time()
        
        try:
            redis_client: Redis = get_redis_connection()
            
            # Test Redis connection
            future = asyncio.get_event_loop().run_in_executor(
                None, 
                redis_client.ping
            )
            
            await asyncio.wait_for(future, timeout=2.0)
            
            # Get Redis info
            info = await asyncio.get_event_loop().run_in_executor(
                None, 
                redis_client.info
            )
            
            details = {
                "connected_clients": info.get("connected_clients", 0),
                "used_memory_human": info.get("used_memory_human", "unknown"),
                "redis_version": info.get("redis_version", "unknown")
            }
            
            duration = time.time() - start_time
            return ComponentHealth(
                name="redis",
                status=HealthStatus.HEALTHY,
                message="Redis is healthy",
                details=details,
                timestamp=datetime.now(timezone.utc),
                duration=f"{duration:.3f}s"
            )
            
        except asyncio.TimeoutError:
            duration = time.time() - start_time
            return ComponentHealth(
                name="redis",
                status=HealthStatus.UNHEALTHY,
                message="Redis connection timeout",
                timestamp=datetime.now(timezone.utc),
                duration=f"{duration:.3f}s"
            )
        except RedisError as e:
            duration = time.time() - start_time
            return ComponentHealth(
                name="redis",
                status=HealthStatus.UNHEALTHY,
                message=f"Redis error: {str(e)}",
                timestamp=datetime.now(timezone.utc),
                duration=f"{duration:.3f}s"
            )
        except Exception as e:
            duration = time.time() - start_time
            logger.error(f"Unexpected error in Redis health check: {e}")
            return ComponentHealth(
                name="redis",
                status=HealthStatus.UNHEALTHY,
                message=f"Unexpected Redis error: {str(e)}",
                timestamp=datetime.now(timezone.utc),
                duration=f"{duration:.3f}s"
            )

    async def _check_memory(self) -> ComponentHealth:
        """Check system memory usage"""
        start_time = time.time()
        
        try:
            # Get memory information
            memory = psutil.virtual_memory()
            process = psutil.Process()
            process_memory = process.memory_info()
            
            # Convert to MB
            system_used_mb = memory.used / (1024 * 1024)
            system_total_mb = memory.total / (1024 * 1024)
            process_rss_mb = process_memory.rss / (1024 * 1024)
            process_vms_mb = process_memory.vms / (1024 * 1024)
            
            details = {
                "system_memory_used_mb": round(system_used_mb, 2),
                "system_memory_total_mb": round(system_total_mb, 2),
                "system_memory_percent": memory.percent,
                "process_memory_rss_mb": round(process_rss_mb, 2),
                "process_memory_vms_mb": round(process_vms_mb, 2)
            }
            
            duration = time.time() - start_time
            
            # Determine status based on process memory usage
            if process_rss_mb > self.memory_threshold_critical:
                return ComponentHealth(
                    name="memory",
                    status=HealthStatus.UNHEALTHY,
                    message="Critical memory usage",
                    details=details,
                    timestamp=datetime.now(timezone.utc),
                    duration=f"{duration:.3f}s"
                )
            elif process_rss_mb > self.memory_threshold_warning:
                return ComponentHealth(
                    name="memory",
                    status=HealthStatus.DEGRADED,
                    message="High memory usage",
                    details=details,
                    timestamp=datetime.now(timezone.utc),
                    duration=f"{duration:.3f}s"
                )
            else:
                return ComponentHealth(
                    name="memory",
                    status=HealthStatus.HEALTHY,
                    message="Memory usage is normal",
                    details=details,
                    timestamp=datetime.now(timezone.utc),
                    duration=f"{duration:.3f}s"
                )
                
        except Exception as e:
            duration = time.time() - start_time
            logger.error(f"Error checking memory: {e}")
            return ComponentHealth(
                name="memory",
                status=HealthStatus.UNHEALTHY,
                message=f"Failed to check memory: {str(e)}",
                timestamp=datetime.now(timezone.utc),
                duration=f"{duration:.3f}s"
            )

    def _determine_overall_status(self, components: List[ComponentHealth]) -> HealthStatus:
        """Determine overall status based on component statuses"""
        overall_status = HealthStatus.HEALTHY
        
        for component in components:
            if component.status == HealthStatus.UNHEALTHY:
                return HealthStatus.UNHEALTHY
            
            if component.status == HealthStatus.DEGRADED and overall_status != HealthStatus.UNHEALTHY:
                overall_status = HealthStatus.DEGRADED
        
        return overall_status


# Global health service instance
health_service = HealthService()
