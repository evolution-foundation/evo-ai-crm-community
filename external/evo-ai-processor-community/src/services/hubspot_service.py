"""
HubSpot MCP OAuth and API integration service.

This service uses the MCP OAuth Protected Resource discovery pattern:
1. Discover OAuth requirements from HubSpot MCP server
2. Perform OAuth flow using discovered authorization server
3. Store tokens for use in MCP server headers

This follows the standard MCP OAuth pattern for HubSpot MCP.
"""

import logging
from typing import Optional, Dict, Any
import httpx

from src.services.mcp_oauth_service import MCPOAuthService

logger = logging.getLogger(__name__)


class HubSpotService(MCPOAuthService):
    """Service for HubSpot MCP OAuth and API operations."""

    # Default HubSpot MCP URL
    DEFAULT_MCP_URL = "https://mcp.hubspot.com/mcp"

    def __init__(
        self,
        client_id: str,
        client_secret: str,
        redirect_uri: str,
        core_service_url: str,
        user_token: str,
        mcp_url: Optional[str] = None,
        tenant_id: Optional[str] = None
    ):
        """
        Initialize HubSpot MCP service.

        Args:
            client_id: HubSpot OAuth client ID
            client_secret: HubSpot OAuth client secret
            redirect_uri: OAuth redirect URI
            core_service_url: Base URL for evo-ai-core-service API
            user_token: User authentication token for API calls
            mcp_url: Optional custom MCP URL (defaults to HubSpot MCP)
            tenant_id: Tenant id forwarded to core-service (enterprise) as
                X-Evo-Tenant-Id on internal integration calls.
        """
        effective_mcp_url = mcp_url or self.DEFAULT_MCP_URL

        # Validate required credentials for HubSpot
        if not client_id:
            raise ValueError("HubSpot client_id is required")
        if not client_secret:
            raise ValueError("HubSpot client_secret is required (HubSpot OAuth requires client_secret for token exchange)")
        if not redirect_uri:
            raise ValueError("HubSpot redirect_uri is required")

        super().__init__(
            mcp_url=effective_mcp_url,
            redirect_uri=redirect_uri,
            core_service_url=core_service_url,
            user_token=user_token,
            provider_name="hubspot",
            client_id=client_id,
            client_secret=client_secret,
            tenant_id=tenant_id
        )

        logger.info(
            f"HubSpotService initialized with MCP URL: {effective_mcp_url}, "
            f"client_id={'***' + client_id[-4:] if len(client_id) > 4 else '***'}, "
            f"client_secret={'present' if client_secret else 'MISSING'} (length: {len(client_secret) if client_secret else 0})"
        )

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

        Overrides parent method to add HubSpot-specific user info retrieval.

        Args:
            agent_id: Agent ID
            code: Authorization code from OAuth callback
            state: State parameter from OAuth callback
            code_verifier: Optional PKCE code verifier (loaded from storage if not provided)
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
        
        # If successful, get HubSpot user info
        if result.get("success") and not result.get("username"):
            try:
                access_token = None
                # Get access token from stored credentials
                credentials = await self._load_credentials(agent_id)
                if credentials:
                    access_token = credentials.get("access_token")
                
                if access_token:
                    # Get HubSpot user info
                    async with httpx.AsyncClient() as client:
                        # Try primary endpoint first
                        user_response = await client.get(
                            f"https://api.hubapi.com/oauth/v1/access-tokens/{access_token}",
                            headers={
                                "Authorization": f"Bearer {access_token}",
                                "Accept": "application/json"
                            },
                            timeout=30.0
                        )
                        # Try alternative endpoint if primary fails
                        if user_response.status_code != 200:
                            user_response = await client.get(
                                "https://api.hubapi.com/integrations/v1/me",
                                headers={
                                    "Authorization": f"Bearer {access_token}",
                                    "Accept": "application/json"
                                },
                                timeout=30.0
                            )
                        
                        if user_response.status_code == 200:
                            user_data = user_response.json()
                            
                            result["username"] = user_data.get("user") or user_data.get("portalId")
                            result["email"] = user_data.get("user") or user_data.get("email")
                            result["user_data"] = user_data
                            
                            # Update stored credentials with user info
                            existing_credentials = await self._load_credentials(agent_id)
                            refresh_token = existing_credentials.get("refresh_token") if existing_credentials else None
                            expires_in = existing_credentials.get("expires_in") if existing_credentials else None
                            
                            await self._store_credentials(
                                agent_id=agent_id,
                                mcp_url=self.mcp_url,
                                access_token=access_token,
                                username=result["username"],
                                email=result["email"],
                                user_data=user_data,
                                oauth_metadata=self._oauth_metadata or {},
                                refresh_token=refresh_token,
                                expires_in=expires_in
                            )
            except Exception as e:
                logger.warning(f"Could not fetch HubSpot user info: {e}")
                # Don't fail the authorization if user info fetch fails
        
        return result

    async def generate_authorization_url(
        self,
        agent_id: str,
        scopes: Optional[list] = None,
    ) -> str:
        """
        Generate OAuth 2.0 authorization URL for HubSpot MCP.

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
            logger.info("Discovering OAuth requirements from HubSpot MCP server...")
            await self.discover_oauth_requirements()

        # Generate authorization URL using parent method
        return await super().generate_authorization_url(
            agent_id=agent_id,
            scopes=scopes
        )

