"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Danilo Leone                                                              │
│ @file: error_codes.py                                                        │
│ Standardized error codes for API responses                                   │
│ Creation date: January 2025                                                  │
├──────────────────────────────────────────────────────────────────────────────┤
│ @copyright © Evolution API 2025. All rights reserved.                        │
│ Licensed under the Apache License, Version 2.0                               │
└──────────────────────────────────────────────────────────────────────────────┘
"""

# Standard error codes matching other services (evo-auth-service, evo-ai-crm, evo-ai-core-service)

# 400 Bad Request
VALIDATION_ERROR = "VALIDATION_ERROR"
INVALID_INPUT = "INVALID_INPUT"
MISSING_REQUIRED_FIELD = "MISSING_REQUIRED_FIELD"
BAD_REQUEST = "BAD_REQUEST"

# 401 Unauthorized
UNAUTHORIZED = "UNAUTHORIZED"
INVALID_TOKEN = "INVALID_TOKEN"
TOKEN_EXPIRED = "TOKEN_EXPIRED"

# 403 Forbidden
FORBIDDEN = "FORBIDDEN"
INSUFFICIENT_PERMISSIONS = "INSUFFICIENT_PERMISSIONS"

# 404 Not Found
NOT_FOUND = "NOT_FOUND"
RESOURCE_NOT_FOUND = "RESOURCE_NOT_FOUND"

# 409 Conflict
RESOURCE_ALREADY_EXISTS = "RESOURCE_ALREADY_EXISTS"
CONFLICT = "CONFLICT"

# 413 Payload Too Large
PAYLOAD_TOO_LARGE = "PAYLOAD_TOO_LARGE"

# 422 Unprocessable Entity
BUSINESS_RULE_VIOLATION = "BUSINESS_RULE_VIOLATION"
INVALID_STATE_TRANSITION = "INVALID_STATE_TRANSITION"

# 429 Too Many Requests
# CRM-236: an upstream model provider refusing us for quota/rate reasons is not
# an internal error, and reporting it as one sent operators bug-hunting through
# our code when the account had simply run out of free-tier requests.
RATE_LIMIT_EXCEEDED = "RATE_LIMIT_EXCEEDED"

# 499 Client Closed Request (nginx convention; no RFC status exists)
CLIENT_CLOSED_REQUEST = "CLIENT_CLOSED_REQUEST"

# 500 Internal Server Error
INTERNAL_ERROR = "INTERNAL_ERROR"
DATABASE_ERROR = "DATABASE_ERROR"
EXTERNAL_SERVICE_ERROR = "EXTERNAL_SERVICE_ERROR"
TIMEOUT_ERROR = "TIMEOUT_ERROR"

