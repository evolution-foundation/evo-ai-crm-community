"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: client_routes.py                                                      │
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

from fastapi import APIRouter, Depends, HTTPException, status, Request
from sqlalchemy.orm import Session
from src.config.database import get_db
from src.services.temp_limits_service import get_usage_summary
from src.api.dependencies import get_current_user
from src.middleware.permissions import RequirePermission
from src.utils.response import success_response, error_response, map_status_to_error_code
from src.schemas.responses import SuccessResponse, ErrorResponse
from src.schemas.response_models import UsageSummaryDictResponse

import logging

logger = logging.getLogger(__name__)

router = APIRouter(
    prefix="/clients",
    tags=["clients"],
)

@router.get(
    "/usage",
    response_model=SuccessResponse[UsageSummaryDictResponse],
    responses={
        200: {"description": "Usage summary retrieved successfully"},
        500: {"model": ErrorResponse, "description": "Internal server error"}
    }
)
async def get_client_usage_summary(
    current_user: dict = Depends(get_current_user),
    _: None = Depends(RequirePermission("ai_clients", "usage")),
    db: Session = Depends(get_db)
):
    """
    Get usage summary for a clients (sessions, etc.)

    Args:
        current_user: Authenticated user
        db: Database session

    Returns:
        Standardized response with usage summary data

    Raises:
        HTTPException: If the user doesn't have access to this accounts
    """
    try:
        # Get usage summary
        usage_summary = get_usage_summary(db)

        return success_response(
            data=usage_summary,
            message="Usage summary retrieved successfully"
        )

    except Exception as e:
        logger.error(f"Error getting usage summary for account: {str(e)}")
        return error_response(
            code=map_status_to_error_code(status.HTTP_500_INTERNAL_SERVER_ERROR),
            message=f"Error getting usage summary: {str(e)}",
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR
        )