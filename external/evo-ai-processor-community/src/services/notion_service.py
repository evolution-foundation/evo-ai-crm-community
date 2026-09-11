"""
Notion MCP OAuth and API integration service.
This service uses the MCP OAuth Protected Resource discovery pattern:
1. Discover OAuth requirements from Notion MCP server
2. Perform OAuth flow using discovered authorization server
3. Store tokens for use in MCP server headers
This follows the standard MCP OAuth pattern for Notion MCP.
"""
import logging
from typing import Optional, Dict, Any
import httpx
from src.services.mcp_oauth_service import MCPOAuthService
logger = logging.getLogger(__name__)
class NotionService(MCPOAuthService):
    """Service for Notion MCP OAuth and API operations."""
    # Default Notion MCP URL
    DEFAULT_MCP_URL = "https://mcp.notion.com/mcp"
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
        Initialize Notion MCP service.
        Args:
            redirect_uri: OAuth redirect URI
            core_service_url: Base URL for evo-ai-core-service API
            user_token: User authentication token for API calls
            client_id: Notion OAuth client ID (optional, can be obtained via dynamic registration)
            client_secret: Notion OAuth client secret (optional, can be obtained via dynamic registration)
            mcp_url: Optional custom MCP URL (defaults to Notion MCP)
            tenant_id: Tenant id forwarded to core-service (enterprise) as
                X-Evo-Tenant-Id on internal integration calls.
        """
        effective_mcp_url = mcp_url or self.DEFAULT_MCP_URL
        super().__init__(
            mcp_url=effective_mcp_url,
            redirect_uri=redirect_uri,
            core_service_url=core_service_url,
            user_token=user_token,
            provider_name="notion",
            client_id=client_id,
            client_secret=client_secret,
            tenant_id=tenant_id
        )
        logger.info(f"NotionService initialized with MCP URL: {effective_mcp_url}")
    async def complete_authorization(
        self,
        agent_id: str,
        code: str,
        state: str,
        db: Optional[Any] = None
    ) -> Dict[str, Any]:
        """
        Complete OAuth authorization flow and store tokens.
        Overrides parent method to add Notion-specific user info retrieval.
        Args:
            agent_id: Agent ID
            code: Authorization code from OAuth callback
            state: State parameter from OAuth callback
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
        
        # If successful, get Notion user info
        if result.get("success") and not result.get("username"):
            try:
                access_token = None
                # Get access token from stored credentials
                credentials = await self._load_credentials(agent_id)
                if credentials:
                    access_token = credentials.get("access_token")
                
                if access_token:
                    # Get Notion user info
                    async with httpx.AsyncClient() as client:
                        user_response = await client.get(
                            "https://api.notion.com/v1/users/me",
                            headers={
                                "Authorization": f"Bearer {access_token}",
                                "Notion-Version": "2022-06-28"
                            },
                            timeout=30.0
                        )
                        user_response.raise_for_status()
                        user_data = user_response.json()
                        
                        result["username"] = user_data.get("name") or user_data.get("id")
                        result["email"] = user_data.get("person", {}).get("email") if user_data.get("type") == "person" else None
                        result["user_data"] = user_data
                        
                        # Update stored credentials with user info
                        await self._store_credentials(
                            agent_id=agent_id,
                            mcp_url=self.mcp_url,
                            access_token=access_token,
                            username=result["username"],
                            email=result["email"],
                            user_data=user_data,
                            oauth_metadata=self._oauth_metadata or {},
                            db=db
                        )
            except Exception as e:
                logger.warning(f"Could not fetch Notion user info: {e}")
                # Don't fail the authorization if user info fetch fails
        
        return result
    async def generate_authorization_url(
        self,
        agent_id: str,
        scopes: Optional[list] = None,
    ) -> str:
        """
        Generate OAuth 2.0 authorization URL for Notion MCP.
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
            logger.info("Discovering OAuth requirements from Notion MCP server...")
            await self.discover_oauth_requirements()
        # Generate authorization URL using parent method
        return await super().generate_authorization_url(
            agent_id=agent_id,
            scopes=scopes
        )
