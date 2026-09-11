"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: System                                                              │
│ @file: responses.py                                                           │
│ Generic response schemas for Swagger documentation                           │
│ Creation date: December 2025                                                  │
├──────────────────────────────────────────────────────────────────────────────┤
│ @copyright © Evolution API 2025. All rights reserved.                        │
│ Licensed under the Apache License, Version 2.0                               │
└──────────────────────────────────────────────────────────────────────────────┘
"""

from typing import Optional, Generic, TypeVar, List
from pydantic import BaseModel, Field
from pydantic.generics import GenericModel
from src.utils.response import MetaInfo, MetaInfoPagination, ErrorInfo, MetaInfoError

# Type variable for generic responses
T = TypeVar('T')


class SuccessResponse(GenericModel, Generic[T]):
    """
    Standard success response wrapper.
    """
    success: bool = Field(True, description="Success indicator")
    data: T = Field(..., description="Response payload")
    meta: MetaInfo = Field(..., description="Metadata")
    message: Optional[str] = Field(None, description="Optional success message")


class PaginatedResponse(GenericModel, Generic[T]):
    """
    Generic paginated response schema for Swagger documentation.
    
    This schema wraps the standardized paginated response format used by paginated_response().
    """
    success: bool = Field(True, description="Success indicator")
    data: List[T] = Field(..., description="List of items for current page")
    meta: MetaInfoPagination = Field(..., description="Metadata including pagination")
    message: Optional[str] = Field(None, description="Optional success message")


class ErrorResponse(BaseModel):
    """
    Standard error response schema matching error_response() return format.
    
    This schema matches the structure returned by error_response() function,
    which always uses ErrorInfo for the error field.
    """
    success: bool = Field(False, description="Success indicator")
    error: ErrorInfo = Field(..., description="Error information")
    meta: MetaInfoError = Field(..., description="Metadata")
