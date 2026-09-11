"""
PayPal MCP OAuth and API integration service.

This service uses the MCP OAuth Authorization Server discovery pattern:
1. Discover OAuth requirements from PayPal MCP server
2. Perform OAuth flow using discovered authorization server
3. Store tokens for use in MCP server headers

This follows the standard MCP OAuth pattern for PayPal MCP, with PayPal-specific
token endpoint handling using Basic Auth as per PayPal REST API documentation:
https://developer.paypal.com/api/rest/#link-getclientidandclientsecret
"""

import logging
import base64
import json
from datetime import datetime
from typing import Optional, Dict, Any
from urllib.parse import quote
import httpx

from src.services.mcp_oauth_service import MCPOAuthService

logger = logging.getLogger(__name__)


class PayPalService(MCPOAuthService):
    """Service for PayPal MCP OAuth and API operations."""

    # Default PayPal MCP URLs (per PayPal MCP documentation)
    DEFAULT_MCP_URL_PRODUCTION = "https://mcp.paypal.com"
    DEFAULT_MCP_URL_SANDBOX = "https://mcp.sandbox.paypal.com"
    DEFAULT_MCP_URL = DEFAULT_MCP_URL_PRODUCTION  # Default to production
    
    # PayPal REST API token endpoints (per PayPal REST API documentation)
    PAYPAL_SANDBOX_TOKEN_ENDPOINT = "https://api-m.sandbox.paypal.com/v1/oauth2/token"
    PAYPAL_PRODUCTION_TOKEN_ENDPOINT = "https://api-m.paypal.com/v1/oauth2/token"
    
    # PayPal OAuth authorization endpoints (per PayPal OAuth documentation)
    PAYPAL_SANDBOX_AUTHORIZATION_ENDPOINT = "https://www.sandbox.paypal.com/webapps/auth/protocol/openidconnect/v1/authorize"
    PAYPAL_PRODUCTION_AUTHORIZATION_ENDPOINT = "https://www.paypal.com/webapps/auth/protocol/openidconnect/v1/authorize"

    def __init__(
        self,
        redirect_uri: str,
        core_service_url: str,
        user_token: str,
        client_id: Optional[str] = None,
        client_secret: Optional[str] = None,
        mcp_url: Optional[str] = None,
        environment: Optional[str] = None,
        tenant_id: Optional[str] = None
    ):
        """
        Initialize PayPal MCP service.

        Args:
            redirect_uri: OAuth redirect URI
            core_service_url: Base URL for evo-ai-core-service API
            user_token: User authentication token for API calls
            client_id: PayPal OAuth client ID
            client_secret: PayPal OAuth client secret
            mcp_url: Optional custom MCP URL (defaults to PayPal MCP)
            environment: Optional environment ("sandbox" or "production"),
                        defaults to detecting from mcp_url
            tenant_id: Tenant id forwarded to core-service (enterprise) as
                X-Evo-Tenant-Id on internal integration calls.
        """
        # Detect environment from MCP URL if not provided
        if environment is None:
            if mcp_url and "sandbox" in mcp_url.lower():
                environment = "sandbox"
            else:
                environment = "production"
        
        # Set default MCP URL based on environment if not provided
        if mcp_url is None:
            effective_mcp_url = (
                self.DEFAULT_MCP_URL_SANDBOX 
                if environment == "sandbox" 
                else self.DEFAULT_MCP_URL_PRODUCTION
            )
        else:
            effective_mcp_url = mcp_url
        
        self.environment = environment
        self.paypal_token_endpoint = (
            self.PAYPAL_SANDBOX_TOKEN_ENDPOINT 
            if environment == "sandbox" 
            else self.PAYPAL_PRODUCTION_TOKEN_ENDPOINT
        )
        self.paypal_authorization_endpoint = (
            self.PAYPAL_SANDBOX_AUTHORIZATION_ENDPOINT
            if environment == "sandbox"
            else self.PAYPAL_PRODUCTION_AUTHORIZATION_ENDPOINT
        )

        super().__init__(
            mcp_url=effective_mcp_url,
            redirect_uri=redirect_uri,
            core_service_url=core_service_url,
            user_token=user_token,
            provider_name="paypal",
            client_id=client_id,
            client_secret=client_secret,
            tenant_id=tenant_id
        )

        logger.info(
            f"PayPalService initialized with MCP URL: {effective_mcp_url}, "
            f"environment: {environment}, "
            f"token_endpoint: {self.paypal_token_endpoint}"
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

        Overrides parent method to use PayPal-specific token endpoint with Basic Auth
        as per PayPal REST API documentation:
        https://developer.paypal.com/api/rest/#link-getclientidandclientsecret

        Args:
            agent_id: Agent ID
            code: Authorization code from OAuth callback
            state: State parameter from OAuth callback
            code_verifier: Optional PKCE code verifier

        Returns:
            Dictionary with success status, username, and user info
        """
        try:
            # Verify state parameter
            state_data = json.loads(
                base64.urlsafe_b64decode(state.encode()).decode()
            )

            if state_data.get('agent_id') != agent_id:
                return {
                    "success": False,
                    "error": "Invalid state parameter"
                }
            
            mcp_url = state_data.get('mcp_url', self.mcp_url)
            
            # Ensure we have client credentials
            if not self.client_id or not self.client_secret:
                logger.info(
                    f"[paypal] Client credentials missing, loading from integration config"
                )
                stored_credentials = await self._load_credentials(agent_id, mcp_url)
                if stored_credentials and stored_credentials.get("client_id"):
                    self.client_id = stored_credentials.get("client_id")
                    self.client_secret = stored_credentials.get("client_secret")
                    if not self.client_secret:
                        return {
                            "success": False,
                            "error": "PayPal client_secret not found. Please configure PAYPAL_OAUTH_CLIENT_SECRET."
                        }
                else:
                    return {
                        "success": False,
                        "error": "Client credentials not found. Please initiate authorization flow first."
                    }

            # Retrieve code_verifier if PKCE was used
            if not code_verifier:
                code_verifier = await self._load_pkce_verifier(agent_id, state)

            # Exchange authorization code for access token using PayPal REST API format
            # PayPal requires Basic Auth (client_id:client_secret in Base64) per documentation
            # Normalize redirect_uri to match what was sent in authorization URL
            normalized_redirect_uri = self.redirect_uri.rstrip('/')
            
            token_data = {
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": normalized_redirect_uri
            }
            
            logger.info(
                f"[paypal] Token exchange request details: "
                f"client_id={self.client_id[:20]}... (length: {len(self.client_id)}), "
                f"redirect_uri={normalized_redirect_uri}, "
                f"environment={self.environment}, "
                f"token_endpoint={self.paypal_token_endpoint}"
            )

            # Add code_verifier if PKCE was used
            if code_verifier:
                token_data["code_verifier"] = code_verifier
                logger.info("[paypal] Including code_verifier for PKCE token exchange")

            # Create Basic Auth header: Base64(client_id:client_secret)
            credentials = f"{self.client_id}:{self.client_secret}"
            basic_auth = base64.b64encode(credentials.encode()).decode()

            logger.info(
                f"[paypal] Exchanging authorization code for token at {self.paypal_token_endpoint}. "
                f"Using Basic Auth (per PayPal REST API documentation), "
                f"PKCE: {bool(code_verifier)}, "
                f"environment: {self.environment}"
            )

            async with httpx.AsyncClient() as client:
                token_response = await client.post(
                    self.paypal_token_endpoint,
                    data=token_data,
                    headers={
                        "Authorization": f"Basic {basic_auth}",
                        "Content-Type": "application/x-www-form-urlencoded",
                        "Accept": "application/json"
                    },
                    timeout=30.0
                )
                
                logger.info(
                    f"[paypal] Token exchange response: status={token_response.status_code}, "
                    f"response_length={len(token_response.text) if token_response.text else 0}"
                )
                
                if token_response.status_code != 200:
                    error_text = token_response.text
                    logger.error(
                        f"[paypal] Token exchange failed: status={token_response.status_code}, "
                        f"response={error_text[:500]}"
                    )
                    token_response.raise_for_status()
                
                token_result = token_response.json()
                logger.info(
                    f"[paypal] Token exchange successful, response keys: {list(token_result.keys())}"
                )

                access_token = token_result.get("access_token")
                if not access_token:
                    logger.error(f"[paypal] No access_token in response: {token_result}")
                    return {
                        "success": False,
                        "error": "No access token received from PayPal"
                    }

                # Check for non-standard token formats
                if access_token.startswith("login:"):
                    logger.error(
                        f"[paypal] Received non-standard 'login:' format token. "
                        f"This may indicate incorrect configuration or PayPal MCP beta mode."
                    )

                refresh_token = token_result.get("refresh_token")
                expires_in = token_result.get("expires_in")

                logger.info(
                    f"[paypal] Successfully obtained access token "
                    f"(length: {len(access_token)}, "
                    f"has_refresh_token: {bool(refresh_token)}, "
                    f"expires_in: {expires_in})"
                )

                # Clean up PKCE verifier
                await self._delete_pkce_verifier(agent_id, state)

                # Get user information from PayPal
                user_data = {}
                username = None
                email = None

                try:
                    # Determine API base URL based on environment
                    api_base_url = (
                        "https://api-m.sandbox.paypal.com"
                        if self.environment == "sandbox"
                        else "https://api-m.paypal.com"
                    )
                    
                    async with httpx.AsyncClient() as client:
                        user_response = await client.get(
                            f"{api_base_url}/v1/identity/oauth2/userinfo",
                            params={"schema": "paypalv1.1"},
                            headers={
                                "Authorization": f"Bearer {access_token}",
                                "Content-Type": "application/json"
                            },
                            timeout=30.0
                        )
                        user_response.raise_for_status()
                        user_data = user_response.json()

                        username = user_data.get("name") or user_data.get("user_id")
                        email = user_data.get("emails", [{}])[0].get("value") if user_data.get("emails") else None
                        logger.info(f"[paypal] Retrieved user info: username={username}, email={email}")
                except Exception as e:
                    logger.warning(f"[paypal] Could not fetch PayPal user info: {e}")
                    # Don't fail the authorization if user info fetch fails

                # Store credentials
                await self._store_credentials(
                    db=db,
                    agent_id=agent_id,
                    mcp_url=mcp_url,
                    access_token=access_token,
                    username=username,
                    email=email,
                    user_data=user_data,
                    oauth_metadata=self._oauth_metadata or {},
                    refresh_token=refresh_token,
                    expires_in=expires_in
                )

                return {
                    "success": True,
                    "username": username,
                    "email": email,
                    "user_data": user_data,
                    "mcp_url": mcp_url
                }

        except httpx.HTTPStatusError as e:
            error_text = e.response.text if hasattr(e.response, 'text') else str(e)
            logger.error(
                f"[paypal] HTTP error completing authorization: status={e.response.status_code}, "
                f"error={error_text[:500]}"
            )
            return {
                "success": False,
                "error": f"HTTP error: {e.response.status_code} - {error_text[:200]}"
            }
        except Exception as e:
            logger.error(f"[paypal] Error completing authorization: {e}", exc_info=True)
            return {
                "success": False,
                "error": str(e)
            }

    async def generate_authorization_url(
        self,
        agent_id: str,
        scopes: Optional[list] = None,
    ) -> str:
        """
        Generate OAuth 2.0 authorization URL for PayPal MCP.

        Uses PayPal's standard OAuth authorization endpoint instead of the MCP server endpoint,
        as per PayPal OAuth documentation:
        https://developer.paypal.com/api/rest/#link-getclientidandclientsecret

        Args:
            agent_id: Agent ID
            scopes: Optional list of scopes to request (defaults to discovering from MCP server or empty)

        Returns:
            Authorization URL for user to visit
        """
        # Ensure client_id is configured (fast path - already set in __init__)
        if not self.client_id:
            stored_credentials = await self._load_credentials(agent_id, self.mcp_url)
            if stored_credentials and stored_credentials.get("client_id"):
                self.client_id = stored_credentials.get("client_id")
                self.client_secret = stored_credentials.get("client_secret")
            else:
                raise Exception(
                    "PayPal client_id not configured. Please configure PAYPAL_OAUTH_CLIENT_ID "
                    "in the Super Admin settings."
                )

        # PayPal doesn't require scopes parameter - will use app default scopes
        # Don't send scope parameter in authorization URL
        scopes = []

        # Generate PKCE challenge (RFC 7636) - fast operation
        code_verifier, code_challenge = self._generate_pkce_challenge()

        # Create state parameter with account and agent IDs
        state_data = {
            "agent_id": agent_id,
            "mcp_url": self.mcp_url,
            "timestamp": datetime.utcnow().isoformat()
        }
        state = base64.urlsafe_b64encode(
            json.dumps(state_data).encode()
        ).decode()

        # Store code_verifier in memory (fast, always available)
        self._pkce_verifiers[state] = code_verifier
        
        # Store code_verifier in storage (async, non-blocking - fire and forget for performance)
        # The callback can load from memory first, then fallback to storage if needed
        # This improves response time significantly by not waiting for HTTP call
        try:
            # Create background task without awaiting - improves response time by ~100-500ms
            import asyncio
            loop = asyncio.get_event_loop()
            if loop.is_running():
                # If loop is running, create task
                asyncio.create_task(
                    self._store_pkce_verifier(agent_id, state, code_verifier)
                )
            else:
                # If no loop running, await (shouldn't happen in async context)
                await self._store_pkce_verifier(agent_id, state, code_verifier)
        except Exception as e:
            # If background task fails, log but don't block - memory storage is sufficient
            logger.debug(f"[paypal] Background PKCE storage failed (non-critical, using memory): {e}")

        # Normalize redirect_uri (remove trailing slash if present, as PayPal is strict about this)
        normalized_redirect_uri = self.redirect_uri.rstrip('/')
        
        # Build URL efficiently - PayPal doesn't require scope parameter
        authorization_url = (
            f"{self.paypal_authorization_endpoint}"
            f"?client_id={quote(str(self.client_id))}"
            f"&redirect_uri={quote(normalized_redirect_uri)}"
            f"&state={quote(state)}"
            f"&response_type=code"
        )
        
        # Add PKCE parameters (PayPal supports PKCE)
        authorization_url += f"&code_challenge={code_challenge}&code_challenge_method=S256"
        
        # Detailed log for debugging PayPal OAuth issues
        logger.info(
            f"[paypal] Generated authorization URL: "
            f"endpoint={self.paypal_authorization_endpoint.split('?')[0]}, "
            f"env={self.environment}, "
            f"client_id={self.client_id[:20]}... (full length: {len(self.client_id)}), "
            f"redirect_uri={normalized_redirect_uri}, "
            f"no_scope_parameter=True (using app default scopes), "
            f"has_pkce=True"
        )
        logger.debug(
            f"[paypal] Full authorization URL (for debugging): {authorization_url}"
        )
        
        return authorization_url
