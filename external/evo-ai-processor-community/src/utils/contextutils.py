"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: contextutils.py                                                       │
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
from src.utils.logger import setup_logger

logger = setup_logger(__name__)

def get_user_id(context: Dict[str, Any]) -> Optional[str]:
    """Get user ID from context"""
    return context.get("user_id")

def get_email(context: Dict[str, Any]) -> Optional[str]:
    """Get user email from context"""
    return context.get("email")

def get_name(context: Dict[str, Any]) -> Optional[str]:
    """Get user name from context"""
    return context.get("name")

def get_user(context: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    """Get user object from context"""
    return context.get("user")

def get_api_access_token(context: Dict[str, Any]) -> Optional[str]:
    """Get API access token from context (from token_info)"""
    token_info = context.get("token_info")
    if token_info:
        return token_info.get("access_token")
    return None

def get_token_type(context: Dict[str, Any]) -> Optional[str]:
    """Get token type from context (from token_info)"""
    token_info = context.get("token_info")
    if token_info:
        return token_info.get("type", "bearer")
    return "bearer"

def get_user_role(context: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    """Get user role from context"""
    user = get_user(context)
    if not user:
        return None
    
    return user.get("role")

def get_user_type(context: Dict[str, Any]) -> Optional[str]:
    """Get user type from context"""
    user = get_user(context)
    if not user:
        return None
    
    return user.get("type")
