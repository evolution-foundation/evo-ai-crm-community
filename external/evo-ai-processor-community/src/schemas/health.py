"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: health.py                                                             │
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

from datetime import datetime
from typing import Dict, Any, List, Optional
from enum import Enum

from pydantic import BaseModel, field_serializer


class HealthStatus(str, Enum):
    """Health status enumeration"""
    HEALTHY = "healthy"
    UNHEALTHY = "unhealthy" 
    DEGRADED = "degraded"


class ComponentHealth(BaseModel):
    """Health status of a single component"""
    name: str
    status: HealthStatus
    message: Optional[str] = None
    details: Optional[Dict[str, Any]] = None
    timestamp: datetime
    duration: str  # Duration as string for consistency with Go implementation
    
    @field_serializer('timestamp')
    def serialize_timestamp(self, timestamp: datetime) -> str:
        """Serialize timestamp to ISO format with Z suffix"""
        return timestamp.isoformat() + "Z"


class OverallHealth(BaseModel):
    """Overall system health"""
    status: HealthStatus
    timestamp: datetime
    duration: str  # Duration as string for consistency with Go implementation
    components: List[ComponentHealth]
    
    @field_serializer('timestamp')
    def serialize_timestamp(self, timestamp: datetime) -> str:
        """Serialize timestamp to ISO format with Z suffix"""
        return timestamp.isoformat() + "Z"
