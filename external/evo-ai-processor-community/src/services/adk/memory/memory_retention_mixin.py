"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: memory_retention_mixin.py                                            │
│ Developed by: Davidson Gomes                                                 │
│ Creation date: May 26, 2025                                                  │
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

from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from sqlalchemy.orm import Session

# Note: MemoryRetentionMixin is kept for backward compatibility but is no longer used
# since memory operations are now handled via HTTP through the knowledge microservice.
# MemoryLimitExceeded is kept for error handling in chat_routes.py


class MemoryLimitExceeded(Exception):
    """Exception raised when memory retention limits are exceeded.
    
    This exception is kept for backward compatibility with error handling code.
    With the new HTTP-based memory service, limits are handled by the knowledge microservice.
    """

    pass


class MemoryRetentionMixin:
    """Mixin class for memory retention functionality.
    
    This mixin is kept for backward compatibility but is no longer actively used
    since memory operations are now handled via HTTP through the knowledge microservice.
    The knowledge service handles all memory retention and limits internally.
    """
    
    pass
