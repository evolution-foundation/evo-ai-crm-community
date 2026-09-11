"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: exceptions.py                                                         │
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

from fastapi import HTTPException
from typing import Optional, Dict, Any
from src.core.error_codes import (
    RESOURCE_NOT_FOUND,
    INVALID_INPUT,
    INTERNAL_ERROR
)


class BaseAPIException(HTTPException):
    """Base class for API exceptions"""

    def __init__(
        self,
        status_code: int,
        message: str,
        error_code: str,
        details: Optional[Dict[str, Any]] = None,
    ):
        super().__init__(
            status_code=status_code,
            detail={
                "error": message,
                "error_code": error_code,
                "details": details or {},
            },
        )
        self.error_code = error_code


class AgentNotFoundError(BaseAPIException):
    """Exception when the agent is not found"""

    def __init__(self, agent_id: str):
        super().__init__(
            status_code=404,
            message=f"Agent with ID {agent_id} not found",
            error_code=RESOURCE_NOT_FOUND,
        )


class InvalidRequestError(BaseAPIException):
    """Exception for invalid requests"""

    def __init__(self, message: str, details: Optional[Dict[str, Any]] = None):
        super().__init__(
            status_code=400,
            message=message,
            error_code=INVALID_INPUT,
            details=details,
        )


class InternalServerError(BaseAPIException):
    """Exception for server errors"""

    def __init__(self, message: str = "Server error"):
        super().__init__(
            status_code=500, message=message, error_code=INTERNAL_ERROR
        )
