"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: tool_schemas.py                                                       │
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

from typing import List, Optional, Dict, Any
from pydantic import BaseModel, Field


class AvailableToolConfig(BaseModel):
    """Configuration details for an available tool"""

    required_fields: List[str] = Field(..., description="Required configuration fields")
    optional_fields: List[str] = Field(
        default_factory=list, description="Optional configuration fields"
    )
    default_values: Dict[str, Any] = Field(
        default_factory=dict, description="Default values for configuration"
    )
    field_types: Dict[str, Any] = Field(
        default_factory=dict, description="Field types for configuration"
    )

    class Config:
        from_attributes = True


class AvailableTool(BaseModel):
    """Schema for available tools listing"""

    id: str = Field(..., description="Unique tool identifier")
    name: str = Field(..., description="Tool name")
    description: str = Field(..., description="Tool description")
    tags: List[str] = Field(
        default_factory=list, description="Tool tags for categorization"
    )
    examples: List[str] = Field(default_factory=list, description="Usage examples")
    inputModes: List[str] = Field(
        default_factory=list, description="Supported input formats"
    )
    outputModes: List[str] = Field(
        default_factory=list, description="Supported output formats"
    )
    config: AvailableToolConfig = Field(..., description="Tool configuration details")

    class Config:
        from_attributes = True


class ToolCategory(BaseModel):
    """Schema for tool categories"""

    id: str = Field(..., description="Category identifier")
    name: str = Field(..., description="Category name")
    description: str = Field(..., description="Category description")
    tools: List[str] = Field(..., description="List of tool IDs in this category")

    class Config:
        from_attributes = True


class ToolsMetadata(BaseModel):
    """Schema for tools metadata"""

    version: str = Field(..., description="Tools configuration version")
    last_updated: str = Field(..., description="Last update date")
    total_tools: int = Field(..., description="Total number of available tools")
    total_categories: int = Field(..., description="Total number of categories")

    class Config:
        from_attributes = True


class AvailableToolsResponse(BaseModel):
    """Schema for the complete tools listing response"""

    tools: List[AvailableTool] = Field(..., description="List of available tools")
    categories: List[ToolCategory] = Field(..., description="Tool categories")
    metadata: ToolsMetadata = Field(..., description="Response metadata")

    class Config:
        from_attributes = True


class ToolsFilterRequest(BaseModel):
    """Schema for filtering tools"""

    category: Optional[str] = Field(None, description="Filter by category ID")
    tags: Optional[List[str]] = Field(None, description="Filter by tags")
    search: Optional[str] = Field(None, description="Search in name and description")

    class Config:
        from_attributes = True
