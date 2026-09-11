"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: agent_config.py                                                       │
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

from typing import List, Optional, Dict, Union, Any
from pydantic import BaseModel, Field, validator
from uuid import UUID
import secrets
import string

# ToolConfig model
class ToolConfig(BaseModel):
    """Configuration of a tool"""

    id: UUID
    name: str = Field(..., description="Name of the tool")
    description: Optional[str] = Field(None, description="Description of the tool")
    tags: List[str] = Field(default_factory=list, description="Tags for categorization")
    examples: List[str] = Field(default_factory=list, description="Usage examples")
    inputModes: List[str] = Field(
        default_factory=list, description="Input modes supported"
    )
    outputModes: List[str] = Field(
        default_factory=list, description="Output modes supported"
    )
    config: Optional[Dict[str, Any]] = Field(
        default_factory=dict,
        description="Tool configuration including environment variables",
    )

    class Config:
        from_attributes = True

# MCPServerConfig model
class MCPServerConfig(BaseModel):
    """Configuration of an MCP server"""

    id: UUID
    envs: Dict[str, str] = Field(
        default_factory=dict, description="Environment variables of the server"
    )
    # The key the pipeline actually persists: the screen writes `environments`
    # and the core rewrites the entry as {id, environments, tools}
    # (config_processor.go:266,278-282). `envs` above is kept for older entries.
    environments: Dict[str, str] = Field(
        default_factory=dict, description="Environment variables of the server"
    )
    # Vault references, keyed by env var name.
    credential_refs: Dict[str, str] = Field(
        default_factory=dict, description="Vault credential ids by env var name"
    )
    tools: List[str] = Field(
        default_factory=list, description="List of tools of the server"
    )

    class Config:
        from_attributes = True

# CustomMCPServerConfig model
class CustomMCPServerConfig(BaseModel):
    """Configuration of a custom MCP server"""

    url: str = Field(..., description="Server URL of the custom MCP server")
    headers: Dict[str, str] = Field(
        default_factory=dict, description="Headers for requests to the server"
    )

    class Config:
        from_attributes = True

#FlowNodes model
class FlowNodes(BaseModel):
    """Configuration of workflow nodes"""

    nodes: List[Any]
    edges: List[Any]

# MCPServerConfig model
class HTTPToolParameter(BaseModel):
    """Parameter of an HTTP tool"""

    type: str
    element_type: Optional[str] = (
        None  # NEW: Type of elements for arrays (e.g., "string", "number", "object")
    )
    required: bool
    description: str

    class Config:
        from_attributes = True

# HTTPToolParameters model
class HTTPToolParameters(BaseModel):
    """Parameters of an HTTP tool"""

    path_params: Optional[Dict[str, str]] = None
    query_params: Optional[Dict[str, Union[str, List[str]]]] = None
    body_params: Optional[Dict[str, HTTPToolParameter]] = None
    body_type: Optional[str] = "object"
    array_param: Optional[str] = None

    class Config:
        from_attributes = True

# HTTPToolErrorHandling model
class HTTPToolErrorHandling(BaseModel):
    """Configuration of error handling"""

    timeout: int
    retry_count: int
    fallback_response: Dict[str, str]

    class Config:
        from_attributes = True

#HttpTool model
class HTTPTool(BaseModel):
    """Configuration of an HTTP tool"""

    name: str
    method: str
    values: Dict[str, str]
    headers: Dict[str, str]
    endpoint: str
    parameters: HTTPToolParameters
    description: str
    error_handling: HTTPToolErrorHandling

    class Config:
        from_attributes = True

#CustomTools model
class CustomTools(BaseModel):
    """Configuration of custom tools"""

    http_tools: List[HTTPTool] = Field(
        default_factory=list, description="List of HTTP tools"
    )

    class Config:
        from_attributes = True

# Utility function to generate a secure API key
def generate_api_key(length: int = 32) -> str:
    """Generate a secure API key."""
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(length))

# LLMConfig model
class LLMConfig(BaseModel):
    """Configuration for LLM agents"""

    api_key: str = Field(
        default_factory=generate_api_key,
        description="API key for the LLM. If not provided, a secure key will be generated automatically.",
    )

    output_key: Optional[str] = Field(
        default=None,
        description="State key where the agent's output will be stored (for workflow state management)",
    )
    enable_exit_loop: Optional[bool] = Field(
        default=False, description="Enable exit_loop tool for agents inside LoopAgent"
    )
    load_memory: Optional[bool] = Field(
        default=False, description="Enable memory loading tools for the agent"
    )
    preload_memory: Optional[bool] = Field(
        default=False,
        description="Enable memory preloading tools for the agent (requires load_memory to be True)",
    )
    memory_short_term_max_messages: Optional[int] = Field(
        default=50,
        ge=10,
        le=500,
        description="Maximum number of messages in short-term memory before compression to medium-term memory. Default: 50, Min: 10, Max: 500.",
    )
    memory_medium_term_compression_interval: Optional[int] = Field(
        default=10,
        ge=5,
        le=100,
        description="Compress every N messages into medium-term memory. Default: 10, Min: 5, Max: 100.",
    )
    memory_base_config_id: Optional[UUID] = Field(
        default=None,
        description="UUID of the knowledge base configuration to use for memory operations (uses memory_index_name/memory_collection_name from the config)",
    )
    planner: Optional[bool] = Field(
        default=False, description="Enable PlanReActPlanner for the agent"
    )
    output_schema: Optional[Dict[str, Any]] = Field(
        default=None, description="JSON schema for structured output from the agent"
    )
    tools: Optional[List[ToolConfig]] = Field(
        default=None, description="List of available tools"
    )
    custom_tools: Optional[CustomTools] = Field(
        default=None, description="Custom tools"
    )
    custom_tool_ids: Optional[List[UUID]] = Field(
        default=None,
        description="List of custom tool IDs to include in agent configuration",
    )
    mcp_servers: Optional[List[MCPServerConfig]] = Field(
        default=None, description="List of MCP servers"
    )
    custom_mcp_servers: Optional[List[CustomMCPServerConfig]] = Field(
        default=None, description="List of custom MCP servers with URL and headers"
    )
    custom_mcp_server_ids: Optional[List[UUID]] = Field(
        default=None,
        description="List of custom MCP server IDs to include in agent configuration",
    )
    agent_tools: Optional[List[UUID]] = Field(
        default=None, description="List of IDs of sub-agents"
    )
    sub_agents: Optional[List[UUID]] = Field(
        default=None, description="List of IDs of sub-agents"
    )
    workflow: Optional[FlowNodes] = Field(
        default=None, description="Workflow configuration"
    )

    @validator("preload_memory")
    def validate_preload_memory(cls, v, values):
        """Validate that preload_memory is only enabled when load_memory is also enabled."""
        if v and not values.get("load_memory"):
            raise ValueError("preload_memory requires load_memory to be enabled")
        return v
    
    class Config:
        from_attributes = True

# SequentialConfig model
class SequentialConfig(BaseModel):
    """Configuration for sequential agents"""

    sub_agents: List[UUID] = Field(
        ..., description="List of IDs of sub-agents in execution order"
    )
    output_key: Optional[str] = Field(
        default=None, description="State key where the agent's output will be stored"
    )
    custom_tool_ids: Optional[List[UUID]] = Field(
        default=None,
        description="List of custom tool IDs to include in agent configuration",
    )
    custom_mcp_server_ids: Optional[List[UUID]] = Field(
        default=None,
        description="List of custom MCP server IDs to include in agent configuration",
    )

    class Config:
        from_attributes = True

# ParallelConfig model
class ParallelConfig(BaseModel):
    """Configuration for parallel agents"""

    sub_agents: List[UUID] = Field(
        ..., description="List of IDs of sub-agents for parallel execution"
    )
    output_key: Optional[str] = Field(
        default=None, description="State key where the agent's output will be stored"
    )
    custom_tool_ids: Optional[List[UUID]] = Field(
        default=None,
        description="List of custom tool IDs to include in agent configuration",
    )
    custom_mcp_server_ids: Optional[List[UUID]] = Field(
        default=None,
        description="List of custom MCP server IDs to include in agent configuration",
    )

    class Config:
        from_attributes = True

# LoopConfig model
class LoopConfig(BaseModel):
    """Configuration for loop agents"""

    sub_agents: List[UUID] = Field(
        ..., description="List of IDs of sub-agents for loop execution"
    )
    max_iterations: Optional[int] = Field(
        default=None, description="Maximum number of iterations"
    )
    condition: Optional[str] = Field(
        default=None, description="Condition to stop the loop"
    )
    output_key: Optional[str] = Field(
        default=None, description="State key where the agent's output will be stored"
    )
    agents_exit_loop: Optional[List[str]] = Field(
        default_factory=list,
        description="List of sub-agent IDs that should have exit_loop tool enabled",
    )
    custom_tool_ids: Optional[List[UUID]] = Field(
        default=None,
        description="List of custom tool IDs to include in agent configuration",
    )
    custom_mcp_server_ids: Optional[List[UUID]] = Field(
        default=None,
        description="List of custom MCP server IDs to include in agent configuration",
    )

    class Config:
        from_attributes = True

# WorkflowConfig model
class WorkflowConfig(BaseModel):
    """Configuration for workflow agents"""

    workflow: Dict[str, Any] = Field(
        ..., description="Workflow configuration with nodes and edges"
    )
    sub_agents: Optional[List[UUID]] = Field(
        default_factory=list, description="List of IDs of sub-agents used in workflow"
    )
    api_key: Optional[str] = Field(
        default_factory=generate_api_key, description="API key for the workflow agent"
    )
    output_key: Optional[str] = Field(
        default=None, description="State key where the agent's output will be stored"
    )
    custom_tool_ids: Optional[List[UUID]] = Field(
        default=None,
        description="List of custom tool IDs to include in agent configuration",
    )
    custom_mcp_server_ids: Optional[List[UUID]] = Field(
        default=None,
        description="List of custom MCP server IDs to include in agent configuration",
    )

    class Config:
        from_attributes = True

# AgentTask model
class AgentTask(BaseModel):
    """Task configuration for agents"""

    agent_id: Union[UUID, str] = Field(
        ..., description="ID of the agent assigned to this task"
    )
    enabled_tools: Optional[List[str]] = Field(
        default_factory=list, description="List of tool names to be used in the task"
    )
    description: str = Field(..., description="Description of the task to be performed")
    expected_output: str = Field(..., description="Expected output from this task")

    @validator("agent_id")
    def validate_agent_id(cls, v):
        if isinstance(v, str):
            try:
                return UUID(v)
            except ValueError:
                raise ValueError(f"Invalid UUID format for agent_id: {v}")
        return v

    class Config:
        from_attributes = True

# # Agent configuration model
class AgentConfig(BaseModel):
    """Configuration for agents"""

    tasks: List[AgentTask] = Field(
        ..., description="List of tasks to be performed by the agent"
    )
    api_key: Optional[str] = Field(
        default_factory=generate_api_key, description="API key for the agent"
    )
    sub_agents: Optional[List[UUID]] = Field(
        default_factory=list, description="List of IDs of sub-agents used in agent"
    )
    output_key: Optional[str] = Field(
        default=None, description="State key where the agent's output will be stored"
    )
    custom_tool_ids: Optional[List[UUID]] = Field(
        default=None,
        description="List of custom tool IDs to include in agent configuration",
    )
    custom_mcp_server_ids: Optional[List[UUID]] = Field(
        default=None,
        description="List of custom MCP server IDs to include in agent configuration",
    )

    class Config:
        from_attributes = True
