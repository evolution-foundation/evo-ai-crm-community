"""
Asana MCP OAuth and API integration service.
This service uses the MCP OAuth Protected Resource discovery pattern:
1. Discover OAuth requirements from Asana MCP server
2. Perform OAuth flow using discovered authorization server
3. Store tokens for use in MCP server headers
This follows the standard MCP OAuth pattern for Asana MCP.
"""
import logging
from typing import Optional, Dict, Any
import httpx
from src.services.mcp_oauth_service import MCPOAuthService
logger = logging.getLogger(__name__)
class AsanaService(MCPOAuthService):
    """Service for Asana MCP OAuth and API operations."""
    # Default Asana MCP URL
    DEFAULT_MCP_URL = "https://mcp.asana.com/mcp"
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
        Initialize Asana MCP service.
        Args:
            redirect_uri: OAuth redirect URI
            core_service_url: Base URL for evo-ai-core-service API
            user_token: User authentication token for API calls
            client_id: Asana OAuth client ID (optional, can be obtained via dynamic registration)
            client_secret: Asana OAuth client secret (optional, can be obtained via dynamic registration)
            mcp_url: Optional custom MCP URL (defaults to Asana MCP)
            tenant_id: Tenant id forwarded to core-service (enterprise) as
                X-Evo-Tenant-Id on internal integration calls.
        """
        effective_mcp_url = mcp_url or self.DEFAULT_MCP_URL
        super().__init__(
            mcp_url=effective_mcp_url,
            redirect_uri=redirect_uri,
            core_service_url=core_service_url,
            user_token=user_token,
            provider_name="asana",
            client_id=client_id,
            client_secret=client_secret,
            tenant_id=tenant_id
        )
        logger.info(f"AsanaService initialized with MCP URL: {effective_mcp_url}")
    async def complete_authorization(
        self,
        agent_id: str,
        code: str,
        state: str,
        db: Optional[Any] = None
    ) -> Dict[str, Any]:
        """
        Complete OAuth authorization flow and store tokens.
        Overrides parent method to add Asana-specific user info retrieval.
        Args:
            agent_id: Agent ID
            code: Authorization code from OAuth callback
            state: State parameter from OAuth callback
            db: Optional database session for direct DB access
        Returns:
            Dictionary with success status, username, and user info
        """
        # Call parent method to handle OAuth flow
        result = await super().complete_authorization(
            agent_id=agent_id,
            code=code,
            state=state,
            db=db
        )
        
        # If successful, get Asana user info
        if result.get("success"):
            try:
                # Get access token from stored credentials (should have been saved by parent)
                credentials = await self._load_credentials(agent_id)
                if not credentials:
                    logger.warning("No credentials found after authorization - token may not have been saved")
                    return result
                
                access_token = credentials.get("access_token")
                if not access_token:
                    logger.warning("No access_token found in stored credentials")
                    return result
                
                # Get Asana user info
                async with httpx.AsyncClient() as client:
                    user_response = await client.get(
                        "https://app.asana.com/api/1.0/users/me",
                        headers={
                            "Authorization": f"Bearer {access_token}",
                            "Accept": "application/json"
                        },
                        timeout=30.0
                    )
                    user_response.raise_for_status()
                    user_data = user_response.json()
                    
                    if user_data.get("data"):
                        user = user_data["data"]
                        username = user.get("name") or user.get("gid")
                        email = user.get("email")
                        
                        result["username"] = username
                        result["email"] = email
                        result["user_data"] = user
                        
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
                            user_data=user,
                            oauth_metadata=self._oauth_metadata or existing_config.get("oauth_metadata", {}),
                            refresh_token=existing_config.get("refresh_token"),  # Preserve refresh_token
                            expires_in=existing_config.get("expires_in")  # Preserve expires_in
                        )
                        logger.info(f"Updated Asana credentials with user info: username={username}, email={email}")
            except Exception as e:
                logger.warning(f"Could not fetch Asana user info: {e}")
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
        Generate OAuth 2.0 authorization URL for Asana MCP.
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
            logger.info("Discovering OAuth requirements from Asana MCP server...")
            await self.discover_oauth_requirements()
        # Generate authorization URL using parent method
        return await super().generate_authorization_url(
            agent_id=agent_id,
            scopes=scopes
        )
