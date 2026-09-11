"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: System                                                              │
│ @file: response.py                                                           │
│ Standardized API response format matching other Evolution services           │
│ Creation date: January 2025                                                  │
├──────────────────────────────────────────────────────────────────────────────┤
│ @copyright © Evolution API 2025. All rights reserved.                        │
│ Licensed under the Apache License, Version 2.0                               │
└──────────────────────────────────────────────────────────────────────────────┘
"""

from typing import Optional, Any, Dict, List
from datetime import datetime, timezone
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field
from fastapi import Request

from src.utils.json_encoder import SafeJSONResponse

# Import error codes for mapping
try:
    from src.core.error_codes import (
        VALIDATION_ERROR,
        INVALID_INPUT,
        UNAUTHORIZED,
        FORBIDDEN,
        NOT_FOUND,
        INTERNAL_ERROR,
        BAD_REQUEST,
        CONFLICT,
        EXTERNAL_SERVICE_ERROR,
        TIMEOUT_ERROR,
        RATE_LIMIT_EXCEEDED,
        PAYLOAD_TOO_LARGE,
        CLIENT_CLOSED_REQUEST
    )
except ImportError:
    # Fallback if error_codes module is not available
    VALIDATION_ERROR = "VALIDATION_ERROR"
    INVALID_INPUT = "INVALID_INPUT"
    UNAUTHORIZED = "UNAUTHORIZED"
    FORBIDDEN = "FORBIDDEN"
    NOT_FOUND = "NOT_FOUND"
    INTERNAL_ERROR = "INTERNAL_ERROR"
    BAD_REQUEST = "BAD_REQUEST"
    CONFLICT = "CONFLICT"
    EXTERNAL_SERVICE_ERROR = "EXTERNAL_SERVICE_ERROR"
    TIMEOUT_ERROR = "TIMEOUT_ERROR"
    RATE_LIMIT_EXCEEDED = "RATE_LIMIT_EXCEEDED"
    PAYLOAD_TOO_LARGE = "PAYLOAD_TOO_LARGE"
    CLIENT_CLOSED_REQUEST = "CLIENT_CLOSED_REQUEST"


class PaginationMeta(BaseModel):
    """Pagination metadata"""
    page: int = Field(..., description="Current page number")
    page_size: int = Field(..., description="Number of items per page")
    total_pages: int = Field(..., description="Total number of pages")
    total: int = Field(..., description="Total number of items")
    has_next_page: bool = Field(..., description="Whether there's a next page")
    has_previous_page: bool = Field(..., description="Whether there's a previous page")


class MetaInfo(BaseModel):
    """Metadata information"""
    timestamp: str = Field(..., description="ISO8601 timestamp")
   
class MetaInfoPagination(MetaInfo):
    """Metadata information for pagination"""
    pagination: PaginationMeta = Field(..., description="Pagination metadata")

class MetaInfoError(BaseModel):
    """Metadata information for error responses"""
    timestamp: str = Field(..., description="ISO8601 timestamp")
    path: Optional[str] = Field(None, description="Path of the request")
    method: Optional[str] = Field(None, description="HTTP method of the request")


class ErrorInfo(BaseModel):
    """Error information"""
    code: str = Field(..., description="Error code")
    message: str = Field(..., description="Human-readable error message")
    details: Optional[Any] = Field(None, description="Additional error details")


class SuccessResponseData(BaseModel):
    """Standard success response structure"""
    success: bool = Field(True, description="Success indicator")
    data: Any = Field(..., description="Response data")
    meta: MetaInfo = Field(..., description="Metadata")
    message: Optional[str] = Field(None, description="Optional success message")


class ErrorResponseData(BaseModel):
    """Standard error response structure"""
    success: bool = Field(False, description="Success indicator")
    error: ErrorInfo = Field(..., description="Error information")
    meta: MetaInfoError = Field(..., description="Metadata")


def success_response(
    data: Any,
    message: Optional[str] = None,
    status_code: int = 200
) -> JSONResponse:
    """
    Create a standardized success response
    
    Args:
        data: Response data (dict, list, or any serializable object)
        message: Optional success message
        status_code: HTTP status code (default: 200)
    
    Returns:
        JSONResponse with standardized format
    """
    # For 204 No Content, return empty response body
    if status_code == 204:
        return SafeJSONResponse(
            status_code=status_code,
            content=None
        )
    
    meta = MetaInfo(
        timestamp=datetime.now(timezone.utc).isoformat()
    )
    
    response = SuccessResponseData(
        success=True,
        data=data,
        meta=meta,
        message=message
    )
    
    return SafeJSONResponse(
        status_code=status_code,
        content=response.model_dump(exclude_none=True)
    )


def map_status_to_error_code(status_code: int) -> str:
    """
    Map HTTP status code to standardized error code
    
    Args:
        status_code: HTTP status code
    
    Returns:
        Standardized error code string
    """
    status_mapping = {
        400: BAD_REQUEST,
        401: UNAUTHORIZED,
        403: FORBIDDEN,
        404: NOT_FOUND,
        409: CONFLICT,
        413: PAYLOAD_TOO_LARGE,
        422: VALIDATION_ERROR,
        # CRM-236: without these three, an upstream quota refusal, an oversized
        # request and a caller that hung up all fell through to INTERNAL_ERROR.
        429: RATE_LIMIT_EXCEEDED,
        499: CLIENT_CLOSED_REQUEST,
        500: INTERNAL_ERROR,
        502: EXTERNAL_SERVICE_ERROR,
        503: EXTERNAL_SERVICE_ERROR,
        504: TIMEOUT_ERROR,
    }
    
    return status_mapping.get(status_code, INTERNAL_ERROR)


def error_response(
    request: Optional[Request] = None,
    code: str = "ERROR",
    message: str = "Error",
    details: Optional[Any] = None,
    status_code: int = 400
) -> JSONResponse:
    """
    Create a standardized error response

    Args:
        request: FastAPI request object
        code: Error code (e.g., "VALIDATION_ERROR", "NOT_FOUND")
        message: Human-readable error message
        details: Optional additional error details
        status_code: HTTP status code (default: 400)
    
    Returns:
        JSONResponse with standardized error format
    """
    
    error_info = ErrorInfo(
        code=code,
        message=message,
        details=details
    )
    
    response = ErrorResponseData(
        success=False,
        error=error_info,
        meta=MetaInfoError(
            timestamp=datetime.now(timezone.utc).isoformat(),
            path=str(request.url.path) if request else None,
            method=request.method if request else None
        )
    )
        
    return SafeJSONResponse(
        status_code=status_code,
        content=response.model_dump(exclude_none=True)
    )


def paginated_response(
    data: List[Any],
    page: int,
    page_size: int,
    total: int,
    message: Optional[str] = None,
    status_code: int = 200
) -> JSONResponse:
    """
    Create a standardized paginated response
    
    Args:
        data: List of items for current page
        page: Current page number (1-indexed)
        page_size: Number of items per page
        total: Total number of items
        message: Optional success message
        status_code: HTTP status code (default: 200)
    
    Returns:
        JSONResponse with standardized paginated format
    """
    # Calculate total pages
    total_pages = (total + page_size - 1) // page_size if page_size > 0 else 1
    if total_pages == 0:
        total_pages = 1
    
    pagination = PaginationMeta(
        page=page,
        page_size=page_size,
        total_pages=total_pages,
        total=total,
        has_next_page=page < total_pages,
        has_previous_page=page > 1
    )
    
    meta = MetaInfo(
        timestamp=datetime.now(timezone.utc).isoformat(),
        pagination=pagination
    )
    
    response = SuccessResponseData(
        success=True,
        data=data,
        meta=meta,
        message=message
    )
    
    return SafeJSONResponse(
        status_code=status_code,
        content=response.model_dump(exclude_none=True)
    )

