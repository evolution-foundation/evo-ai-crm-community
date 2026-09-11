"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Guilherme Gomes                                                     │
│ @file: folder_share_service.py                                               │
│ Developed by: Guilherme Gomes                                                │
│ Creation date: May 28, 2025                                                  │
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
from src.models.models import FolderShare, AgentFolder
from typing import Optional
import uuid
import logging

logger = logging.getLogger(__name__)

def check_folder_access(
    db: Session,
    folder_id: uuid.UUID,
    user_email: Optional[str] = None,
    required_permission: str = "read"
) -> bool:
    """Check if a user has access to a folder"""
    try:
        # Check if folder exists
        if user_email:
            folder = db.query(AgentFolder).filter(
                AgentFolder.id == folder_id,
            ).first()
            if folder:
                return True
        
        # Check if folder is shared with the user
        share = db.query(FolderShare).filter(
            FolderShare.folder_id == folder_id,
            FolderShare.shared_with_email == user_email,
            FolderShare.is_active == True
        ).first()
        
        if not share:
            return False
            
        # Check permission level
        if required_permission == "write" and share.permission_level != "write":
            return False
            
        return True
        
    except SQLAlchemyError as e:
        logger.error(f"Error checking folder access: {str(e)}")
        return False 