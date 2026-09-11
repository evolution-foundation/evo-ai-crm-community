"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: auth.py                                                               │
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

from typing import Optional, Dict, Any, List
from pydantic import AliasChoices, BaseModel, Field

# ============================================================================
# EvoAuth Schemas
# ============================================================================

class EvoAuthUser(BaseModel):
    """Evo Auth user structure"""
    id: str
    name: str
    email: str
    display_name: Optional[str] = None
    availability: Optional[str] = "online"
    mfa_enabled: Optional[bool] = False
    confirmed: Optional[bool] = True
    role: Optional[Dict[str, Any]] = None
    type: Optional[str] = None

class EvoAuthFeature(BaseModel):
    """Feature structure"""
    key: str
    value: Any

class EvoAuthPlan(BaseModel):
    """Active plan structure"""
    id: str
    plan_name: str
    is_active: bool
    is_custom: bool
    starts_at: str
    ends_at: Optional[str] = None
    features: List[EvoAuthFeature] = []

class EvoAuthAccount(BaseModel):
    """Evo Auth account structure"""
    id: str
    name: str
    status: str
    locale: str
    created_at: Optional[str] = None
    updated_at: Optional[str] = None
    active_plan: Optional[EvoAuthPlan] = None

class TokenInfo(BaseModel):
    """Token information structure from validate endpoint

    evo-auth names this field `access_token` for bearer tokens and `token` for
    api_access_token ones; both are accepted and normalized to `access_token`,
    which is what every consumer of token_info reads.
    """
    access_token: str = Field(validation_alias=AliasChoices("access_token", "token"))
    type: str = "bearer"

class EvoAuthResponse(BaseModel):
    """Evo Auth API response structure"""
    user: EvoAuthUser
    accounts: List[EvoAuthAccount]
    token: Optional[TokenInfo] = None
    metadata: Optional[Dict[str, Any]] = None  # For agent_id and other metadata
    
    class Config:
        extra = "allow"  # Allow extra fields for flexibility

class PermissionResponse(BaseModel):
    """Response model for permission validation"""
    has_permission: bool
    user_id: Optional[str] = None

class UserContext(BaseModel):
    """User context structure"""
    user_id: str
    email: str
    name: str
    display_name: Optional[str] = None
    availability: str
    mfa_enabled: bool
    confirmed: bool
    role: Optional[Dict[str, Any]] = None
    type: Optional[str] = None
    token_info: Optional[TokenInfo] = None
    