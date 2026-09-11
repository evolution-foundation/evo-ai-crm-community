"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: lazy_mcp_tool.py                                                      │
│ Developed by: Davidson Gomes                                                 │
│ Creation date: May 20, 2025                                                  │
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

from google.adk.tools.mcp_tool.mcp_tool import MCPTool
from google.adk.tools.mcp_tool.mcp_session_manager import MCPSessionManager
from google.genai.types import FunctionDeclaration
import json
from typing import Any, Dict
from google.adk.tools.tool_context import ToolContext
from src.services.adk.mcp_context import mcp_context
from src.utils.logger import setup_logger
from src.config.settings import settings
import asyncio

logger = setup_logger(__name__)


class LazyMCPTool(MCPTool):
    """Lazy-loading proxy for MCPTool that connects only when needed.

    This class extends the real MCPTool but opens connections on-demand
    to conserve resources.
    """

    def __init__(
        self,
        server_cfg: Dict[str, Any],
        tool_name: str,
        description: str = "",
        input_schema: Dict = None,
        timeout: int = settings.MCP_CONNECTION_TIMEOUT,
    ):
        # Store the basic information and server config for later use
        self.name = tool_name
        self.description = description
        self._server_cfg = server_cfg
        self._timeout = timeout

        # Initialize other required attributes with None
        self._mcp_tool = None
        self._mcp_session_manager = None
        self.auth_scheme = None
        self.auth_credential = None

        # For storing the tool's input schema
        self._input_schema = input_schema

        logger.debug(f"Created LazyMCPTool proxy for {tool_name}")

    def _resolve_allof(self, schema: Dict[str, Any]) -> Dict[str, Any]:
        """Resolve allOf by merging all schemas in the array recursively.
        
        Args:
            schema: Schema that may contain allOf
            
        Returns:
            Schema with allOf resolved by merging
        """
        if not isinstance(schema, dict):
            return schema
            
        # First, recursively resolve allOf in nested structures
        # Process properties
        if "properties" in schema and isinstance(schema["properties"], dict):
            for prop_name, prop_schema in schema["properties"].items():
                if isinstance(prop_schema, dict):
                    schema["properties"][prop_name] = self._resolve_allof(prop_schema)
        
        # Process items (for arrays)
        if "items" in schema and isinstance(schema["items"], dict):
            schema["items"] = self._resolve_allof(schema["items"])
        
        # Now resolve allOf at this level
        if "allOf" not in schema:
            return schema
            
        all_of = schema.get("allOf", [])
        if not isinstance(all_of, list):
            return schema
            
        # Start with base schema (without allOf)
        merged = {k: v for k, v in schema.items() if k != "allOf"}
        
        # Merge each schema in allOf array
        for item in all_of:
            if isinstance(item, dict):
                # Recursively resolve allOf in nested schemas
                resolved_item = self._resolve_allof(item)
                
                # Merge properties
                if "properties" in resolved_item:
                    if "properties" not in merged:
                        merged["properties"] = {}
                    merged["properties"].update(resolved_item["properties"])
                
                # Merge required fields
                if "required" in resolved_item:
                    if "required" not in merged:
                        merged["required"] = []
                    merged["required"] = list(set(merged["required"] + resolved_item["required"]))
                
                # Merge other fields (type, enum, etc.) - later values override earlier ones
                for key in ["type", "enum", "description", "default", "items"]:
                    if key in resolved_item:
                        merged[key] = resolved_item[key]
        
        return merged

    def _clean_schema(self, schema: Dict[str, Any]) -> Dict[str, Any]:
        """Clean the schema to be compatible with FunctionDeclaration.

        Removes properties not supported by FunctionDeclaration like
        additionalProperties and $schema. Resolves allOf by merging schemas recursively.

        Args:
            schema: The original schema

        Returns:
            A cleaned schema compatible with FunctionDeclaration
        """
        if not schema:
            return {"type": "object", "properties": {}}

        # First resolve allOf by merging schemas (recursively)
        schema = self._resolve_allof(schema)

        # Make a copy to avoid modifying the original
        cleaned = schema.copy()

        # Remove unsupported properties
        unsupported_keys = ["additionalProperties", "$schema", "allOf", "anyOf", "oneOf"]
        for key in unsupported_keys:
            if key in cleaned:
                cleaned.pop(key)

        # Convert Type objects to strings (e.g., <Type.STRING: 'STRING'> to 'string')
        if "type" in cleaned:
            # Handle both single type and arrays of types
            if isinstance(cleaned["type"], list):
                cleaned["type"] = [
                    str(t).lower() if hasattr(t, "lower") else str(t).lower()
                    for t in cleaned["type"]
                ]
            else:
                # Extract the string value if it's a Type object
                type_value = cleaned["type"]
                if hasattr(type_value, "__str__") and not isinstance(type_value, str):
                    # If it's something like <Type.STRING: 'STRING'>, extract 'string'
                    type_str = str(type_value).lower()
                    # Try to extract the string value from format like <Type.STRING: 'STRING'>
                    if "'" in type_str:
                        try:
                            extracted = type_str.split("'")[1].lower()
                            cleaned["type"] = extracted
                        except (IndexError, AttributeError):
                            cleaned["type"] = (
                                "string"  # Default to string if extraction fails
                            )
                    else:
                        cleaned["type"] = type_str

        # Process enum values to ensure they're all valid JSON types
        if "enum" in cleaned and isinstance(cleaned["enum"], list):
            cleaned["enum"] = [
                str(e) if not isinstance(e, (str, int, float, bool, type(None))) else e
                for e in cleaned["enum"]
            ]

        # Process nested properties recursively (this will also resolve allOf in nested schemas)
        if "properties" in cleaned and isinstance(cleaned["properties"], dict):
            for prop_name, prop_schema in list(cleaned["properties"].items()):
                if isinstance(prop_schema, dict):
                    cleaned["properties"][prop_name] = self._clean_schema(prop_schema)

        # Process items (for arrays) recursively - this is critical for resolving allOf in array items
        if "items" in cleaned and isinstance(cleaned["items"], dict):
            cleaned["items"] = self._clean_schema(cleaned["items"])

        return cleaned

    def _get_declaration(self) -> FunctionDeclaration:
        """Return function declaration with the original schema if available."""
        if self._input_schema:
            # Clean the schema before using it
            cleaned_schema = self._clean_schema(self._input_schema)

            return FunctionDeclaration(
                name=self.name,
                description=self.description,
                parameters=cleaned_schema,
            )

        # Fallback to a simple schema
        logger.debug(f"Using fallback schema for {self.name}")
        return FunctionDeclaration(
            name=self.name,
            description=self.description,
            parameters={"type": "object", "properties": {}},
        )
    
    def to_function_declaration(self) -> FunctionDeclaration:
        """Convert this tool to a FunctionDeclaration for the LLM agent.
        
        This method is called by LlmAgent to get the function declaration
        for each tool. It uses the cached schema if available.
        """
        logger.debug(f"LazyMCPTool.to_function_declaration() called for {self.name}")
        declaration = self._get_declaration()
        logger.debug(
            f"Generated FunctionDeclaration for {self.name}: "
            f"name={declaration.name}, description length={len(declaration.description or '')}, "
            f"parameters keys={list(declaration.parameters.keys()) if isinstance(declaration.parameters, dict) else 'N/A'}"
        )
        return declaration

    async def run_async(self, *, args, tool_context: ToolContext):
        """Connect to the MCPTool server on-demand when the tool is called."""
        logger.debug(f"LazyMCPTool: Connecting to server to run {self.name}...")

        # Compatibilidade com objetos antigos em cache
        timeout = getattr(self, "_timeout", settings.MCP_CONNECTION_TIMEOUT)

        try:
            async with mcp_context(self._server_cfg, timeout=timeout) as tools:
                # Find the matching tool by name
                original_tool = next((t for t in tools if t.name == self.name), None)
                if not original_tool:
                    logger.error(f"Tool {self.name} not found in MCP server")
                    return {"error": f"Tool {self.name} not found"}

                logger.debug(f"Found original tool: {self.name}")

                # Execute the original tool directly
                try:
                    result = await original_tool.run_async(
                        args=args, tool_context=tool_context
                    )
                    logger.debug(
                        f"Tool {self.name} execution completed, connection closed"
                    )
                    return result
                except asyncio.CancelledError:
                    logger.warning(f"Tool {self.name} execution was cancelled")
                    return {"error": "Tool execution cancelled"}
                except Exception as e:
                    logger.error(f"Error executing tool {self.name}: {e}")
                    return {"error": f"Error executing tool: {str(e)}"}
        except RuntimeError as e:
            if "generator didn't stop" in str(e):
                logger.warning(f"Context manager issue with tool {self.name}: {e}")
                return {"error": "Tool execution interrupted"}
            else:
                logger.error(f"Error with tool {self.name}: {e}")
                return {"error": str(e)}
        except asyncio.CancelledError:
            logger.warning(f"Tool {self.name} connection was cancelled")
            return {"error": "Connection cancelled"}
        except Exception as e:
            logger.error(f"Unexpected error with tool {self.name}: {e}")
            return {"error": str(e)}

    async def run(self, **kwargs):
        """Standard run method for compatibility."""
        # Create a default tool context if not provided
        if "tool_context" not in kwargs:
            kwargs["tool_context"] = ToolContext()

        # Extract args from kwargs if not explicitly provided
        if "args" not in kwargs:
            args = {k: v for k, v in kwargs.items() if k != "tool_context"}
            return await self.run_async(args=args, tool_context=kwargs["tool_context"])

        return await self.run_async(**kwargs)
