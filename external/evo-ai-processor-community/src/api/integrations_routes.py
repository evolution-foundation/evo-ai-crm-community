"""
Integrations API routes - Bulk operations.

Provides endpoints for:
- Getting all integration configurations at once
- Checking credentials status for all integrations
"""

import logging
from typing import Dict, Any
from fastapi import APIRouter, HTTPException, Depends, status, Request
from sqlalchemy.orm import Session

from src.api.dependencies import get_current_user
from src.config.database import get_db
from src.middleware.permissions import RequirePermission
from src.services.global_config_service import get_global_config_service
from src.utils.response import success_response, error_response, map_status_to_error_code
from src.schemas.responses import SuccessResponse, ErrorResponse
from src.schemas.response_models import IntegrationListResponse

logger = logging.getLogger(__name__)

router = APIRouter(
    prefix="/agents/{agent_id}/integrations",
    tags=["integrations"],
)


def sanitize_config(config: Dict[str, Any]) -> Dict[str, Any]:
    """
    Remove ALL sensitive fields from integration config before returning to frontend.
    
    Security: Frontend should NEVER receive access_token, client_id, or any credentials.
    Discovery of tools should be done via backend endpoints that use stored credentials.
    
    Args:
        config: Integration configuration dictionary
        
    Returns:
        Sanitized configuration with all sensitive fields removed
    """
    if not config:
        return config
    
    # Create a copy to avoid modifying the original
    sanitized = config.copy()
    
    # List of sensitive fields to remove (including access_token and client_id)
    sensitive_fields = [
        "access_token",
        "client_id",
        "client_secret",
        "refresh_token",
        "pkce_verifiers",
        "token",  # Google Calendar token
        "code_verifier",
    ]
    
    # Track what was removed for logging
    removed_fields = []
    
    # Remove sensitive fields
    for field in sensitive_fields:
        if field in sanitized:
            sanitized.pop(field, None)
            removed_fields.append(field)
    
    # Remove any token-like values (REST API keys, etc.)
    # Check for tokens starting with sk_, rk_, pk_ (Stripe REST API keys)
    for key, value in list(sanitized.items()):
        if isinstance(value, str) and value.startswith(("sk_", "rk_", "pk_")):
            sanitized.pop(key, None)
            removed_fields.append(key)
            logger.debug(f"Removed sensitive token field '{key}' from config")
    
    if removed_fields:
        logger.info(f"Sanitized config: removed sensitive fields: {', '.join(removed_fields)}")
    
    return sanitized


async def check_credentials_configured(provider: str, config_service) -> bool:
    """
    Check if credentials are configured for a provider in global config.

    Args:
        provider: Provider name (github, notion, stripe, etc.)
        config_service: GlobalConfigService instance

    Returns:
        True if credentials are configured, False otherwise
    """
    try:
        if provider == "github":
            creds = await config_service.get_github_credentials()
            return bool(creds.get("client_id") and creds.get("client_secret") and creds.get("redirect_uri"))
        elif provider == "notion":
            creds = await config_service.get_notion_credentials()
            return bool(creds.get("redirect_uri"))
        elif provider == "stripe":
            creds = await config_service.get_stripe_credentials()
            return bool(creds.get("redirect_uri"))
        elif provider == "linear":
            creds = await config_service.get_linear_credentials()
            return bool(creds.get("redirect_uri"))
        elif provider == "monday":
            creds = await config_service.get_monday_credentials()
            return bool(creds.get("redirect_uri"))
        elif provider == "atlassian":
            creds = await config_service.get_atlassian_credentials()
            return bool(creds.get("redirect_uri"))
        elif provider == "asana":
            creds = await config_service.get_asana_credentials()
            return bool(creds.get("redirect_uri"))
        elif provider == "hubspot":
            creds = await config_service.get_hubspot_credentials()
            return bool(creds.get("client_id") and creds.get("client_secret") and creds.get("redirect_uri"))
        elif provider == "paypal":
            creds = await config_service.get_paypal_credentials()
            return bool(creds.get("client_id") and creds.get("client_secret") and creds.get("redirect_uri"))
        elif provider == "canva":
            creds = await config_service.get_canva_credentials()
            return bool(creds.get("redirect_uri"))
        elif provider == "supabase":
            creds = await config_service.get_supabase_credentials()
            return bool(creds.get("redirect_uri"))
        elif provider == "google_calendar":
            creds = await config_service.get_google_calendar_credentials()
            return bool(creds.get("client_id") and creds.get("client_secret") and creds.get("redirect_uri"))
        elif provider == "google_sheets":
            creds = await config_service.get_google_sheets_credentials()
            return bool(creds.get("client_id") and creds.get("client_secret") and creds.get("redirect_uri"))
        return False
    except Exception as e:
        logger.warning(f"Error checking credentials for {provider}: {e}")
        return False


@router.get(
    "",
    response_model=SuccessResponse[IntegrationListResponse],
    responses={
        200: {"description": "All configurations retrieved successfully"},
        401: {"model": ErrorResponse, "description": "Authentication token required"},
        500: {"model": ErrorResponse, "description": "Internal server error"}
    }
)
async def get_all_configurations(
    agent_id: str,
    request: Request,
    db: Session = Depends(get_db),
    _permission: None = Depends(RequirePermission("integrations", "read")),
    _: dict = Depends(get_current_user),
):
    """
    Get all integration configurations at once, including credentials status.
    
    Returns a dictionary with:
    - configs: Dictionary mapping provider names to their configurations
    - credentials_configured: Dictionary mapping provider names to boolean status
    """
    try:
        from src.services.agent_service import get_agent_integrations
        
        # Get user token from request headers
        auth_header = request.headers.get("Authorization", "")
        user_token = auth_header.replace("Bearer ", "") if auth_header.startswith("Bearer ") else ""
        
        if not user_token:
            return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_401_UNAUTHORIZED),
            message="Authentication token required",
            status_code=status.HTTP_401_UNAUTHORIZED
        )
        
        # Get all integrations from database
        integrations = await get_agent_integrations(db, agent_id)

        # Organize integrations by provider
        configs: Dict[str, Dict[str, Any]] = {}
        credentials_providers = {}  # Track which providers have credentials (e.g., google_sheets_credentials)

        for integration in integrations:
            provider = integration.get("provider", "").lower()
            if provider:
                config = integration.get("config", {})
                # Store connected status before sanitizing (access_token will be removed)
                has_access_token = bool(config.get("access_token") or config.get("token") or config.get("refresh_token"))

                # For credential providers (like google_sheets_credentials), track separately
                if provider.endswith("_credentials"):
                    credentials_providers[provider] = has_access_token
                    continue  # Don't add credentials to main configs

                # Sanitize config to remove sensitive fields (access_token, client_secret, etc.)
                sanitized_config = sanitize_config(config)
                # Set connected status based on access_token presence (before sanitization)
                sanitized_config["connected"] = has_access_token
                configs[provider] = sanitized_config

        # For Google integrations, check if credentials exist in separate provider
        # Google Sheets credentials are in "google_sheets_credentials", config in "google_sheets"
        # Google Calendar credentials are in "google_calendar_credentials", config in "google_calendar"
        if "google_sheets_credentials" in credentials_providers:
            if "google_sheets" in configs:
                configs["google_sheets"]["connected"] = credentials_providers["google_sheets_credentials"]
            else:
                configs["google_sheets"] = {
                    "provider": "google_sheets",
                    "connected": credentials_providers["google_sheets_credentials"]
                }

        if "google_calendar_credentials" in credentials_providers:
            if "google_calendar" in configs:
                configs["google_calendar"]["connected"] = credentials_providers["google_calendar_credentials"]
            else:
                configs["google_calendar"] = {
                    "provider": "google_calendar",
                    "connected": credentials_providers["google_calendar_credentials"]
                }

        # Check credentials status for all providers
        config_service = get_global_config_service()
        credentials_configured: Dict[str, bool] = {}

        providers = ["github", "notion", "stripe", "linear", "monday", "atlassian", "asana", "hubspot", "paypal", "canva", "supabase", "google_calendar", "google_sheets"]
        for provider in providers:
            credentials_configured[provider] = await check_credentials_configured(provider, config_service)

        # For providers without config, return default disconnected state
        for provider in providers:
            if provider not in configs:
                configs[provider] = {
                    "provider": provider,
                    "connected": False
                }
        
        return success_response(
            data={
                "configs": configs,
                "credentials_configured": credentials_configured
            },
            message="All configurations retrieved successfully"
        )
    except Exception as e:
        logger.error(f"Error getting all configurations: {e}")
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_500_INTERNAL_SERVER_ERROR),
            message=f"Failed to get configurations: {str(e)}",
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR
        )

