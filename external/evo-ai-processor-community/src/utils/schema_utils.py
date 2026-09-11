"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: schema_utils.py                                                       │
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

from typing import Dict, Any, Optional, Type
from pydantic import BaseModel, Field, create_model
from src.utils.logger import setup_logger

logger = setup_logger(__name__)


def json_schema_to_pydantic(
    schema_dict: Dict[str, Any], model_name: str = "DynamicOutputSchema"
) -> Optional[Type[BaseModel]]:
    """
    Convert a JSON schema dictionary to a dynamic Pydantic model.

    Args:
        schema_dict: JSON schema dictionary with field definitions
        model_name: Name for the generated Pydantic model

    Returns:
        Pydantic model class or None if conversion fails

    Example schema_dict:
    {
        "temperature": {"type": "string", "description": "Temperature value"},
        "humidity": {"type": "string", "description": "Humidity percentage"},
        "wind_speed": {"type": "string", "description": "Wind speed value"}
    }
    """
    try:
        if not isinstance(schema_dict, dict):
            logger.error("Schema must be a dictionary")
            return None

        if not schema_dict:
            logger.error("Schema dictionary cannot be empty")
            return None

        # Build field definitions for create_model
        field_definitions = {}

        for field_name, field_config in schema_dict.items():
            if not isinstance(field_config, dict):
                logger.warning(
                    f"Field {field_name} config must be a dictionary, skipping"
                )
                continue

            field_type = field_config.get("type", "string")
            field_description = field_config.get("description", "")
            field_required = field_config.get("required", True)
            field_default = field_config.get("default")

            # Map JSON schema types to Python types
            python_type = _map_json_type_to_python(field_type)

            if field_required and field_default is None:
                # Required field without default
                if field_description:
                    field_definitions[field_name] = (
                        python_type,
                        Field(description=field_description),
                    )
                else:
                    field_definitions[field_name] = (python_type, ...)
            else:
                # Optional field or field with default
                if field_default is not None:
                    if field_description:
                        field_definitions[field_name] = (
                            python_type,
                            Field(default=field_default, description=field_description),
                        )
                    else:
                        field_definitions[field_name] = (python_type, field_default)
                else:
                    # Optional field
                    from typing import Optional as TypingOptional

                    optional_type = TypingOptional[python_type]
                    if field_description:
                        field_definitions[field_name] = (
                            optional_type,
                            Field(default=None, description=field_description),
                        )
                    else:
                        field_definitions[field_name] = (optional_type, None)

        if not field_definitions:
            logger.error("No valid field definitions found in schema")
            return None

        # Create the dynamic model
        dynamic_model = create_model(model_name, **field_definitions)

        logger.debug(
            f"Successfully created dynamic Pydantic model '{model_name}' with fields: {list(field_definitions.keys())}"
        )
        return dynamic_model

    except Exception as e:
        logger.error(f"Error creating dynamic Pydantic model: {str(e)}")
        return None


def _map_json_type_to_python(json_type: str) -> Type:
    """Map JSON schema types to Python types."""
    type_mapping = {
        "string": str,
        "integer": int,
        "number": float,
        "boolean": bool,
        "array": list,
        "object": dict,
    }

    return type_mapping.get(json_type.lower(), str)


def validate_output_schema(schema_dict: Dict[str, Any]) -> bool:
    """
    Validate if a schema dictionary is valid for output_schema.

    Args:
        schema_dict: Schema dictionary to validate

    Returns:
        True if valid, False otherwise
    """
    try:
        if not isinstance(schema_dict, dict):
            logger.error("Schema must be a dictionary")
            return False

        if not schema_dict:
            logger.error("Schema dictionary cannot be empty")
            return False

        for field_name, field_config in schema_dict.items():
            if not isinstance(field_name, str):
                logger.error(f"Field name must be a string: {field_name}")
                return False

            if not isinstance(field_config, dict):
                logger.error(f"Field config for '{field_name}' must be a dictionary")
                return False

            # Check required keys
            if "type" not in field_config:
                logger.error(f"Field '{field_name}' must have a 'type' property")
                return False

            field_type = field_config["type"]
            valid_types = ["string", "integer", "number", "boolean", "array", "object"]
            if field_type not in valid_types:
                logger.error(
                    f"Field '{field_name}' has invalid type '{field_type}'. Valid types: {valid_types}"
                )
                return False

        logger.debug("Schema validation passed")
        return True

    except Exception as e:
        logger.error(f"Error validating schema: {str(e)}")
        return False
