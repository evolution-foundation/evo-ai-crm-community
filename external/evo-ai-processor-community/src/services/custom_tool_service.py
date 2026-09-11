"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: custom_tool_service.py                                               │
│ Developed by: Davidson Gomes                                                 │
│ Creation date: January 14, 2025                                              │
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

from sqlalchemy.orm import Session
from sqlalchemy.exc import SQLAlchemyError
from src.models.models import CustomTool
from src.services.adk.custom_tools import strip_modes_meta
from typing import List, Optional, Dict, Any
import uuid
import logging
logger = logging.getLogger(__name__)

# Fetch a single custom tool by id
def get_custom_tool(db: Session, tool_id: uuid.UUID) -> Optional[CustomTool]:
    """Get a single custom tool by id.

    Synchronous on purpose: the ADK tool builder runs inside the sync request
    path and calls this without awaiting.
    """

    try:
        return db.query(CustomTool).filter(CustomTool.id == tool_id).first()
    except SQLAlchemyError as e:
        logger.error(f"Error getting custom tool {tool_id}: {str(e)}")
        return None

# Fetch custom tools with optional filtering
async def get_custom_tools(
    db: Session,
    skip: int = 0,
    limit: int = 100,
    search: Optional[str] = None,
    tags: Optional[List[str]] = None,
) -> List[CustomTool]:
    """Get custom tools with filtering"""

    try:
        query = db.query(CustomTool)

        if search:
            search_filter = f"%{search}%"
            query = query.filter(
                CustomTool.name.ilike(search_filter)
                | CustomTool.description.ilike(search_filter)
            )

        if tags:
            # Filter by tags (JSON contains)
            for tag in tags:
                query = query.filter(CustomTool.tags.contains([tag]))

        return query.order_by(CustomTool.name).offset(skip).limit(limit).all()
    except SQLAlchemyError as e:
        logger.error(f"Error getting custom tools: {str(e)}")
        return []

# Convert CustomTool to HTTPTool format for agent configuration 
def convert_to_http_tool(custom_tool: CustomTool) -> Dict[str, Any]:
    """Convert CustomTool to HTTPTool format for agent configuration"""
    # Ensure error_handling has all required fields with defaults
    error_handling = custom_tool.error_handling or {}
    default_error_handling = {
        "timeout": error_handling.get("timeout", 30),
        "retry_count": error_handling.get("retry_count", 0),
        "fallback_response": error_handling.get(
            "fallback_response", {"error": "", "message": ""}
        ),
    }

    return {
        "name": custom_tool.name,
        "method": custom_tool.method,
        "endpoint": custom_tool.endpoint,
        "headers": custom_tool.headers,
        "parameters": {
            "path_params": custom_tool.path_params,
            "query_params": custom_tool.query_params,
            "body_params": custom_tool.body_params,
        },
        "description": custom_tool.description or "",
        "error_handling": default_error_handling,
        # The wizard parks documentation under a reserved key of `values`. The tool
        # builders drop it before hitting the wire, but it has no business being
        # copied into an agent config either.
        "values": strip_modes_meta(custom_tool.values),
    }

