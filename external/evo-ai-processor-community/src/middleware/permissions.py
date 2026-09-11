"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: permissions.py                                                        │
│ Developed by: Davidson Gomes                                                 │
│ Creation date: January 27, 2025                                              │
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

from fastapi import Request
from fastapi.security import HTTPBearer
from src.utils.logger import setup_logger
from src.services.permission_service import permission_service

logger = setup_logger(__name__)

# Security scheme for Swagger documentation
security = HTTPBearer()

class PermissionChecker:
    """FastAPI dependency for permission checking"""
    
    def __init__(self, resource: str, action: str):
        self.resource = resource
        self.action = action
    
    async def __call__(self, request: Request) -> None:
        """FastAPI dependency that validates permissions"""
        service = permission_service()
        await service.validate_permission(request, self.resource, self.action)


# Convenience function for creating permission dependencies
def RequirePermission(resource: str, action: str):
    """
    Create a FastAPI dependency for permission checking.
    
    Usage:
        @router.get("/agents")
        async def list_agents(
            _: None = Depends(RequirePermission("ai_agents", "read"))
        ):
            # Permission validated, proceed with route logic
            return agents
    
    Args:
        resource: Resource name (e.g., "ai_agents")
        action: Action name (e.g., "read", "create", "update", "delete")
    
    Returns:
        FastAPI dependency that validates permissions
    """
    return PermissionChecker(resource, action)
