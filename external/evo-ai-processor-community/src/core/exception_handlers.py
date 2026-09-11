"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Danilo Leone                                                              │
│ @file: exception_handlers.py                                                 │
│ Global exception handlers for FastAPI to convert to standardized format      │
│ Creation date: January 2025                                                  │
├──────────────────────────────────────────────────────────────────────────────┤
│ @copyright © Evolution API 2025. All rights reserved.                        │
│ Licensed under the Apache License, Version 2.0                               │
└──────────────────────────────────────────────────────────────────────────────┘
"""

from fastapi import Request
from fastapi.exceptions import HTTPException
from fastapi.responses import JSONResponse
from src.core.exceptions import BaseAPIException
from src.core.error_codes import (
    VALIDATION_ERROR,
    UNAUTHORIZED,
    FORBIDDEN,
    NOT_FOUND,
    INTERNAL_ERROR,
    BAD_REQUEST,
    CONFLICT,
    EXTERNAL_SERVICE_ERROR,
    TIMEOUT_ERROR
)
from src.utils.response import error_response


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
        422: VALIDATION_ERROR,
        500: INTERNAL_ERROR,
        502: EXTERNAL_SERVICE_ERROR,
        503: EXTERNAL_SERVICE_ERROR,
        504: TIMEOUT_ERROR,
    }
    
    return status_mapping.get(status_code, INTERNAL_ERROR)


async def http_exception_handler(request: Request, exc: HTTPException) -> JSONResponse:
    """
    Global handler for HTTPException to convert to standardized error format
    
    Args:
        request: FastAPI request object
        exc: HTTPException instance
    
    Returns:
        JSONResponse with standardized error format
    """
    # Extract error code from exception detail if it's a dict (BaseAPIException)
    error_code = map_status_to_error_code(exc.status_code)
    error_message = str(exc.detail)
    error_details = None
    
    # Check if detail is a dict (from BaseAPIException)
    if isinstance(exc.detail, dict):
        error_code = exc.detail.get("error_code", error_code)
        error_message = exc.detail.get("error", error_message)
        error_details = exc.detail.get("details")
    
    return error_response(
        request,
        code=error_code,
        message=error_message,
        details=error_details,
        status_code=exc.status_code
    )


async def base_api_exception_handler(request: Request, exc: BaseAPIException) -> JSONResponse:
    """
    Handler for BaseAPIException to convert to standardized error format
    
    Args:
        request: FastAPI request object
        exc: BaseAPIException instance
    
    Returns:
        JSONResponse with standardized error format
    """
    # Extract error code from exception (stored as attribute)
    error_code = getattr(exc, 'error_code', None)
    if not error_code:
        error_code = map_status_to_error_code(exc.status_code)
    
    error_message = str(exc.detail.get("error", exc.detail)) if isinstance(exc.detail, dict) else str(exc.detail)
    error_details = exc.detail.get("details") if isinstance(exc.detail, dict) else None
    
    return error_response(
        request,
        code=error_code,
        message=error_message,
        details=error_details,
        status_code=exc.status_code
    )

