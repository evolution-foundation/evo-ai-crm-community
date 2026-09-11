"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: schemas.py                                                            │
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

from pydantic import BaseModel, Field, validator, UUID4, ConfigDict
from typing import Optional, Dict, Any, List
from datetime import datetime
from uuid import UUID
import re
from src.schemas.agent_config import LLMConfig

class ApiKey(BaseModel):
    id: UUID4
    name: str
    provider: str
    created_at: datetime
    updated_at: Optional[datetime] = None
    is_active: bool

    model_config = ConfigDict(from_attributes=True)

class AgentBase(BaseModel):
    name: Optional[str] = Field(
        None, description="Agent name (no spaces or special characters)"
    )
    description: Optional[str] = Field(None, description="Agent description")
    role: Optional[str] = Field(None, description="Agent role in the system")
    goal: Optional[str] = Field(None, description="Agent goal or objective")
    type: str = Field(
        ...,
        description="Agent type (llm, sequential, parallel, loop, a2a, workflow, task, external)",
    )
    model: Optional[str] = Field(
        None, description="Agent model (required only for llm type)"
    )
    api_key_id: Optional[UUID4] = Field(
        None, description="Reference to a stored API Key ID"
    )
    instruction: Optional[str] = None
    card_url: Optional[str] = Field(
        None, description="Agent card URL (required for a2a type)"
    )
    folder_id: Optional[UUID4] = Field(
        None, description="ID of the folder this agent belongs to"
    )
    config: Any = Field(None, description="Agent configuration based on type")

    @validator("name")
    def validate_name(cls, v, values):
        if values.get("type") == "a2a":
            return v

        if not v:
            raise ValueError("Name is required for non-a2a agent types")

        if not re.match(r"^[a-zA-Z0-9_-]+$", v):
            raise ValueError("Agent name cannot contain spaces or special characters")
        return v

    @validator("type")
    def validate_type(cls, v):
        if v not in [
            "llm",
            "sequential",
            "parallel",
            "loop",
            "a2a",
            "workflow",
            "task",
            "external",
        ]:
            raise ValueError(
                "Invalid agent type. Must be: llm, sequential, parallel, loop, a2a, workflow, task or external"
            )
        return v

    @validator("card_url")
    def validate_card_url(cls, v, values):
        if "type" in values and values["type"] == "a2a":
            if not v:
                raise ValueError("card_url is required for a2a type agents")
            if not v.endswith("/.well-known/agent.json"):
                raise ValueError("card_url must end with /.well-known/agent.json")
        return v

    @validator("model")
    def validate_model(cls, v, values):
        if "type" in values and values["type"] == "llm" and not v:
            raise ValueError("Model is required for llm type agents")
        return v

    @validator("api_key_id")
    def validate_api_key_id(cls, v, values):
        return v

    @validator("config")
    def validate_config(cls, v, values):
        if "type" in values and values["type"] == "a2a":
            return v or {}

        if "type" not in values:
            return v

        # For workflow agents, we do not perform any validation
        if "type" in values and values["type"] == "workflow":
            return v

        if not v and values.get("type") != "a2a":
            raise ValueError(
                f"Configuration is required for {values.get('type')} agent type"
            )

        if values["type"] == "llm":
            if isinstance(v, dict):
                try:
                    # Store original dict to preserve all fields
                    original_dict = v.copy()
                    # Validate with LLMConfig
                    llm_config = LLMConfig(**v)
                    # Convert back to dict to ensure compatibility with agent_service processing
                    validated_dict = llm_config.model_dump(exclude_unset=True)
                    # Preserve any additional fields that might not be in LLMConfig
                    for key, value in original_dict.items():
                        if key not in LLMConfig.model_fields:
                            validated_dict[key] = value
                    v = validated_dict
                except Exception as e:
                    raise ValueError(f"Invalid LLM configuration for agent: {str(e)}")
            elif isinstance(v, LLMConfig):
                # Convert LLMConfig object to dict for consistency
                v = v.model_dump(exclude_unset=True)
        elif values["type"] in ["sequential", "parallel", "loop"]:
            if not isinstance(v, dict):
                raise ValueError(f'Invalid configuration for agent {values["type"]}')
            if "sub_agents" not in v:
                raise ValueError(f'Agent {values["type"]} must have sub_agents')
            if not isinstance(v["sub_agents"], list):
                raise ValueError("sub_agents must be a list")
            if not v["sub_agents"]:
                raise ValueError(
                    f'Agent {values["type"]} must have at least one sub-agent'
                )
        elif values["type"] == "task":
            if not isinstance(v, dict):
                raise ValueError(f'Invalid configuration for agent {values["type"]}')
            if "tasks" not in v:
                raise ValueError(f'Agent {values["type"]} must have tasks')
            if not isinstance(v["tasks"], list):
                raise ValueError("tasks must be a list")
            if not v["tasks"]:
                raise ValueError(f'Agent {values["type"]} must have at least one task')
            for task in v["tasks"]:
                if not isinstance(task, dict):
                    raise ValueError("Each task must be a dictionary")
                required_fields = ["agent_id", "description", "expected_output"]
                for field in required_fields:
                    if field not in task:
                        raise ValueError(f"Task missing required field: {field}")

            if "sub_agents" in v and v["sub_agents"] is not None:
                if not isinstance(v["sub_agents"], list):
                    raise ValueError("sub_agents must be a list")

            return v

        return v

class Agent(AgentBase):
    id: UUID4
    created_at: datetime
    updated_at: Optional[datetime] = None
    card_url: Optional[str] = None
    folder_id: Optional[UUID4] = None

    class Config:
        from_attributes = True

    @validator("card_url", pre=True)
    def set_card_url(cls, v, values):
        if v:
            return v

        if "id" in values:
            from os import getenv

            return f"{getenv('API_URL', '')}/api/v1/a2a/{values['id']}/.well-known/agent.json"

        return v

class ToolConfig(BaseModel):
    id: str
    name: str
    description: str
    tags: List[str] = Field(default_factory=list)
    examples: List[str] = Field(default_factory=list)
    inputModes: List[str] = Field(default_factory=list)
    outputModes: List[str] = Field(default_factory=list)
    config: Optional[Dict[str, Any]] = Field(
        default_factory=dict,
        description="Tool configuration including environment variables",
    )

class MCPServer(BaseModel):
    id: UUID
    name: str
    description: Optional[str] = None
    config_type: str = Field(default="studio")
    config_json: Dict[str, Any] = Field(default_factory=dict)
    environments: Dict[str, Any] = Field(default_factory=dict)
    tools: Optional[List[ToolConfig]] = Field(default_factory=list)
    type: str = Field(default="official")
    created_at: datetime
    updated_at: Optional[datetime] = None

    class Config:
        from_attributes = True

class AgentFolder(BaseModel):
    id: UUID4
    name: str
    description: Optional[str] = None
    created_at: datetime
    updated_at: Optional[datetime] = None

    model_config = ConfigDict(from_attributes=True)

class BulkDeleteSessionsRequest(BaseModel):
    """Schema for bulk delete sessions request"""

    session_ids: List[str] = Field(
        ..., description="List of session IDs to delete", min_items=1, max_items=100
    )

class BulkDeleteSessionsResponse(BaseModel):
    """Schema for bulk delete sessions response"""

    deleted_count: int = Field(
        ..., description="Number of sessions successfully deleted"
    )
    total_requested: int = Field(
        ..., description="Total number of sessions requested for deletion"
    )
    failed_sessions: List[Dict[str, str]] = Field(
        default_factory=list,
        description="List of sessions that failed to delete with error details",
    )

class SessionMetadataBase(BaseModel):
    """Base schema for session metadata"""

    name: Optional[str] = Field(None, description="Human-readable name for the session")
    description: Optional[str] = Field(None, description="Description of the session")
    tags: Optional[List[str]] = Field(
        default_factory=list, description="List of tags for categorization"
    )

class SessionMetadataCreate(SessionMetadataBase):
    """Schema for creating session metadata"""

    pass


class SessionCreateRequest(BaseModel):
    """Schema for creating a session with custom session_id"""

    session_id: Optional[str] = Field(None, description="Custom session ID (defaults to UUID if not provided)")
    user_id: Optional[str] = Field(None, description="User ID (defaults to user_id from auth if not provided)")
    metadata: Optional[SessionMetadataCreate] = Field(None, description="Optional session metadata")

class SessionMetadataUpdate(SessionMetadataBase):
    """Schema for updating session metadata"""

    pass

class SessionMetadata(SessionMetadataBase):
    """Schema for session metadata response"""

    session_id: str = Field(..., description="Session ID from ADK")
    created_by_user_id: UUID4 = Field(..., description="User who created this session")
    created_at: datetime
    updated_at: Optional[datetime] = None

    model_config = ConfigDict(from_attributes=True)

class SessionWithMetadata(BaseModel):
    """Schema for session with embedded metadata"""

    session_id: str
    agent_id: str
    user_id: str
    created_at: Optional[datetime] = None
    status: str
    metadata: Optional[SessionMetadata] = None


class SessionEventCreate(BaseModel):
    """Schema for creating a session event"""

    author: str = Field(..., description="Author of the event (e.g., 'user', 'assistant', 'system')")
    content: str = Field(..., description="Text content of the event")
    role: Optional[str] = Field("user", description="Role of the content (e.g., 'user', 'model')")
    timestamp: Optional[float] = Field(None, description="Unix timestamp (defaults to current time)")
    invocation_id: Optional[str] = Field(None, description="Unique invocation ID (auto-generated if not provided)")


class SessionEventResponse(BaseModel):
    """Schema for session event response"""

    status: str = Field(..., description="Status of the operation")
    message: str = Field(..., description="Human-readable message")
    event_id: Optional[str] = Field(None, description="ID of the created event")
    session_id: str = Field(..., description="Session ID")

class FolderShare(BaseModel):
    id: UUID4
    folder_id: UUID4
    shared_by_user_id: UUID4
    shared_with_email: str = Field(..., description="Email of the user to share with")
    shared_with_user_id: Optional[UUID4] = None
    permission_level: str = Field(
        default="read", description="Permission level: read or write"
    )
    is_active: bool
    created_at: datetime
    updated_at: Optional[datetime] = None

    model_config = ConfigDict(from_attributes=True)

class CustomMCPServer(BaseModel):
    """Schema for custom MCP server response"""

    id: UUID4
    name: str = Field(..., description="MCP server name")
    description: Optional[str] = Field(None, description="MCP server description")
    url: str = Field(..., description="MCP server URL")
    headers: Dict[str, str] = Field(
        default_factory=dict, description="HTTP headers for requests"
    )
    timeout: int = Field(
        default=30, description="Request timeout in seconds", ge=1, le=300
    )
    retry_count: int = Field(default=3, description="Number of retries", ge=0, le=10)
    tags: List[str] = Field(default_factory=list, description="Tags for categorization")
    tools: List[Dict[str, Any]] = Field(
        default_factory=list, description="Discovered tools from the server"
    )
    created_at: datetime
    updated_at: Optional[datetime] = None

    model_config = ConfigDict(from_attributes=True)

class CustomMCPDiscoverToolsCreate(BaseModel):
    """Schema for creating a custom MCP server with tool discovery"""

    url: Optional[str] = None
    headers: Optional[Dict[str, str]] = None
   
    @validator("url")
    def validate_url(cls, v):
        if v is not None:
            if not v.strip():
                raise ValueError("URL cannot be empty")
            if not (v.startswith("http://") or v.startswith("https://")):
                raise ValueError("URL must start with http:// or https://")
            return v.strip()
        return v
    @validator("headers")
    def validate_headers(cls, v):
        if v is not None:
            if not isinstance(v, dict):
                raise ValueError("Headers must be a dictionary")
            for key, value in v.items():
                if not isinstance(key, str) or not isinstance(value, str):
                    raise ValueError("Headers must be key-value pairs of strings")
        return v
    
class CustomMCPDiscoverToolsResponse(BaseModel):
    """Schema for the response of custom MCP tool discovery"""

    tools: List[Dict[str, Any]] = Field(
        default_factory=list, description="List of discovered tools"
    )
 
class KnowledgeSearch(BaseModel):
    """Schema for knowledge search requests"""

    query: str = Field(..., description="Search query")
    tags: Optional[List[str]] = Field(None, description="Filter by tags")
    max_results: int = Field(default=10, description="Maximum number of results")


class Knowledge(BaseModel):
    """Schema for knowledge entries"""
    
    id: str = Field(..., description="Unique identifier for the knowledge entry")
    client_id: UUID = Field(..., description="Client ID that owns this knowledge")
    title: str = Field(..., description="Title of the knowledge entry")
    content: str = Field(..., description="Content of the knowledge entry")
    description: Optional[str] = Field(None, description="Description of the knowledge entry")
    tags: Optional[List[str]] = Field(default_factory=list, description="Tags for categorization")
    metadata: Optional[Dict[str, Any]] = Field(default_factory=dict, description="Additional metadata")
    is_active: bool = Field(default=True, description="Whether the knowledge entry is active")
    created_at: datetime = Field(..., description="Creation timestamp")
    updated_at: datetime = Field(..., description="Last update timestamp")


class KnowledgeSearchResult(BaseModel):
    """Schema for knowledge search results"""
    
    knowledge: Knowledge = Field(..., description="Knowledge entry")
    score: float = Field(..., description="Search relevance score")
    highlights: Optional[Dict[str, List[str]]] = Field(None, description="Search highlights")


class KnowledgeSearchResponse(BaseModel):
    """Schema for knowledge search response"""
    
    results: List[KnowledgeSearchResult] = Field(..., description="Search results")
    total: int = Field(..., description="Total number of results")
    query: str = Field(..., description="Original search query")

class CustomTool(BaseModel):
    """Schema for custom tool response"""

    id: UUID4
    name: str = Field(..., description="Tool name")
    description: Optional[str] = Field(None, description="Tool description")
    method: str = Field(..., description="HTTP method: GET, POST, PUT, DELETE, PATCH")
    endpoint: str = Field(..., description="API endpoint URL")
    headers: Dict[str, str] = Field(default_factory=dict, description="HTTP headers")
    path_params: Dict[str, str] = Field(
        default_factory=dict, description="URL path parameters (e.g., {id} in URL)"
    )
    query_params: Dict[str, Any] = Field(
        default_factory=dict, description="URL query parameters"
    )
    body_params: Dict[str, Any] = Field(
        default_factory=dict, description="Request body parameters configuration"
    )
    error_handling: Dict[str, Any] = Field(
        default_factory=dict, description="Error handling configuration"
    )
    values: Dict[str, str] = Field(
        default_factory=dict, description="Default values for requests"
    )
    tags: List[str] = Field(default_factory=list, description="Tags for categorization")
    examples: List[str] = Field(default_factory=list, description="Usage examples")
    input_modes: List[str] = Field(
        default_factory=list, description="Supported input modes"
    )
    output_modes: List[str] = Field(
        default_factory=list, description="Supported output modes"
    )
    created_at: datetime
    updated_at: Optional[datetime] = None

    model_config = ConfigDict(from_attributes=True)

class ExecutionMetricsBase(BaseModel):
    agent_id: UUID
    session_id: str
    user_id: str
    llm_model: str
    prompt_tokens: int
    candidate_tokens: int
    cost: float
    total_tokens: int

class ExecutionMetricsCreate(ExecutionMetricsBase):
    pass

class ExecutionMetrics(ExecutionMetricsBase):
    id: UUID
    created_at: datetime

    model_config = ConfigDict(from_attributes=True)

class ExecutionMetricsTotals(BaseModel):
    prompt_tokens: int
    candidate_tokens: int
    total_tokens: int
    cost: float

class ExecutionMetricsResponse(BaseModel):
    metrics: List[ExecutionMetrics]
    totals: ExecutionMetricsTotals