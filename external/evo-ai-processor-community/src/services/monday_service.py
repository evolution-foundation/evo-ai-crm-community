"""
Monday MCP OAuth and API integration service.

This service uses the MCP OAuth Protected Resource discovery pattern:
1. Discover OAuth requirements from Monday MCP server
2. Perform OAuth flow using discovered authorization server
3. Store tokens for use in MCP server headers

This follows the standard MCP OAuth pattern for Monday MCP.
"""

import logging
from typing import Optional, Dict, Any
import httpx

from src.services.mcp_oauth_service import MCPOAuthService

logger = logging.getLogger(__name__)


class MondayService(MCPOAuthService):
    """Service for Monday MCP OAuth and API operations."""

    # Default Monday MCP URL
    DEFAULT_MCP_URL = "https://mcp.monday.com/mcp"

    def __init__(
        self,
        redirect_uri: str,
        core_service_url: str,
        user_token: str,
        client_id: Optional[str] = None,
        client_secret: Optional[str] = None,
        mcp_url: Optional[str] = None,
        tenant_id: Optional[str] = None
    ):
        """
        Initialize Monday MCP service.

        Args:
            redirect_uri: OAuth redirect URI
            core_service_url: Base URL for evo-ai-core-service API
            user_token: User authentication token for API calls
            client_id: Monday OAuth client ID (optional, can be obtained via dynamic registration)
            client_secret: Monday OAuth client secret (optional, can be obtained via dynamic registration)
            mcp_url: Optional custom MCP URL (defaults to Monday MCP)
            tenant_id: Tenant id forwarded to core-service (enterprise) as
                X-Evo-Tenant-Id on internal integration calls.
        """
        effective_mcp_url = mcp_url or self.DEFAULT_MCP_URL

        super().__init__(
            mcp_url=effective_mcp_url,
            redirect_uri=redirect_uri,
            core_service_url=core_service_url,
            user_token=user_token,
            provider_name="monday",
            client_id=client_id,
            client_secret=client_secret,
            tenant_id=tenant_id
        )

        logger.info(f"MondayService initialized with MCP URL: {effective_mcp_url}")

    async def complete_authorization(
        self,
        agent_id: str,
        code: str,
        state: str,
        code_verifier: Optional[str] = None,
        db: Optional[Any] = None
    ) -> Dict[str, Any]:
        """
        Complete OAuth authorization flow and store tokens.

        Overrides parent method to add Monday-specific user info retrieval.

        Args:
            agent_id: Agent ID
            code: Authorization code from OAuth callback
            state: State parameter from OAuth callback
            code_verifier: Optional PKCE code verifier (if not provided, will be loaded from storage)
            db: Optional database session for direct DB access

        Returns:
            Dictionary with success status, username, and user info
        """
        # Call parent method to handle OAuth flow
        result = await super().complete_authorization(
            agent_id=agent_id,
            code=code,
            state=state,
            code_verifier=code_verifier,
            db=db
        )
        
        # If successful, get Monday user info
        if result.get("success"):
            try:
                # Get access token from stored credentials (should have been saved by parent)
                credentials = await self._load_credentials(agent_id)
                if not credentials:
                    return result
                
                access_token = credentials.get("access_token")
                if not access_token:
                    return result
                
                # Note: Monday MCP tokens may not work with the GraphQL API
                # The token is already saved, so user info fetch is optional
                # Try to get Monday user info via GraphQL API
                try:
                    async with httpx.AsyncClient() as client:
                        user_response = await client.post(
                            "https://api.monday.com/v2",
                            json={
                                "query": "query { me { id name email } }"
                            },
                            headers={
                                "Authorization": f"Bearer {access_token}",
                                "Content-Type": "application/json"
                            },
                            timeout=30.0
                        )
                        
                        if user_response.status_code == 200:
                            user_data = user_response.json()
                            
                            if user_data.get("data", {}).get("me"):
                                me = user_data["data"]["me"]
                                username = me.get("name") or me.get("id")
                                email = me.get("email")
                                
                                result["username"] = username
                                result["email"] = email
                                result["user_data"] = me
                                
                                # Update stored credentials with user info, preserving all existing fields
                                # Load existing config to preserve refresh_token, expires_in, etc.
                                existing_config = await self._load_credentials(agent_id) or {}
                                
                                # Update with user info while preserving all other fields
                                await self._store_credentials(
                                    agent_id=agent_id,
                                    mcp_url=self.mcp_url,
                                    access_token=access_token,  # Preserve access_token
                                    username=username,
                                    email=email,
                                    user_data=me,
                                    oauth_metadata=self._oauth_metadata or existing_config.get("oauth_metadata", {}),
                                    refresh_token=existing_config.get("refresh_token"),  # Preserve refresh_token
                                    expires_in=existing_config.get("expires_in")  # Preserve expires_in
                                )
                                logger.info(f"Updated Monday credentials with user info: username={username}, email={email}")
                            else:
                                logger.info("Monday user info response did not contain 'me' data")
                        else:
                            logger.info(
                                f"Monday GraphQL API returned {user_response.status_code}. "
                                f"This is expected - MCP tokens may not work with GraphQL API. "
                                f"Token is saved and integration is ready to use."
                            )
                except httpx.HTTPStatusError as http_error:
                    logger.info(
                        f"Monday GraphQL API returned {http_error.response.status_code}. "
                        f"This is expected - MCP tokens may not work with GraphQL API. "
                        f"Token is saved and integration is ready to use."
                    )
            except Exception as e:
                logger.info(
                    f"Could not fetch Monday user info: {e}. "
                    f"This is not critical - the token is already saved and the integration is ready to use."
                )
                # Don't fail the authorization if user info fetch fails
                import traceback
                logger.debug(traceback.format_exc())
        
        return result

    async def generate_authorization_url(
        self,
        agent_id: str,
        scopes: Optional[list] = None,
    ) -> str:
        """
        Generate OAuth 2.0 authorization URL for Monday MCP.

        First discovers OAuth requirements from the MCP server, then generates
        the authorization URL using the discovered authorization server and scopes.

        Args:
            agent_id: Agent ID
            scopes: Optional list of scopes to request (defaults to all supported scopes)

        Returns:
            Authorization URL for user to visit
        """
        # Discover OAuth requirements if not already discovered
        if not self._oauth_metadata:
            logger.info("Discovering OAuth requirements from Monday MCP server...")
            await self.discover_oauth_requirements()

        # Generate authorization URL using parent method
        return await super().generate_authorization_url(
            agent_id=agent_id,
            scopes=scopes
        )

