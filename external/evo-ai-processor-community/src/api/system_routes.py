"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: system_routes.py                                                      │
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

from fastapi import APIRouter, status
from fastapi.responses import JSONResponse

from src.schemas.health import OverallHealth, HealthStatus
from src.services.health_service import health_service
from src.utils.logger import setup_logger

logger = setup_logger(__name__)

router = APIRouter(
    tags=["system"],
)


@router.get(
    "/health",
    summary="Health check",
    description="Comprehensive health check including database, Redis, and system components",
    response_model=OverallHealth,
    responses={
        200: {
            "description": "System is healthy or degraded",
            "model": OverallHealth,
        },
        503: {
            "description": "System is unhealthy", 
            "model": OverallHealth,
        },
    },
)
async def health_check() -> JSONResponse:
    """
    Comprehensive health check endpoint
    
    Returns detailed health information about all system components including:
    - Database connectivity and performance
    - Database connection pool status
    - Redis connectivity
    - System memory usage
    
    Status codes:
    - 200: System is healthy or degraded but functional
    - 503: System is unhealthy and may not function properly
    """
    try:
        health = await health_service.check_health()
        
        # Determine HTTP status code based on health status
        status_code = status.HTTP_200_OK
        if health.status == HealthStatus.UNHEALTHY:
            status_code = status.HTTP_503_SERVICE_UNAVAILABLE
        elif health.status == HealthStatus.DEGRADED:
            status_code = status.HTTP_200_OK  # Still return 200 for degraded but include status
        
        return JSONResponse(
            status_code=status_code,
            content=health.model_dump()
        )
        
    except Exception as e:
        logger.error(f"Health check failed with unexpected error: {e}")
        
        # Return unhealthy status in case of unexpected errors
        from datetime import datetime, timezone
        error_health = OverallHealth(
            status=HealthStatus.UNHEALTHY,
            timestamp=datetime.now(timezone.utc),
            duration="0.000s",
            components=[],
        )
        
        return JSONResponse(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            content=error_health.model_dump()
        )


@router.get(
    "/ready",
    summary="Ready check",
    description="Readiness check to verify if the server is ready to serve requests",
    response_model=OverallHealth,
    responses={
        200: {
            "description": "System is ready to serve requests",
            "model": OverallHealth,
        },
        503: {
            "description": "System is not ready to serve requests",
            "model": OverallHealth,
        },
    },
)
async def ready_check() -> JSONResponse:
    """
    Readiness check endpoint for Kubernetes readiness probe
    
    Performs lightweight checks to determine if the service is ready to handle traffic:
    - Database ping connectivity
    - Redis connectivity
    
    This is typically used by Kubernetes to determine when to route traffic to the pod.
    
    Status codes:
    - 200: Service is ready to handle requests
    - 503: Service is not ready (should not receive traffic)
    """
    try:
        readiness = await health_service.check_readiness()
        
        # For readiness, only healthy status should return 200
        status_code = status.HTTP_200_OK
        if readiness.status != HealthStatus.HEALTHY:
            status_code = status.HTTP_503_SERVICE_UNAVAILABLE
        
        return JSONResponse(
            status_code=status_code,
            content=readiness.model_dump()
        )
        
    except Exception as e:
        logger.error(f"Readiness check failed with unexpected error: {e}")
        
        # Return not ready status in case of unexpected errors
        from datetime import datetime, timezone
        error_readiness = OverallHealth(
            status=HealthStatus.UNHEALTHY,
            timestamp=datetime.now(timezone.utc),
            duration="0.000s",
            components=[],
        )
        
        return JSONResponse(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            content=error_readiness.model_dump()
        )
