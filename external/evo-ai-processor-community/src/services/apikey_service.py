"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: apikey_service.py                                                     │
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

from src.models.models import ApiKey
from src.utils.crypto import decrypt_api_key
from sqlalchemy.orm import Session
from sqlalchemy.exc import SQLAlchemyError
from fastapi import HTTPException, status
import uuid
import logging
from typing import Optional, TYPE_CHECKING

if TYPE_CHECKING:
    from src.models.models import Agent

logger = logging.getLogger(__name__)

def get_api_key(db: Session, key_id: uuid.UUID) -> Optional[ApiKey]:
    """Get an API key by ID"""
    try:
        return db.query(ApiKey).filter(ApiKey.id == key_id).first()
    except SQLAlchemyError as e:
        logger.error(f"Error getting API key {key_id}: {str(e)}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Error getting API key",
        )


def get_decrypted_api_key(db: Session, key_id: uuid.UUID, agent: Optional['Agent'] = None) -> Optional[str]:
    """Get the decrypted value of an API key
    
    Args:
        db: Database session
        key_id: API key ID
        agent: Optional agent object for shared agent access validation
    """
    try:
        key = get_api_key(db, key_id)
            
        if not key or not key.is_active:
            logger.warning(f"API key {key_id} not found or inactive")
            return None
            
        # If agent is provided and it's a shared agent scenario,
        # allow access to the API key even if it belongs to a different client 
        if agent and agent.api_key_id == key.id:
            logger.info(f"Allowing API key access for agent {agent.name} (shared agent scenario)")
            return decrypt_api_key(key.key)  # Decrypt using shared ENCRYPTION_KEY
            
        return decrypt_api_key(key.key)  # Decrypt using shared ENCRYPTION_KEY
    except Exception as e:
        logger.error(f"Error decrypting API key {key_id}: {str(e)}")
        return None