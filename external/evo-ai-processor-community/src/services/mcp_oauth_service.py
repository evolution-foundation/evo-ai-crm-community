"""
MCP OAuth Discovery and Authorization Service.

This service implements the MCP OAuth Protected Resource discovery pattern:
1. Discover OAuth requirements by calling the MCP endpoint (returns 401)
2. Get OAuth metadata from .well-known/oauth-protected-resource endpoint
3. Discover Authorization Server metadata (RFC 8414)
4. Perform OAuth flow with PKCE (RFC 7636)
5. Store tokens for use in MCP server headers

This pattern is standard for MCP servers that require OAuth authentication.
"""

import json
import logging
import base64
import hashlib
import secrets
import re
from typing import Optional, Dict, Any, List
from datetime import datetime
from urllib.parse import urlunsplit, urlsplit, quote

import httpx

logger = logging.getLogger(__name__)


class MCPOAuthService:
    """Service for MCP OAuth discovery and authorization."""

    def __init__(
        self,
        mcp_url: str,
        redirect_uri: str,
        core_service_url: str,
        user_token: str,
        provider_name: str,
        client_id: Optional[str] = None,
        client_secret: Optional[str] = None,
        tenant_id: Optional[str] = None
    ):
        """
        Initialize MCP OAuth service.

        Args:
            mcp_url: Base URL of the MCP server (e.g., https://api.githubcopilot.com/mcp/)
            redirect_uri: OAuth redirect URI
            core_service_url: Base URL for evo-ai-core-service API
            user_token: User authentication token for API calls
            provider_name: Provider name for integration storage (e.g., "notion", "github")
            client_id: OAuth client ID (optional, can be obtained via dynamic registration)
            client_secret: OAuth client secret (optional, can be obtained via dynamic registration)
            tenant_id: Tenant id to forward to core-service (enterprise). When present,
                sent as X-Evo-Tenant-Id so the tenant middleware resolves the correct
                tenant on internal calls (integration read/store). None under
                community/standalone → header omitted, no-op.
        """
        self.mcp_url = mcp_url.rstrip('/')
        self.provider_name = provider_name
        self.client_id = client_id
        self.client_secret = client_secret
        self.redirect_uri = redirect_uri
        self.core_service_url = core_service_url.rstrip('/')
        self.user_token = user_token
        self.tenant_id = tenant_id
        # The browser reaches core-service through the CRM, which supplies
        # X-Evo-Tenant-Id; the processor's internal calls must carry the same
        # header or the enterprise tenant middleware rejects them (403 forbidden,
        # fail-closed on empty tenant). Attach it only when a tenant is bound.
        client_headers = {"Authorization": f"Bearer {user_token}"}
        if tenant_id:
            client_headers["X-Evo-Tenant-Id"] = tenant_id
        self.http_client = httpx.AsyncClient(
            headers=client_headers,
            timeout=30.0
        )

        # Cache for OAuth metadata
        self._oauth_metadata: Optional[Dict[str, Any]] = None
        self._authorization_server_metadata: Optional[Dict[str, Any]] = None
        self._token_endpoint_auth_method: Optional[str] = None

        # PKCE state storage (code_verifier per state)
        self._pkce_verifiers: Dict[str, str] = {}

    async def close(self) -> None:
        """Close HTTP client."""
        await self.http_client.aclose()

    async def __aenter__(self):
        """Async context manager entry."""
        return self

    async def __aexit__(self, exc_type, exc_val, exc_tb):
        """Async context manager exit - closes HTTP client."""
        await self.close()

    async def discover_oauth_requirements(self) -> Dict[str, Any]:
        """
        Discover OAuth requirements from MCP server.

        Follows the MCP OAuth Protected Resource discovery pattern:
        1. Call MCP endpoint (expects 401 with www-authenticate header)
        2. Extract resource metadata URL from www-authenticate header
        3. Call .well-known/oauth-protected-resource endpoint
        4. Return OAuth metadata (authorization_servers, scopes_supported, etc.)

        Returns:
            Dictionary with OAuth metadata:
            {
                "resource_name": str,
                "resource": str,
                "authorization_servers": List[str],
                "scopes_supported": List[str],
                ...
            }
        """
        try:
            # Step 1: Call MCP endpoint to get 401 with www-authenticate header
            logger.info(f"Discovering OAuth requirements for MCP: {self.mcp_url}")
            
            async with httpx.AsyncClient(follow_redirects=True, timeout=30.0) as client:
                response = await client.get(self.mcp_url)
                
                # Expect 401 Unauthorized
                if response.status_code != 401:
                    logger.warning(
                        f"MCP endpoint returned {response.status_code} instead of 401. "
                        f"Response: {response.text[:200]}"
                    )
                
                # Extract www-authenticate header
                www_authenticate = response.headers.get("www-authenticate", "")
                logger.debug(f"www-authenticate header: {www_authenticate}")
                
                # Extract resource_metadata URL from www-authenticate header
                # Format: Bearer error="invalid_request", error_description="...", resource_metadata="https://..."
                resource_metadata_match = re.search(
                    r'resource_metadata="([^"]+)"',
                    www_authenticate
                )

                # Step 2: Call .well-known/oauth-protected-resource endpoint
                # Try both standard path and /mcp suffix (e.g., Supabase uses /mcp suffix)
                should_try_authorization_server = False
                oauth_metadata = None
                
                if not resource_metadata_match:
                    # Fallback: construct well-known URLs from MCP URL
                    # Try both standard path and /mcp suffix
                    parsed = urlsplit(self.mcp_url)
                    discovery_paths = [
                        "/.well-known/oauth-protected-resource",
                        "/.well-known/oauth-protected-resource/mcp"
                    ]
                    
                    for discovery_path in discovery_paths:
                        well_known_url = urlunsplit((
                            parsed.scheme,
                            parsed.netloc,
                            discovery_path,
                            "",  # query
                            ""   # fragment
                        ))
                        
                        logger.info(f"Trying OAuth discovery path: {discovery_path} ({well_known_url})")
                        try:
                            metadata_response = await client.get(well_known_url)
                            metadata_response.raise_for_status()

                            # Check if response is JSON (not HTML)
                            content_type = metadata_response.headers.get("content-type", "")
                            response_text = metadata_response.text.strip()
                            if "text/html" in content_type or response_text.startswith("<!DOCTYPE") or response_text.startswith("<html"):
                                # Got HTML instead of JSON - try next path
                                logger.warning(f"oauth-protected-resource returned HTML instead of JSON (content-type: {content_type}), trying next path")
                                continue
                            else:
                                oauth_metadata = metadata_response.json()
                                logger.info(
                                    f"OAuth metadata discovered via {discovery_path}: "
                                    f"authorization_servers={oauth_metadata.get('authorization_servers')}, "
                                    f"scopes_supported={len(oauth_metadata.get('scopes_supported', []))} scopes"
                                )

                                # Cache metadata
                                self._oauth_metadata = oauth_metadata

                                return oauth_metadata
                        except httpx.HTTPStatusError as e:
                            if e.response.status_code == 404:
                                # Try next path
                                logger.debug(f"404 for {discovery_path}, trying next path")
                                continue
                            else:
                                # Non-404 error - try next path but don't fail yet
                                logger.warning(f"HTTP {e.response.status_code} for {discovery_path}, trying next path")
                                continue
                        except Exception as e:
                            logger.debug(f"Error fetching {discovery_path}: {e}, trying next path")
                            continue
                    
                    # If we get here, both paths failed - try oauth-authorization-server fallback
                    should_try_authorization_server = True
                else:
                    # Use the well_known_url from resource_metadata header
                    well_known_url = resource_metadata_match.group(1)
                    logger.info(f"Found resource_metadata URL: {well_known_url}")
                    
                    logger.info(f"Fetching OAuth metadata from: {well_known_url}")
                    try:
                        metadata_response = await client.get(well_known_url)
                        metadata_response.raise_for_status()

                        # Check if response is JSON (not HTML)
                        content_type = metadata_response.headers.get("content-type", "")
                        response_text = metadata_response.text.strip()
                        if "text/html" in content_type or response_text.startswith("<!DOCTYPE") or response_text.startswith("<html"):
                            # Got HTML instead of JSON - try oauth-authorization-server fallback
                            logger.warning(f"oauth-protected-resource returned HTML instead of JSON (content-type: {content_type}), trying oauth-authorization-server")
                            should_try_authorization_server = True
                        else:
                            oauth_metadata = metadata_response.json()
                            logger.info(
                                f"OAuth metadata discovered: "
                                f"authorization_servers={oauth_metadata.get('authorization_servers')}, "
                                f"scopes_supported={len(oauth_metadata.get('scopes_supported', []))} scopes"
                            )

                            # Cache metadata
                            self._oauth_metadata = oauth_metadata

                            return oauth_metadata
                    except httpx.HTTPStatusError as e:
                        if e.response.status_code == 404:
                            should_try_authorization_server = True
                        else:
                            raise

                if should_try_authorization_server:
                    # PayPal, Linear and some other providers use oauth-authorization-server directly
                    # Try RFC 8414 discovery instead
                    logger.info(f"Trying oauth-authorization-server fallback")
                    parsed = urlsplit(self.mcp_url)
                    auth_server_url = urlunsplit((
                        parsed.scheme,
                        parsed.netloc,
                        "/.well-known/oauth-authorization-server",
                        "",  # query
                        ""   # fragment
                    ))

                    try:
                        auth_metadata_response = await client.get(auth_server_url)
                        auth_metadata_response.raise_for_status()
                        auth_metadata = auth_metadata_response.json()

                        # Convert authorization server metadata to oauth-protected-resource format
                        # Extract issuer/base URL
                        issuer = auth_metadata.get("issuer", self.mcp_url)
                        oauth_metadata = {
                            "resource": issuer,
                            "authorization_servers": [issuer],
                            "scopes_supported": auth_metadata.get("scopes_supported", []),
                            "authorization_server_metadata": auth_metadata
                        }

                        # Cache both metadata formats
                        self._oauth_metadata = oauth_metadata
                        self._authorization_server_metadata = auth_metadata

                        logger.info(
                            f"OAuth metadata discovered via oauth-authorization-server: "
                            f"issuer={issuer}, "
                            f"authorization_endpoint={auth_metadata.get('authorization_endpoint')}, "
                            f"scopes_supported={len(oauth_metadata.get('scopes_supported', []))} scopes"
                        )

                        return oauth_metadata
                    except Exception as fallback_error:
                        logger.error(f"Both oauth-protected-resource and oauth-authorization-server failed: {fallback_error}")
                        raise Exception(f"Failed to discover OAuth metadata: {fallback_error}")
                
        except httpx.HTTPStatusError as e:
            logger.error(f"HTTP error discovering OAuth requirements: {e}")
            raise Exception(f"Failed to discover OAuth requirements: {e.response.status_code} - {e.response.text}")
        except Exception as e:
            logger.error(f"Error discovering OAuth requirements: {e}")
            raise

    async def discover_authorization_server(
        self,
        authorization_server_url: str
    ) -> Dict[str, Any]:
        """
        Discover Authorization Server metadata (RFC 8414).

        Tries multiple discovery methods in order:
        1. GET directly to authorization_server_url (may return metadata)
        2. GET to /.well-known/oauth-authorization-server (RFC 8414)
        3. Fallback: construct endpoints based on authorization_server_url

        Args:
            authorization_server_url: Authorization server URL from resource metadata

        Returns:
            Dictionary with authorization server metadata:
            {
                "issuer": str,
                "authorization_endpoint": str,
                "token_endpoint": str,
                "registration_endpoint": str,
                "response_types_supported": List[str],
                "grant_types_supported": List[str],
                "code_challenge_methods_supported": List[str],
                "scopes_supported": List[str]
            }
        """
        try:
            async with httpx.AsyncClient(timeout=30.0) as client:
                # Method 1: Try GET directly to authorization_server_url
                logger.info(f"Trying direct GET to authorization server: {authorization_server_url}")
                try:
                    response = await client.get(authorization_server_url)
                    if response.status_code == 200:
                        # Check if response looks like metadata (has authorization_endpoint)
                        data = response.json()
                        if "authorization_endpoint" in data:
                            logger.info("Authorization server metadata found via direct GET")
                            self._authorization_server_metadata = data
                            
                            # Update token_endpoint_auth_method based on discovered metadata
                            auth_methods = data.get('token_endpoint_auth_methods_supported', [])
                            if "client_secret_post" in auth_methods:
                                self._token_endpoint_auth_method = "client_secret_post"
                            elif "none" in auth_methods:
                                self._token_endpoint_auth_method = "none"
                            elif auth_methods:
                                self._token_endpoint_auth_method = auth_methods[0]
                            
                            logger.info(
                                f"[{self.provider_name}] Set token_endpoint_auth_method from discovery: {self._token_endpoint_auth_method}"
                            )
                            
                            return data
                except Exception as e:
                    logger.debug(f"Direct GET failed: {e}")

                # Method 2: Try /.well-known/oauth-authorization-server (RFC 8414)
                # When path starts with /, it replaces entire path keeping only origin
                parsed = urlsplit(authorization_server_url)
                well_known_url = urlunsplit((
                    parsed.scheme,
                    parsed.netloc,
                    "/.well-known/oauth-authorization-server",
                    "",  # query
                    ""   # fragment
                ))

                logger.info(f"Trying RFC 8414 discovery: {well_known_url}")
                try:
                    response = await client.get(well_known_url)
                    if response.status_code == 200:
                        metadata = response.json()
                        logger.info(
                            f"Authorization server metadata discovered via RFC 8414: "
                            f"issuer={metadata.get('issuer')}, "
                            f"authorization_endpoint={metadata.get('authorization_endpoint')}, "
                            f"token_endpoint={metadata.get('token_endpoint')}, "
                            f"PKCE support={'S256' in metadata.get('code_challenge_methods_supported', [])}, "
                            f"auth_methods={metadata.get('token_endpoint_auth_methods_supported', [])}"
                        )
                        self._authorization_server_metadata = metadata
                        
                        # Update token_endpoint_auth_method based on discovered metadata
                        auth_methods = metadata.get('token_endpoint_auth_methods_supported', [])
                        if "client_secret_post" in auth_methods:
                            self._token_endpoint_auth_method = "client_secret_post"
                        elif "none" in auth_methods:
                            self._token_endpoint_auth_method = "none"
                        elif auth_methods:
                            # Use first supported method
                            self._token_endpoint_auth_method = auth_methods[0]
                        
                        logger.info(
                            f"[{self.provider_name}] Set token_endpoint_auth_method from discovery: {self._token_endpoint_auth_method}"
                        )
                        
                        return metadata
                except Exception as e:
                    logger.debug(f"RFC 8414 discovery failed: {e}")

                # Method 3: Fallback - construct endpoints based on authorization_server_url
                logger.info(f"Discovery methods failed, using fallback endpoint construction")
                base_url = authorization_server_url.rstrip('/')

                metadata = {
                    "issuer": authorization_server_url,
                    "authorization_endpoint": f"{base_url}/authorize",
                    "token_endpoint": f"{base_url}/access_token",
                    "code_challenge_methods_supported": [],  # Assume PKCE not supported
                    "response_types_supported": ["code"],
                    "grant_types_supported": ["authorization_code"]
                }

                logger.info(
                    f"Using fallback endpoints: "
                    f"authorization_endpoint={metadata['authorization_endpoint']}, "
                    f"token_endpoint={metadata['token_endpoint']}"
                )

                self._authorization_server_metadata = metadata
                return metadata

        except Exception as e:
            logger.error(f"Error discovering authorization server: {e}")
            raise

    async def register_client(
        self,
        registration_endpoint: str,
        client_name: str = "EvoAI MCP Client",
        redirect_uris: Optional[List[str]] = None
    ) -> Dict[str, Any]:
        """
        Register OAuth client dynamically (RFC 7591).

        Args:
            registration_endpoint: Client registration endpoint from authorization server metadata
            client_name: Name to display in authorization screen
            redirect_uris: List of allowed redirect URIs (defaults to self.redirect_uri)

        Returns:
            Dictionary with client registration information:
            {
                "client_id": str,
                "client_secret": str (optional),
                "client_id_issued_at": int,
                "client_secret_expires_at": int,
                "redirect_uris": List[str],
                "grant_types": List[str],
                "response_types": List[str],
                "token_endpoint_auth_method": str
            }
        """
        try:
            logger.info(f"Registering OAuth client at: {registration_endpoint}")

            # Use provided redirect_uris or default to configured redirect_uri
            if redirect_uris is None:
                redirect_uris = [self.redirect_uri]

            # Prepare registration request (RFC 7591)
            # Use discovered auth_method if available, otherwise default to "none" for public clients
            # Some providers (like Supabase) may require client_secret even with dynamic registration
            discovered_auth_method = getattr(self, '_token_endpoint_auth_method', None)
            # For Supabase, try to use "client_secret_post" if available, otherwise use discovered method
            # Supabase requires client_secret in token exchange even with dynamic registration
            if self.provider_name == "supabase":
                if discovered_auth_method and discovered_auth_method != "none":
                    auth_method_for_registration = discovered_auth_method
                elif "client_secret_post" in self._authorization_server_metadata.get("token_endpoint_auth_methods_supported", []):
                    auth_method_for_registration = "client_secret_post"
                    logger.info(
                        f"[supabase] Using client_secret_post for dynamic registration "
                        f"(Supabase requires client_secret in token exchange)"
                    )
                else:
                    auth_method_for_registration = "none"
            else:
                # If we have a discovered auth_method that's not "none", use it
                # Otherwise, default to "none" (public client)
                auth_method_for_registration = discovered_auth_method if discovered_auth_method and discovered_auth_method != "none" else "none"
            
            registration_request = {
                "client_name": client_name,
                "redirect_uris": redirect_uris,
                "grant_types": ["authorization_code", "refresh_token"],
                "response_types": ["code"],
                "token_endpoint_auth_method": auth_method_for_registration
            }
            
            logger.info(
                f"[{self.provider_name}] Dynamic registration request: "
                f"auth_method={auth_method_for_registration} "
                f"(discovered={discovered_auth_method}, default=none)"
            )

            async with httpx.AsyncClient(timeout=30.0) as client:
                response = await client.post(
                    registration_endpoint,
                    json=registration_request,
                    headers={
                        "Content-Type": "application/json",
                        "Accept": "application/json"
                    }
                )
                response.raise_for_status()

                client_info = response.json()

                # Log full registration response for PayPal (to debug login: token issue)
                if self.provider_name == "paypal":
                    logger.warning(
                        f"[paypal] Full client registration response from PayPal: {client_info}"
                    )
                    # Check if PayPal returned login: credentials during registration
                    if client_info.get('client_id', '').startswith('login:'):
                        logger.error(
                            f"[paypal] PayPal MCP returned 'login:' format client_id during registration. "
                            f"This is not a standard OAuth client_id. "
                            f"Full response: {client_info}"
                        )

                logger.info(
                    f"[{self.provider_name}] Client registered successfully: "
                    f"client_id={client_info.get('client_id')}, "
                    f"client_secret={'present' if client_info.get('client_secret') else 'None'}, "
                    f"auth_method={client_info.get('token_endpoint_auth_method')}"
                )
                if client_info.get('client_secret'):
                    logger.info(
                        f"[{self.provider_name}] Dynamic registration returned client_secret "
                        f"(length: {len(client_info.get('client_secret'))})"
                    )
                else:
                    logger.info(
                        f"[{self.provider_name}] Dynamic registration did not return client_secret "
                        f"(public client with auth_method={client_info.get('token_endpoint_auth_method')})"
                    )

                return client_info

        except httpx.HTTPStatusError as e:
            logger.error(f"HTTP error during client registration: {e}")
            error_detail = e.response.text

            # Check for specific error cases
            if e.response.status_code == 400 and "redirect_uri" in error_detail.lower():
                raise Exception(
                    f"Failed to register client: The authorization server does not allow the redirect_uri '{self.redirect_uri}'. "
                    f"Please manually configure client_id and client_secret in global config, or use a different redirect_uri. "
                    f"Error details: {error_detail}"
                )

            raise Exception(
                f"Failed to register client: {e.response.status_code} - {error_detail}"
            )
        except Exception as e:
            logger.error(f"Error during client registration: {e}")
            raise

    def _generate_pkce_challenge(self) -> tuple[str, str]:
        """
        Generate PKCE code verifier and challenge (RFC 7636).

        Returns:
            Tuple of (code_verifier, code_challenge)
        """
        # Generate code_verifier: random 43-128 character string
        code_verifier = base64.urlsafe_b64encode(
            secrets.token_bytes(32)
        ).decode('utf-8').rstrip('=')

        # Generate code_challenge: BASE64URL(SHA256(code_verifier))
        code_challenge = base64.urlsafe_b64encode(
            hashlib.sha256(code_verifier.encode('utf-8')).digest()
        ).decode('utf-8').rstrip('=')

        return code_verifier, code_challenge

    async def generate_authorization_url(
        self,
        agent_id: str,
        scopes: Optional[List[str]] = None,
    ) -> str:
        """
        Generate OAuth 2.0 authorization URL with PKCE support (RFC 7636).

        Args:
            agent_id: Agent ID
            scopes: Optional list of scopes to request. If not provided, uses all scopes_supported from discovery.

        Returns:
            Authorization URL for user to visit
        """
        # Use cached metadata or discover if not available
        if not self._oauth_metadata:
            raise Exception("OAuth metadata not discovered. Call discover_oauth_requirements() first.")

        # Get authorization server (usually first one)
        authorization_servers = self._oauth_metadata.get("authorization_servers", [])
        if not authorization_servers:
            raise Exception("No authorization servers found in OAuth metadata")

        authorization_server = authorization_servers[0]
        logger.info(f"Using authorization server: {authorization_server}")

        # Discover authorization server metadata (tries multiple methods with fallback)
        if not self._authorization_server_metadata:
            await self.discover_authorization_server(authorization_server)

        # Check if we need to register the client dynamically (RFC 7591)
        # This happens when client_id is not configured (empty string, None, or whitespace)
        client_id_empty = not self.client_id or not self.client_id.strip()
        
        if client_id_empty:
            logger.info("No client_id configured, attempting dynamic client registration")

            # Try to load stored client credentials from integration config first
            # Note: db is not available in generate_authorization_url, so this will use HTTP
            stored_credentials = await self._load_credentials(agent_id, self.mcp_url, db=None)

            if stored_credentials and stored_credentials.get("client_id") and stored_credentials.get("client_id").strip():
                # Use stored client credentials from previous registration
                self.client_id = stored_credentials.get("client_id")
                self.client_secret = stored_credentials.get("client_secret")
                self._token_endpoint_auth_method = stored_credentials.get(
                    "token_endpoint_auth_method",
                    "none"
                )
                logger.info(
                    f"Loaded stored client credentials from integration: "
                    f"client_id={self.client_id}, "
                    f"auth_method={self._token_endpoint_auth_method}"
                )
            else:
                # No stored credentials, try dynamic registration
                registration_endpoint = self._authorization_server_metadata.get("registration_endpoint")

                if registration_endpoint:
                    logger.info("Authorization server supports dynamic client registration")

                    try:
                        # Register new client
                        client_info = await self.register_client(registration_endpoint)

                        # Update instance with registered credentials
                        self.client_id = client_info.get("client_id")
                        self.client_secret = client_info.get("client_secret")  # May be None for public clients
                        self._token_endpoint_auth_method = client_info.get("token_endpoint_auth_method", "none")

                        # Store client credentials immediately so callback can find them
                        # Note: db is not available in generate_authorization_url, so this will use HTTP
                        logger.info(
                            f"[{self.provider_name}] Storing dynamically registered client credentials. "
                            f"client_id={self.client_id}, "
                            f"auth_method={self._token_endpoint_auth_method}"
                        )
                        try:
                            await self._store_client_credentials(
                                agent_id,
                                self.mcp_url,
                                token_endpoint_auth_method=self._token_endpoint_auth_method,
                                db=None  # Not available in generate_authorization_url
                            )
                            logger.info(
                                f"[{self.provider_name}] Dynamic registration successful and stored: "
                                f"client_id={self.client_id}, "
                                f"auth_method={self._token_endpoint_auth_method}"
                            )
                        except Exception as store_error:
                            logger.error(
                                f"[{self.provider_name}] Failed to store dynamically registered credentials: {store_error}. "
                                f"This may cause the callback to fail. "
                                f"client_id={self.client_id}",
                                exc_info=True
                            )
                            # Don't raise - the registration was successful, just storage failed
                            # The callback will try to load from HTTP fallback
                    except Exception as reg_error:
                        # If dynamic registration fails (e.g., redirect_uri not allowed),
                        # provide clear error message
                        error_msg = str(reg_error)
                        provider_upper = self.provider_name.upper()
                        if "redirect_uri" in error_msg.lower():
                            raise Exception(
                                f"Dynamic client registration failed: {error_msg}. "
                                f"Please configure {provider_upper}_OAUTH_CLIENT_ID and {provider_upper}_OAUTH_CLIENT_SECRET "
                                f"manually in the Super Admin settings, and ensure the redirect_uri "
                                f"'{self.redirect_uri}' is registered in your {self.provider_name.title()} OAuth app settings."
                            )
                        raise
                else:
                    raise Exception(
                        "No client_id configured and authorization server does not support "
                        f"dynamic client registration (no registration_endpoint found). "
                        f"Please configure {self.provider_name.upper()}_OAUTH_CLIENT_ID and {self.provider_name.upper()}_OAUTH_CLIENT_SECRET "
                        f"in the Super Admin settings."
                    )

        # Get authorization endpoint from metadata
        auth_endpoint = self._authorization_server_metadata.get("authorization_endpoint")
        if not auth_endpoint:
            raise Exception("No authorization_endpoint found in metadata")
        
        # Log authorization endpoint from discovery
        logger.info(
            f"[{self.provider_name}] Using authorization_endpoint from discovery: {auth_endpoint}"
        )

        # Determine scopes to request
        if scopes is None:
            # Use all supported scopes by default
            scopes = self._oauth_metadata.get("scopes_supported", [])

            # Log scopes from discovery
            logger.info(
                f"[{self.provider_name}] Scopes from discovery: {scopes if scopes else '(none - app will use default scopes)'}"
            )

            # PayPal MCP requires specific scopes - if no scopes from discovery, use defaults
            if self.provider_name == "paypal" and not scopes:
                logger.warning(
                    "PayPal MCP discovery did not return scopes_supported. "
                    "Using default PayPal MCP scopes. "
                    "PayPal MCP requires explicit scopes to return valid OAuth tokens."
                )
                # PayPal MCP default scopes (based on PayPal REST API scopes)
                scopes = [
                    "openid",
                    "profile",
                    "email"
                ]
                logger.info(
                    f"[paypal] Using default PayPal MCP scopes: {scopes}"
                )
            
            # HubSpot MCP requires specific scopes - if no scopes from discovery, use defaults
            if self.provider_name == "hubspot" and not scopes:
                logger.warning(
                    "HubSpot MCP discovery did not return scopes_supported. "
                    "Using default HubSpot MCP scopes. "
                    "HubSpot MCP requires explicit scopes to return valid OAuth tokens."
                )
                # HubSpot MCP default scopes (required + optional from user-level-app-hsmeta.json)
                scopes = [
                    "oauth",
                    "crm.objects.contacts.read",
                    "crm.objects.companies.read",
                    "crm.objects.deals.read",
                    "crm.objects.products.read",
                    "crm.objects.orders.read",
                    "crm.objects.line_items.read"
                ]
                logger.info(
                    f"[hubspot] Using default HubSpot MCP scopes: {scopes}"
                )

        logger.info(
            f"[{self.provider_name}] Requesting scopes: {scopes if scopes else '(none - using app default scopes)'}"
        )
        
        if scopes:
            logger.info(
                f"[{self.provider_name}] Will request {len(scopes)} scopes in authorization URL: {', '.join(scopes[:5])}"
                f"{'...' if len(scopes) > 5 else ''}"
            )
        else:
            logger.warning(
                f"[{self.provider_name}] No scopes will be requested. This may cause issues if the app requires explicit scopes."
            )

        # Generate PKCE challenge (RFC 7636)
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

        # Store code_verifier in memory AND in storage for callback
        self._pkce_verifiers[state] = code_verifier

        # Store code_verifier in integration config so callback can retrieve it
        logger.info(
            f"[{self.provider_name}] Storing PKCE verifier before generating authorization URL. "
            f"state_length={len(state)}, code_verifier_length={len(code_verifier)}"
        )
        await self._store_pkce_verifier(agent_id, state, code_verifier, db=None)
        logger.info(
            f"[{self.provider_name}] PKCE verifier stored successfully. "
            f"Will now store client credentials (which should preserve pkce_verifiers)"
        )

        # Check if server supports PKCE
        code_challenge_methods = self._authorization_server_metadata.get("code_challenge_methods_supported", [])
        supports_pkce = "S256" in code_challenge_methods
        
        # For public clients (token_endpoint_auth_method="none"), PKCE is required
        auth_method = getattr(self, '_token_endpoint_auth_method', None) or "none"
        requires_pkce = auth_method == "none"
        
        if requires_pkce and not supports_pkce:
            logger.warning(
                f"Public client requires PKCE, but server metadata doesn't declare support. "
                f"Using PKCE anyway (RFC 7636 requirement for public clients)."
            )
            supports_pkce = True  # Force PKCE for public clients
            
        # Build OAuth authorization URL with PKCE
        scopes_str = ' '.join(scopes) if scopes else ""

        # URL encode parameters
        authorization_url = (
            f"{auth_endpoint}"
            f"?client_id={quote(str(self.client_id))}"
            f"&redirect_uri={quote(self.redirect_uri)}"
            f"&state={quote(state)}"
            f"&response_type=code"
        )
        
        if scopes_str:
            authorization_url += f"&scope={quote(scopes_str)}"
            logger.info(
                f"[{self.provider_name}] Authorization URL includes scope parameter with {len(scopes)} scopes"
            )
        else:
            logger.warning(
                f"[{self.provider_name}] Authorization URL does NOT include scope parameter. "
                f"This may cause issues if the app requires explicit scopes."
            )

        # Add PKCE parameters if supported or required
        if supports_pkce or requires_pkce:
            authorization_url += f"&code_challenge={code_challenge}&code_challenge_method=S256"
            logger.info(
                f"PKCE enabled for authorization request "
                f"(required={requires_pkce}, server_supports={supports_pkce})"
            )
        else:
            logger.warning(f"Authorization server does not support PKCE (S256)")

        # Always store client credentials so callback can find them
        # This is important even if client_id came from global config (not dynamic registration)
        # The callback needs to load credentials from database, not from global config
        # IMPORTANT: This is called AFTER _store_pkce_verifier, so it will preserve pkce_verifiers
        try:
            await self._store_client_credentials(
                agent_id,
                self.mcp_url,
                token_endpoint_auth_method=self._token_endpoint_auth_method,
                db=None  # Not available in generate_authorization_url
            )
            logger.info(
                f"[{self.provider_name}] Stored client credentials for callback. "
                f"client_id={'present' if self.client_id else 'missing'}, "
                f"auth_method={self._token_endpoint_auth_method}"
            )
        except Exception as store_error:
            logger.warning(
                f"[{self.provider_name}] Failed to store client credentials: {store_error}. "
                f"Callback may fail if credentials are not found. "
                f"client_id={'present' if self.client_id else 'missing'}",
                exc_info=True
            )
            # Don't raise - authorization URL was generated successfully
            # The callback will try to load from HTTP fallback or global config

        # Log authorization URL (masked for security)
        url_preview = authorization_url.split('?')[0] + '?...' if '?' in authorization_url else authorization_url
        logger.info(
            f"[{self.provider_name}] Generated authorization URL for MCP: {self.mcp_url}, "
            f"URL preview: {url_preview}, "
            f"has_scopes={bool(scopes_str)}, has_pkce={supports_pkce or requires_pkce}"
        )
        return authorization_url

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

        Args:
            agent_id: Agent ID
            code: Authorization code from OAuth callback
            state: State parameter from OAuth callback
            code_verifier: Optional PKCE code verifier (if not provided, will be loaded from storage)

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
            
            # Get OAuth metadata if not cached
            if not self._oauth_metadata:
                await self.discover_oauth_requirements()

            # Get authorization server
            authorization_servers = self._oauth_metadata.get("authorization_servers", [])
            if not authorization_servers:
                return {
                    "success": False,
                    "error": "No authorization servers found"
                }

            authorization_server = authorization_servers[0]

            # Get authorization server metadata if not cached
            if not self._authorization_server_metadata:
                await self.discover_authorization_server(authorization_server)

            # Get token endpoint from metadata
            token_endpoint = self._authorization_server_metadata.get("token_endpoint")
            if not token_endpoint:
                raise Exception("No token_endpoint found in metadata")
            
            # Use token_endpoint exactly as discovered - no hardcoded corrections
            logger.info(
                f"[{self.provider_name}] Using token_endpoint from discovery: {token_endpoint}"
            )

            # Ensure we have client credentials (may need to load from integration config)
            # For HubSpot and GitHub, always ensure client_secret is available
            # Load client credentials if missing
            auth_method = getattr(self, '_token_endpoint_auth_method', None) or "none"
            # GitHub and HubSpot always require client_secret (private clients)
            # Stripe can use dynamic registration, so it's not in this list
            needs_client_secret = auth_method != "none" or self.provider_name in ["github", "hubspot"]
            
            # For GitHub and HubSpot, preserve client_secret from constructor (from global config)
            # Don't override it with stored credentials which may be from dynamic registration
            # IMPORTANT: Save the original client_secret BEFORE loading from storage
            original_client_secret = self.client_secret if self.provider_name in ["github", "hubspot"] else None
            
            if not self.client_id or (needs_client_secret and not self.client_secret):
                logger.info(
                    f"[{self.provider_name}] Client credentials missing (auth_method={auth_method} from discovery), "
                    f"loading from integration config. "
                    f"client_id={'present' if self.client_id else 'missing'}, "
                    f"client_secret={'present' if self.client_secret else 'missing'}, "
                    f"has_db={db is not None}"
                )
                stored_credentials = await self._load_credentials(agent_id, mcp_url, db=db)
                logger.info(
                    f"[{self.provider_name}] Loaded credentials result: "
                    f"found={stored_credentials is not None}, "
                    f"has_client_id={stored_credentials.get('client_id') if stored_credentials else False}, "
                    f"client_id_preview={stored_credentials.get('client_id', '')[:20] + '...' if stored_credentials and stored_credentials.get('client_id') else 'None'}"
                )
                if stored_credentials and stored_credentials.get("client_id"):
                    if not self.client_id:
                        self.client_id = stored_credentials.get("client_id")
                    # Load client_secret if auth_method requires it or for GitHub/HubSpot
                    # But for GitHub/HubSpot, ALWAYS prefer the one from constructor (global config) if available
                    if needs_client_secret and not self.client_secret:
                        # For GitHub/HubSpot, use constructor client_secret if available, otherwise from storage
                        if self.provider_name in ["github", "hubspot"]:
                            if original_client_secret:
                                self.client_secret = original_client_secret
                                logger.info(
                                    f"[{self.provider_name}] Using client_secret from constructor (global config) "
                                    f"instead of stored credentials"
                                )
                            else:
                                # If not in constructor, try from storage but log warning
                                self.client_secret = stored_credentials.get("client_secret")
                        else:
                            # For other providers (including Stripe, Notion, Supabase), use from storage if available
                            # These providers use dynamic registration, so client_secret comes from registration response
                            stored_client_secret = stored_credentials.get("client_secret")
                            if stored_client_secret:
                                self.client_secret = stored_client_secret
                                logger.info(
                                    f"[{self.provider_name}] Loaded client_secret from stored credentials (dynamic registration). "
                                    f"client_secret length: {len(stored_client_secret) if stored_client_secret else 0}"
                                )
                            elif self.client_secret:
                                # Use client_secret from constructor (global config) if not in storage
                                logger.info(
                                    f"[{self.provider_name}] Using client_secret from constructor (global config) "
                                    f"since not found in stored credentials"
                                )
                            else:
                                logger.warning(
                                    f"[{self.provider_name}] client_secret not found in stored credentials or global config. "
                                    f"This may cause token exchange to fail if auth_method requires it. "
                                    f"auth_method={auth_method}"
                                )
                    elif not needs_client_secret:
                        # Only load client_secret from storage if not needed (for other providers)
                        if not self.client_secret:
                            self.client_secret = stored_credentials.get("client_secret")
                    
                    # Use stored auth_method if available, otherwise keep discovered one
                    stored_auth_method = stored_credentials.get("token_endpoint_auth_method")
                    if stored_auth_method:
                        self._token_endpoint_auth_method = stored_auth_method
                    
                    logger.info(
                        f"[{self.provider_name}] Loaded client credentials from integration: "
                        f"client_id={self.client_id[:10]}..., "
                        f"client_secret={'***' + self.client_secret[-4:] if self.client_secret and len(self.client_secret) > 4 else 'None'}, "
                        f"auth_method={self._token_endpoint_auth_method}"
                    )
                else:
                    return {
                        "success": False,
                        "error": "Client credentials not found. Please initiate authorization flow first."
                    }
            
            # Final check: For GitHub and HubSpot, ensure client_secret is present
            # Stripe can use dynamic registration, so it's not checked here
            if self.provider_name in ["github", "hubspot"] and not self.client_secret:
                logger.error(
                    f"[{self.provider_name}] client_secret is required but missing! "
                    f"client_id={self.client_id}, "
                    f"original_client_secret={'present' if original_client_secret else 'missing'}"
                )
                return {
                    "success": False,
                    "error": f"{self.provider_name.title()} OAuth requires client_secret. "
                             f"Please ensure {self.provider_name.upper()}_OAUTH_CLIENT_SECRET is configured in global config."
                }

            # Retrieve code_verifier from parameter, memory, or storage
            if not code_verifier:
                code_verifier = self._pkce_verifiers.get(state)
                if code_verifier:
                    logger.info(f"[{self.provider_name}] Found code_verifier in memory cache")
            if not code_verifier:
                # Try to load from storage (callback scenario)
                try:
                    code_verifier = await self._load_pkce_verifier(agent_id, state, db=db)
                    if code_verifier:
                        logger.info(f"[{self.provider_name}] Found code_verifier in storage")
                except Exception as load_error:
                    logger.warning(f"[{self.provider_name}] Could not load code_verifier from storage: {load_error}")
                    code_verifier = None
            
            if not code_verifier:
                logger.warning(
                    f"[{self.provider_name}] No code_verifier found for state. "
                    f"This may cause token exchange to fail if PKCE is required. "
                    f"state={state[:50] if state else 'None'}..."
                )
            else:
                logger.info(f"[{self.provider_name}] Using code_verifier (length: {len(code_verifier)})")

            # Initialize token variables
            access_token = None
            refresh_token = None
            expires_in = None

            try:
                # Exchange authorization code for access token
                token_data = {
                    "client_id": self.client_id,
                    "code": code,
                    "redirect_uri": self.redirect_uri,
                    "grant_type": "authorization_code"
                }

                # Include client_secret based on discovered auth_method
                auth_method = getattr(self, '_token_endpoint_auth_method', None) or "none"
                
                # For HubSpot, always require client_secret (per HubSpot OAuth documentation)
                if self.provider_name == "hubspot":
                    if not self.client_secret:
                        logger.error(
                            f"[hubspot] HubSpot requires client_secret for token exchange! "
                            f"client_id={self.client_id}, client_secret={'present' if self.client_secret else 'MISSING'}"
                        )
                        raise Exception(
                            "HubSpot OAuth requires client_secret for token exchange. "
                            "Please ensure HUBSPOT_OAUTH_CLIENT_SECRET is configured in global config."
                        )
                    token_data["client_secret"] = self.client_secret
                    logger.info(
                        f"[hubspot] Including client_secret for HubSpot token exchange "
                        f"(client_secret length: {len(self.client_secret) if self.client_secret else 0})"
                    )
                # For GitHub, always require client_secret (GitHub OAuth requires client_secret for private clients)
                elif self.provider_name == "github":
                    if not self.client_secret:
                        logger.error(
                            f"[github] GitHub requires client_secret for token exchange! "
                            f"client_id={self.client_id}, client_secret={'present' if self.client_secret else 'MISSING'}"
                        )
                        raise Exception(
                            "GitHub OAuth requires client_secret for token exchange. "
                            "Please ensure GITHUB_OAUTH_CLIENT_SECRET is configured in global config."
                        )
                    token_data["client_secret"] = self.client_secret
                    logger.info(
                        f"[github] Including client_secret for GitHub token exchange "
                        f"(client_secret length: {len(self.client_secret) if self.client_secret else 0})"
                    )
                # For Supabase, always include client_secret if available (Supabase requires it even with dynamic registration)
                elif self.provider_name == "supabase" and self.client_secret:
                    token_data["client_secret"] = self.client_secret
                    logger.info(
                        f"[supabase] Including client_secret for Supabase token exchange "
                        f"(client_secret length: {len(self.client_secret) if self.client_secret else 0})"
                    )
                elif auth_method != "none" and self.client_secret:
                    token_data["client_secret"] = self.client_secret
                    logger.info(
                        f"[{self.provider_name}] Including client_secret for auth method: {auth_method} "
                        f"(discovered from metadata)"
                    )
                elif auth_method != "none" and not self.client_secret:
                    # For providers that use dynamic registration (like Supabase, Notion, Stripe),
                    # client_secret should come from the registration response
                    # If it's missing, it means the registration didn't return one (public client)
                    # But the auth_method says it's required, so this is an error
                    logger.error(
                        f"[{self.provider_name}] Auth method '{auth_method}' requires client_secret but it's missing! "
                        f"client_id: {self.client_id}, "
                        f"provider uses dynamic registration: {self.provider_name in ['supabase', 'notion', 'stripe', 'linear', 'monday', 'atlassian', 'asana', 'canva']}"
                    )
                    # For dynamic registration providers, provide a more helpful error message
                    if self.provider_name in ["supabase", "notion", "stripe", "linear", "monday", "atlassian", "asana", "canva"]:
                        raise Exception(
                            f"Auth method '{auth_method}' requires client_secret but it's missing. "
                            f"This may indicate that dynamic client registration did not return a client_secret, "
                            f"or the client_secret was not stored correctly. "
                            f"Please try re-initiating the authorization flow, or configure "
                            f"{self.provider_name.upper()}_OAUTH_CLIENT_ID and {self.provider_name.upper()}_OAUTH_CLIENT_SECRET "
                            f"manually in global config."
                        )
                    else:
                        raise Exception(
                            f"Auth method '{auth_method}' requires client_secret but it's missing. "
                            f"Please ensure {self.provider_name.upper()}_OAUTH_CLIENT_SECRET is configured."
                        )
                else:
                    # For Supabase, even if auth_method is "none", include client_secret if available
                    # Supabase requires client_secret in token exchange even with dynamic registration
                    if self.provider_name == "supabase" and self.client_secret:
                        token_data["client_secret"] = self.client_secret
                        logger.info(
                            f"[supabase] Including client_secret for Supabase token exchange "
                            f"(auth_method={auth_method}, client_secret length: {len(self.client_secret)})"
                        )
                    else:
                        logger.info(
                            f"[{self.provider_name}] Public client (auth_method={auth_method} from discovery), "
                            f"not including client_secret"
                        )

                # Add code_verifier if PKCE was used (required for public clients)
                if code_verifier:
                    token_data["code_verifier"] = code_verifier
                    logger.info("Including code_verifier for PKCE token exchange")

                async with httpx.AsyncClient() as client:
                    # Exchange code for token
                    # HubSpot requires application/x-www-form-urlencoded (per HubSpot OAuth docs)
                    # httpx automatically sets this when using data= parameter, but we'll be explicit
                    headers = {"Accept": "application/json"}
                    if self.provider_name == "hubspot":
                        # Explicitly set Content-Type for HubSpot (though httpx should do this automatically)
                        headers["Content-Type"] = "application/x-www-form-urlencoded"
                    
                    logger.info(
                        f"Exchanging authorization code for token at {token_endpoint}. "
                        f"Auth method: {auth_method}, PKCE: {bool(code_verifier)}, "
                        f"client_id={self.client_id}, "
                        f"client_secret={'present' if 'client_secret' in token_data else 'NOT_INCLUDED'}, "
                        f"code_length={len(code) if code else 0}, "
                        f"redirect_uri={self.redirect_uri}, "
                        f"Content-Type={headers.get('Content-Type', 'auto-set-by-httpx')}"
                    )
                    logger.debug(
                        f"Token exchange request data keys: {list(token_data.keys())}, "
                        f"has_code_verifier={'code_verifier' in token_data}, "
                        f"has_client_secret={'client_secret' in token_data}"
                    )
                    token_response = await client.post(
                        token_endpoint,
                        data=token_data,
                        headers=headers,
                        timeout=30.0
                    )
                    
                    # Log response details for debugging
                    logger.info(
                        f"Token exchange response: status={token_response.status_code}, "
                        f"headers={dict(token_response.headers)}, "
                        f"response_length={len(token_response.text) if token_response.text else 0}"
                    )
                    if token_response.status_code != 200:
                        logger.error(
                            f"Token exchange failed. Response body: {token_response.text[:500]}"
                        )
                    
                    if token_response.status_code != 200:
                        error_text = token_response.text
                        logger.error(
                            f"Token exchange failed: status={token_response.status_code}, "
                            f"response={error_text}"
                        )
                        token_response.raise_for_status()
                    
                    token_result = token_response.json()
                    logger.info(
                        f"[{self.provider_name}] Token exchange successful, response keys: {list(token_result.keys())}"
                    )

                    # Log FULL token response for PayPal debugging (to understand login: token format)
                    if self.provider_name == "paypal":
                        logger.warning(
                            f"[paypal] Full token response from PayPal: {token_result}"
                        )

                    access_token = token_result.get("access_token")
                    if not access_token:
                        logger.error(f"[{self.provider_name}] No access_token in response: {token_result}")
                        return {
                            "success": False,
                            "error": "No access token received from OAuth provider"
                        }

                    # Detect non-standard token formats (PayPal returns login:username:password)
                    if access_token.startswith("login:"):
                        logger.error(
                            f"[{self.provider_name}] Received non-standard 'login:' format token from OAuth provider. "
                            f"This appears to be test/development credentials instead of a proper OAuth Bearer token. "
                            f"Token format: login:username:password (length: {len(access_token)}). "
                            f"OAuth 2.1 requires opaque or JWT Bearer tokens, not login credentials. "
                            f"This may indicate: (1) PayPal MCP is in beta/test mode, "
                            f"(2) Missing required configuration/scopes, or "
                            f"(3) PayPal MCP requires special app setup."
                        )
                        # Log the full response to help debug
                        logger.error(
                            f"[{self.provider_name}] Full token response for debugging: {token_result}"
                        )
                    
                    # Detect REST API keys for Stripe (should not be used with MCP)
                    if self.provider_name == "stripe" and access_token.startswith(("sk_", "rk_", "pk_")):
                        logger.error(
                            f"[stripe] ⚠️ Received REST API key instead of OAuth access token! "
                            f"Token starts with: {access_token[:4]}. "
                            f"Stripe MCP requires OAuth access token obtained through OAuth flow. "
                            f"REST API keys (sk_/rk_/pk_) cannot be used with Stripe MCP. "
                            f"This may indicate: (1) Wrong token type being saved, "
                            f"(2) OAuth flow not completed properly, or "
                            f"(3) Manual REST API key was saved instead of OAuth token."
                        )
                        return {
                            "success": False,
                            "error": "Stripe MCP requires OAuth access token, but REST API key was received. Please complete OAuth flow to obtain proper access token."
                        }

                    # Enhanced logging for Stripe OAuth success
                    token_preview = f"{access_token[:15]}...{access_token[-10:]}" if len(access_token) > 25 else access_token[:25]
                    logger.info(
                        f"✅ [{self.provider_name.upper()}] OAuth Login SUCCESSFUL!\n"
                        f"  - Token obtained successfully\n"
                        f"  - Token length: {len(access_token)}\n"
                        f"  - Token preview: {token_preview}\n"
                        f"  - Token starts with: {access_token[:20]}\n"
                        f"  - Agent ID: {agent_id}\n"
                        f"  - MCP URL: {mcp_url}"
                    )
                    
                    # Extract refresh_token and expires_in from token response
                    refresh_token = token_result.get("refresh_token")
                    expires_in = token_result.get("expires_in")
                    
                    if refresh_token:
                        refresh_preview = f"{refresh_token[:15]}...{refresh_token[-10:]}" if len(refresh_token) > 25 else refresh_token[:25]
                        logger.info(
                            f"✅ [{self.provider_name}] Refresh token received:\n"
                            f"  - Length: {len(refresh_token)}\n"
                            f"  - Preview: {refresh_preview}"
                        )
                    else:
                        logger.warning(
                            f"⚠️ [{self.provider_name}] No refresh_token received. "
                            f"Token cannot be refreshed automatically."
                        )
                    
                    if expires_in:
                        from datetime import datetime, timedelta
                        expires_at = datetime.utcnow() + timedelta(seconds=expires_in)
                        logger.info(
                            f"✅ [{self.provider_name}] Token expiration info:\n"
                            f"  - Expires in: {expires_in} seconds ({expires_in // 3600}h {expires_in % 3600 // 60}m)\n"
                            f"  - Expires at: {expires_at.isoformat()}"
                        )
                    else:
                        logger.warning(
                            f"⚠️ [{self.provider_name}] No expires_in received. "
                            f"Cannot determine token expiration."
                        )
            finally:
                # Always clean up code_verifier (success or failure)
                if state in self._pkce_verifiers:
                    del self._pkce_verifiers[state]
                    logger.debug("Removed code_verifier from memory")

                # Also remove from persistent storage
                await self._delete_pkce_verifier(agent_id, state)

            # Get user information (provider-specific)
            # This is optional and provider-specific
            # Some providers may not have a user info endpoint
            user_data = {}
            username = None
            email = None

            # Try to get user info if we can determine the provider API
            # For GitHub: https://api.github.com/user
            # For other providers, this would need to be configured or discovered
            # For now, we'll skip user info retrieval and let providers implement it
            # if needed via their specific service classes

            # Store credentials via evo-ai-core API (only if access_token was obtained)
            if access_token:
                try:
                    logger.info(
                        f"💾 [{self.provider_name}] Storing OAuth credentials to database:\n"
                        f"  - Agent ID: {agent_id}\n"
                        f"  - Has access_token: True\n"
                        f"  - Has refresh_token: {bool(refresh_token)}\n"
                        f"  - Has expires_in: {expires_in is not None}\n"
                        f"  - Username: {username or 'N/A'}\n"
                        f"  - Email: {email or 'N/A'}"
                    )
                    
                    await self._store_credentials(
                        agent_id=agent_id,
                        mcp_url=mcp_url,
                        access_token=access_token,
                        username=username,
                        email=email,
                        user_data=user_data,
                        oauth_metadata=self._oauth_metadata,
                        refresh_token=refresh_token,
                        expires_in=expires_in,
                        db=db
                    )
                    
                    logger.info(
                        f"✅ [{self.provider_name}] Credentials stored successfully! "
                        f"OAuth login completed and saved."
                    )
                except Exception as store_error:
                    logger.error(
                        f"❌ [{self.provider_name}] Error storing credentials: {store_error}\n"
                        f"  - Token was obtained successfully but storage failed\n"
                        f"  - User may need to retry or store manually",
                        exc_info=True
                    )
                    # Don't fail the authorization if storage fails - token was obtained successfully
                    # The user can retry or the token can be stored manually
            else:
                logger.error(
                    f"❌ [{self.provider_name}] OAuth login FAILED - No access_token to store\n"
                    f"  - Agent ID: {agent_id}\n"
                    f"  - Token exchange may have failed"
                )
                return {
                    "success": False,
                    "error": "Failed to obtain access token"
                }

            logger.info(
                f"🎉 [{self.provider_name.upper()}] OAuth Authorization Flow COMPLETED SUCCESSFULLY!\n"
                f"  - Success: True\n"
                f"  - Username: {username or 'N/A'}\n"
                f"  - Email: {email or 'N/A'}\n"
                f"  - MCP URL: {mcp_url}\n"
                f"  - Token ready for use"
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
                f"HTTP error completing authorization: status={e.response.status_code}, "
                f"url={e.request.url if hasattr(e, 'request') else 'unknown'}, "
                f"error={error_text}"
            )
            return {
                "success": False,
                "error": f"HTTP error: {e.response.status_code} - {error_text}"
            }
        except Exception as e:
            logger.error(f"Error completing authorization: {e}")
            return {
                "success": False,
                "error": str(e)
            }

    async def _store_pkce_verifier(
        self,
        agent_id: str,
        state: str,
        code_verifier: str,
        db: Optional[Any] = None
    ) -> None:
        """Store PKCE code_verifier for retrieval during callback."""
        try:
            # Load existing config
            existing_config = await self._load_credentials(agent_id, self.mcp_url, db=db) or {}

            # Add/update pkce_verifiers dict
            pkce_verifiers = existing_config.get("pkce_verifiers", {})
            pkce_verifiers[state] = code_verifier
            existing_config["pkce_verifiers"] = pkce_verifiers

            # Prefer direct database access if db session is available
            if db is not None:
                try:
                    from src.services.agent_service import upsert_agent_integration
                    success = await upsert_agent_integration(db, agent_id, self.provider_name, existing_config)
                    if success:
                        logger.info(
                            f"Stored PKCE verifier for {self.provider_name} directly to database "
                            f"(state: {state[:20]}..., total_verifiers={len(pkce_verifiers)})"
                        )
                        return
                    else:
                        logger.warning(f"Failed to store PKCE verifier to database, falling back to HTTP")
                except Exception as db_error:
                    logger.warning(f"Error storing PKCE verifier to database: {db_error}, falling back to HTTP")
            
            # Fallback to HTTP API if db is not available or database operation failed
            url = f"{self.core_service_url}/agents/{agent_id}/integrations"
            logger.info(
                f"Storing PKCE verifier for {self.provider_name} via HTTP. "
                f"state_length={len(state)}, code_verifier_length={len(code_verifier)}, "
                f"total_verifiers={len(pkce_verifiers)}"
            )
            response = await self.http_client.post(
                url,
                json={"provider": self.provider_name, "config": existing_config}
            )
            response.raise_for_status()
            logger.info(f"Successfully stored PKCE verifier for {self.provider_name} via HTTP (state: {state[:20]}...)")
        except Exception as e:
            logger.error(
                f"Failed to store PKCE verifier for {self.provider_name}: {e}",
                exc_info=True
            )
            raise

    async def _load_pkce_verifier(
        self,
        agent_id: str,
        state: str,
        db: Optional[Any] = None
    ) -> Optional[str]:
        """Load PKCE code_verifier from storage."""
        try:
            config = await self._load_credentials(agent_id, self.mcp_url, db=db)
            if config and "pkce_verifiers" in config:
                pkce_verifiers = config["pkce_verifiers"]
                logger.info(
                    f"Loading PKCE verifier for {self.provider_name}. "
                    f"state_length={len(state)}, "
                    f"available_states={list(pkce_verifiers.keys())[:3] if pkce_verifiers else []}, "
                    f"total_verifiers={len(pkce_verifiers)}"
                )
                verifier = pkce_verifiers.get(state)
                if verifier:
                    logger.info(f"Found PKCE verifier for {self.provider_name} (length: {len(verifier)})")
                else:
                    logger.warning(
                        f"No PKCE verifier found for state {state[:20]}... "
                        f"Available states: {list(pkce_verifiers.keys())[:3]}"
                    )
                return verifier
            else:
                logger.warning(f"No pkce_verifiers in config for {self.provider_name}")
            return None
        except Exception as e:
            logger.error(
                f"Failed to load PKCE verifier for {self.provider_name}: {e}",
                exc_info=True
            )
            return None

    async def _delete_pkce_verifier(
        self,
        agent_id: str,
        state: str
    ) -> None:
        """Delete PKCE code_verifier from storage after use."""
        try:
            config = await self._load_credentials(agent_id, self.mcp_url)
            if config and "pkce_verifiers" in config:
                pkce_verifiers = config["pkce_verifiers"]
                if state in pkce_verifiers:
                    del pkce_verifiers[state]
                    config["pkce_verifiers"] = pkce_verifiers

                    # Update storage
                    url = f"{self.core_service_url}/agents/{agent_id}/integrations"
                    response = await self.http_client.post(
                        url,
                        json={"provider": self.provider_name, "config": config}
                    )
                    response.raise_for_status()
                    logger.debug(f"Deleted PKCE verifier for state {state[:10]}...")
        except Exception as e:
            logger.warning(f"Could not delete PKCE verifier: {e}")

    async def _store_client_credentials(
        self,
        agent_id: str,
        mcp_url: str,
        token_endpoint_auth_method: str = "none",
        db: Optional[Any] = None
    ) -> None:
        """Store only client credentials (client_id/secret) without access token."""
        # Load existing config first to preserve pkce_verifiers and other fields
        existing_config = await self._load_credentials(agent_id, mcp_url, db=db) or {}
        
        # IMPORTANT: Also check memory for pkce_verifiers that may not have been saved yet
        # This handles the case where _store_pkce_verifier was called but hasn't completed HTTP save
        memory_pkce_verifiers = {}
        if hasattr(self, '_pkce_verifiers') and self._pkce_verifiers:
            memory_pkce_verifiers = self._pkce_verifiers.copy()
            logger.info(
                f"[{self.provider_name}] Found {len(memory_pkce_verifiers)} PKCE verifiers in memory. "
                f"Will merge with stored config."
            )
        
        # Merge memory pkce_verifiers with stored ones (memory takes precedence for latest state)
        stored_pkce_verifiers = existing_config.get("pkce_verifiers", {})
        if memory_pkce_verifiers:
            stored_pkce_verifiers = {**stored_pkce_verifiers, **memory_pkce_verifiers}
            logger.info(
                f"[{self.provider_name}] Merged memory PKCE verifiers with stored ones. "
                f"Total verifiers: {len(stored_pkce_verifiers)}"
            )
        
        # Log what we're preserving
        has_pkce_verifiers = bool(stored_pkce_verifiers)
        logger.info(
            f"[{self.provider_name}] Storing client credentials. "
            f"Preserving pkce_verifiers: {has_pkce_verifiers}, "
            f"pkce_verifiers_count={len(stored_pkce_verifiers)}"
        )
        
        # Update only client credentials fields, preserving existing data
        config = {
            **existing_config,  # Preserve existing fields
            "provider": self.provider_name,
            "connected": False,  # Not fully connected yet (no access token)
            "mcp_url": mcp_url,
            "client_id": self.client_id,
            "client_secret": self.client_secret,  # May be None for public clients
            "token_endpoint_auth_method": token_endpoint_auth_method,
            "registered_at": datetime.utcnow().isoformat()
        }
        
        # Always preserve pkce_verifiers (from stored config or memory)
        if stored_pkce_verifiers:
            config["pkce_verifiers"] = stored_pkce_verifiers
            logger.info(
                f"[{self.provider_name}] Preserved {len(stored_pkce_verifiers)} PKCE verifiers in config"
            )
        elif has_pkce_verifiers:
            # Fallback: use from existing_config if somehow lost
            config["pkce_verifiers"] = existing_config.get("pkce_verifiers", {})
            logger.warning(
                f"[{self.provider_name}] pkce_verifiers was lost during config merge, restoring from existing_config"
            )

        # Prefer direct database access if db session is available
        if db is not None:
            try:
                from src.services.agent_service import upsert_agent_integration
                success = await upsert_agent_integration(db, agent_id, self.provider_name, config)
                if success:
                    logger.info(
                        f"Successfully stored client credentials for {self.provider_name} "
                        f"directly to database (agent: {agent_id})"
                    )
                    return
                else:
                    logger.warning(f"Failed to store client credentials to database, falling back to HTTP")
            except Exception as db_error:
                logger.warning(f"Error storing client credentials to database: {db_error}, falling back to HTTP")
        
        # Fallback to HTTP API if db is not available or database operation failed
        url = f"{self.core_service_url}/agents/{agent_id}/integrations"
        try:
            response = await self.http_client.post(
                url,
                json={"provider": self.provider_name, "config": config}
            )
            response.raise_for_status()
            logger.info(
                f"Successfully stored client credentials for {self.provider_name} "
                f"via HTTP API (agent: {agent_id})"
            )
        except httpx.HTTPStatusError as e:
            logger.error(
                f"Failed to store client credentials for {self.provider_name} integration: "
                f"status={e.response.status_code}, "
                f"response={e.response.text[:500]}, "
                f"url={url}"
            )
            raise
        except Exception as e:
            logger.error(
                f"Unexpected error storing client credentials for {self.provider_name} integration: {e}",
                exc_info=True
            )
            raise

    async def _store_credentials(
        self,
        agent_id: str,
        mcp_url: str,
        access_token: str,
        username: Optional[str],
        email: Optional[str],
        user_data: Dict[str, Any],
        oauth_metadata: Dict[str, Any],
        refresh_token: Optional[str] = None,
        expires_in: Optional[int] = None,
        db: Optional[Any] = None
    ) -> None:
        """Store OAuth credentials directly to database or via evo-ai-core API."""
        url = f"{self.core_service_url}/agents/{agent_id}/integrations"

        config = {
            "provider": self.provider_name,
            "connected": True,
            "mcp_url": mcp_url,
            "username": username,
            "email": email,
            "access_token": access_token,
            "user_data": user_data,
            "oauth_metadata": oauth_metadata,
            "connected_at": datetime.utcnow().isoformat()
        }

        # Include refresh token if available
        if refresh_token:
            config["refresh_token"] = refresh_token
        
        # Include token expiration if available
        if expires_in is not None:
            config["expires_in"] = expires_in
            # Calculate expiration timestamp (ISO format, UTC)
            expiration_time = datetime.utcnow().timestamp() + expires_in
            config["expires_at"] = datetime.utcfromtimestamp(expiration_time).isoformat()

        # Include dynamically registered client credentials if available
        if self.client_id:
            config["client_id"] = self.client_id
        if self.client_secret:
            config["client_secret"] = self.client_secret
        if hasattr(self, '_token_endpoint_auth_method') and self._token_endpoint_auth_method:
            config["token_endpoint_auth_method"] = self._token_endpoint_auth_method

        logger.info(
            f"Storing credentials for {self.provider_name} integration. "
            f"agent_id={agent_id}"
        )
        
        # Prefer direct database access if db session is available
        if db is not None:
            try:
                from src.services.agent_service import upsert_agent_integration
                success = await upsert_agent_integration(db, agent_id, self.provider_name, config)
                if success:
                    logger.info(
                        f"Successfully stored credentials for {self.provider_name} integration "
                        f"directly to database (agent: {agent_id})"
                    )
                    return
                else:
                    logger.warning(f"Failed to store credentials to database, falling back to HTTP")
            except Exception as db_error:
                logger.warning(f"Error storing credentials to database: {db_error}, falling back to HTTP")
        
        # Fallback to HTTP API if db is not available or database operation failed
        try:
            # Use http_client if user_token is set, otherwise create a new client without auth
            # This is needed for callbacks where user_token is empty
            # NOTE: This may fail if core-service requires authentication
            # TODO: Consider using a service token or modifying core-service to allow unauthenticated callbacks
            if self.user_token:
                logger.debug(f"Using authenticated client for {self.provider_name} credential storage")
                response = await self.http_client.post(
                    url,
                    json={"provider": self.provider_name, "config": config}
                )
            else:
                # Callback scenario: create a client without auth header
                # WARNING: This will fail if core-service requires authentication
                logger.warning(
                    f"Attempting to store {self.provider_name} credentials without authentication. "
                    f"This may fail if core-service requires auth. URL: {url}"
                )
                async with httpx.AsyncClient(timeout=30.0) as client:
                    response = await client.post(
                        url,
                        json={"provider": self.provider_name, "config": config}
                    )
            
            response.raise_for_status()
            logger.info(
                f"Successfully stored credentials for {self.provider_name} integration "
                f"via HTTP API (agent: {agent_id})"
            )
        except httpx.HTTPStatusError as e:
            logger.error(
                f"Failed to store credentials for {self.provider_name} integration: "
                f"status={e.response.status_code}, "
                f"response={e.response.text[:500]}, "
                f"url={url}, "
                f"has_user_token={bool(self.user_token)}"
            )
            raise
        except Exception as e:
            logger.error(
                f"Unexpected error storing credentials for {self.provider_name} integration: {e}",
                exc_info=True
            )
            raise

    async def _load_credentials(
        self,
        agent_id: str,
        mcp_url: Optional[str] = None,
        db: Optional[Any] = None
    ) -> Optional[Dict[str, Any]]:
        """Load OAuth credentials from database (preferred) or evo-ai-core API."""
        # Prefer direct database access if db session is available
        if db is not None:
            try:
                from src.services.agent_service import get_agent_integrations
                logger.info(
                    f"[{self.provider_name}] Loading credentials from database "
                    f"(agent: {agent_id})"
                )
                integrations = await get_agent_integrations(db, agent_id)
                logger.info(
                    f"[{self.provider_name}] Found {len(integrations)} integrations in database. "
                    f"Providers: {[i.get('provider') for i in integrations]}"
                )
                for integration in integrations:
                    provider_name = integration.get("provider", "").lower()
                    logger.debug(
                        f"[{self.provider_name}] Checking integration provider: {provider_name} "
                        f"(looking for: {self.provider_name.lower()})"
                    )
                    if provider_name == self.provider_name.lower():
                        config = integration.get("config", {})
                        logger.info(
                            f"[{self.provider_name}] Found matching integration in database. "
                            f"Has client_id: {bool(config.get('client_id'))}, "
                            f"Has client_secret: {bool(config.get('client_secret'))}, "
                            f"Connected: {config.get('connected', False)}"
                        )
                        return config
                logger.warning(
                    f"[{self.provider_name}] No matching integration found in database. "
                    f"Available providers: {[i.get('provider') for i in integrations]}"
                )
                return None
            except Exception as db_error:
                logger.warning(
                    f"Error loading {self.provider_name} credentials from database: {db_error}, "
                    f"falling back to HTTP"
                )
        
        # Fallback to HTTP API if db is not available or database operation failed
        try:
            url = f"{self.core_service_url}/agents/{agent_id}/integrations/{self.provider_name}"

            # Use http_client if user_token is set, otherwise create a new client without auth
            # This is needed for callbacks where user_token is empty
            if self.user_token:
                response = await self.http_client.get(url)
            else:
                # Callback scenario: create a client without auth header
                # The core-service endpoint should allow this for OAuth callbacks
                async with httpx.AsyncClient(timeout=30.0) as client:
                    response = await client.get(url)

            if response.status_code == 404:
                return None

            response.raise_for_status()
            data = response.json()
            return data.get('config')

        except httpx.HTTPStatusError as e:
            if e.response.status_code == 404:
                return None
            logger.error(
                f"Failed to load credentials for {self.provider_name} integration: "
                f"status={e.response.status_code}, "
                f"response={e.response.text[:500]}, "
                f"url={url}, "
                f"has_user_token={bool(self.user_token)}"
            )
            raise

    async def refresh_access_token(
        self,
        agent_id: str,
        mcp_url: Optional[str] = None,
        db: Optional[Any] = None
    ) -> Optional[str]:
        """
        Refresh expired access token using refresh_token.

        Implements OAuth 2.0 refresh token flow (RFC 6749):
        1. Load stored credentials
        2. Check if token is expired or near expiration
        3. Use refresh_token to get new access_token
        4. Update stored credentials with new tokens (handles refresh token rotation)

        Args:
            agent_id: Agent ID
            mcp_url: Optional MCP URL (if different from default)
            db: Optional database session for direct DB access

        Returns:
            New access_token if refresh was successful, None otherwise
        """
        try:
            effective_mcp_url = mcp_url or self.mcp_url
            
            # Load credentials
            credentials = await self._load_credentials(agent_id, effective_mcp_url, db=db)

            if not credentials:
                logger.warning(
                    f"[{self.provider_name}] No credentials found for refresh. "
                    f"agent_id={agent_id}"
                )
                return None
            
            access_token = credentials.get("access_token")
            refresh_token = credentials.get("refresh_token")
            
            if not access_token:
                logger.warning(
                    f"[{self.provider_name}] No access_token found for refresh. "
                    f"agent_id={agent_id}"
                )
                return None
            
            if not refresh_token:
                logger.warning(
                    f"[{self.provider_name}] No refresh_token found. Cannot refresh access token. "
                    f"agent_id={agent_id}"
                )
                return None
            
            # Check if token is expired or near expiration (within 5 minutes)
            expires_at = credentials.get("expires_at")
            should_refresh = False
            
            if expires_at:
                from datetime import datetime, timezone, timedelta
                try:
                    expires_dt = datetime.fromisoformat(expires_at.replace('Z', '+00:00'))
                    now = datetime.now(timezone.utc)
                    # Refresh if expired or expires within 5 minutes
                    if expires_dt <= now + timedelta(minutes=5):
                        should_refresh = True
                        logger.info(
                            f"[{self.provider_name}] Token expired or expiring soon. "
                            f"Expires at: {expires_at}, Current time: {now.isoformat()}, "
                            f"Will refresh."
                        )
                    else:
                        logger.debug(
                            f"[{self.provider_name}] Token still valid. "
                            f"Expires at: {expires_at}, Current time: {now.isoformat()}"
                        )
                except Exception as e:
                    logger.warning(
                        f"[{self.provider_name}] Could not parse expires_at: {e}. "
                        f"Will attempt refresh anyway."
                    )
                    should_refresh = True
            else:
                # No expiration info - try to refresh anyway if refresh_token is available
                logger.info(
                    f"[{self.provider_name}] No expires_at found, but refresh_token available. "
                    f"Will attempt refresh."
                )
                should_refresh = True
            
            if not should_refresh:
                return access_token  # Token is still valid
            
            # Get OAuth metadata if not cached
            if not self._oauth_metadata:
                await self.discover_oauth_requirements()
            
            # Get authorization server metadata if not cached
            authorization_servers = self._oauth_metadata.get("authorization_servers", [])
            if not authorization_servers:
                logger.error(f"[{self.provider_name}] No authorization servers found for refresh")
                return None
            
            authorization_server = authorization_servers[0]
            
            if not self._authorization_server_metadata:
                await self.discover_authorization_server(authorization_server)
            
            # Get token endpoint
            token_endpoint = self._authorization_server_metadata.get("token_endpoint")
            if not token_endpoint:
                logger.error(f"[{self.provider_name}] No token_endpoint found for refresh")
                return None
            
            # Load client credentials if needed
            if not self.client_id:
                stored_credentials = await self._load_credentials(agent_id, effective_mcp_url, db=db)
                if stored_credentials and stored_credentials.get("client_id"):
                    self.client_id = stored_credentials.get("client_id")
                    self.client_secret = stored_credentials.get("client_secret")
            
            if not self.client_id:
                logger.error(
                    f"[{self.provider_name}] No client_id found for refresh. "
                    f"Cannot refresh token."
                )
                return None
            
            # Prepare refresh token request
            refresh_data = {
                "grant_type": "refresh_token",
                "refresh_token": refresh_token,
                "client_id": self.client_id
            }
            
            # Include client_secret if auth method requires it
            # HubSpot and GitHub always require client_secret for refresh, even if auth_method is "none"
            auth_method = credentials.get("token_endpoint_auth_method") or getattr(self, '_token_endpoint_auth_method', None) or "none"
            needs_client_secret = (
                self.provider_name.lower() in ["hubspot", "github"] or 
                (auth_method != "none" and self.client_secret)
            )
            
            if needs_client_secret and self.client_secret:
                refresh_data["client_secret"] = self.client_secret
            elif needs_client_secret and not self.client_secret:
                logger.error(
                    f"[{self.provider_name}] client_secret is required for refresh but not found. "
                    f"auth_method={auth_method}"
                )
                return None
            
            logger.info(
                f"[{self.provider_name}] Refreshing access token. "
                f"token_endpoint={token_endpoint}, "
                f"auth_method={auth_method}, "
                f"needs_client_secret={needs_client_secret}, "
                f"has_client_secret={bool(self.client_secret)}, "
                f"client_secret_length={len(self.client_secret) if self.client_secret else 0}, "
                f"client_id={'***' + self.client_id[-4:] if self.client_id and len(self.client_id) > 4 else 'None'}"
            )
            
            # Log refresh_data keys (but not values for security)
            logger.debug(
                f"[{self.provider_name}] Refresh request data keys: {list(refresh_data.keys())}"
            )
            
            # Exchange refresh_token for new access_token
            async with httpx.AsyncClient() as client:
                headers = {"Accept": "application/json"}
                if self.provider_name == "hubspot":
                    headers["Content-Type"] = "application/x-www-form-urlencoded"
                
                refresh_response = await client.post(
                    token_endpoint,
                    data=refresh_data,
                    headers=headers,
                    timeout=30.0
                )
                
                if refresh_response.status_code != 200:
                    error_text = refresh_response.text
                    logger.error(
                        f"[{self.provider_name}] Token refresh failed: "
                        f"status={refresh_response.status_code}, "
                        f"response={error_text[:500]}"
                    )
                    refresh_response.raise_for_status()
                
                refresh_result = refresh_response.json()
                logger.info(
                    f"[{self.provider_name}] Token refresh successful. "
                    f"Response keys: {list(refresh_result.keys())}"
                )
                
                new_access_token = refresh_result.get("access_token")
                if not new_access_token:
                    logger.error(
                        f"[{self.provider_name}] No access_token in refresh response: {refresh_result}"
                    )
                    return None
                
                # Get new refresh_token if provided (refresh token rotation)
                new_refresh_token = refresh_result.get("refresh_token")
                new_expires_in = refresh_result.get("expires_in")
                
                # Update stored credentials with new tokens
                updated_config = {
                    **credentials,  # Preserve existing fields
                    "access_token": new_access_token,
                    "connected": True,
                    "refreshed_at": datetime.utcnow().isoformat()
                }
                
                # Update refresh_token if new one provided (rotation)
                if new_refresh_token:
                    updated_config["refresh_token"] = new_refresh_token
                    logger.info(
                        f"[{self.provider_name}] Refresh token rotated. "
                        f"New refresh_token received."
                    )
                
                # Update expiration
                if new_expires_in is not None:
                    updated_config["expires_in"] = new_expires_in
                    expiration_time = datetime.utcnow().timestamp() + new_expires_in
                    updated_config["expires_at"] = datetime.utcfromtimestamp(expiration_time).isoformat()
                
                # Store updated credentials
                await self._store_credentials(
                    agent_id=agent_id,
                    mcp_url=effective_mcp_url,
                    access_token=new_access_token,
                    username=credentials.get("username"),
                    email=credentials.get("email"),
                    user_data=credentials.get("user_data", {}),
                    oauth_metadata=self._oauth_metadata or credentials.get("oauth_metadata", {}),
                    refresh_token=new_refresh_token or refresh_token,  # Use new if rotated, otherwise keep old
                    expires_in=new_expires_in  # Update expiration if provided
                )
                
                logger.info(
                    f"[{self.provider_name}] Successfully refreshed and stored new access token. "
                    f"agent_id={agent_id}"
                )
                
                return new_access_token
                
        except httpx.HTTPStatusError as e:
            error_text = e.response.text if hasattr(e.response, 'text') else str(e)
            logger.error(
                f"[{self.provider_name}] HTTP error refreshing token: "
                f"status={e.response.status_code}, "
                f"error={error_text[:500]}"
            )
            return None
        except Exception as e:
            logger.error(
                f"[{self.provider_name}] Error refreshing access token: {e}",
                exc_info=True
            )
            return None

    async def get_mcp_headers(
        self,
        agent_id: str,
        mcp_url: Optional[str] = None,
        db: Optional[Any] = None
    ) -> Dict[str, str]:
        """
        Get headers for MCP server requests (includes Authorization header with OAuth token).

        Automatically refreshes token if expired or near expiration.

        Args:
            agent_id: Agent ID
            mcp_url: Optional MCP URL (if different from default)
            db: Optional database session for direct DB access

        Returns:
            Dictionary with headers for MCP requests
        """
        effective_mcp_url = mcp_url or self.mcp_url
        
        logger.info(
            f"🔍 [{self.provider_name}] Getting MCP headers:\n"
            f"  - Agent ID: {agent_id}\n"
            f"  - MCP URL: {effective_mcp_url}"
        )

        # Load credentials
        credentials = await self._load_credentials(agent_id, effective_mcp_url, db=db)

        if not credentials or not credentials.get("access_token"):
            logger.error(
                f"❌ [{self.provider_name}] MCP OAuth credentials not found!\n"
                f"  - Agent ID: {agent_id}\n"
                f"  - Has credentials: {bool(credentials)}\n"
                f"  - Has access_token: {bool(credentials.get('access_token') if credentials else False)}\n"
                f"  - Please complete OAuth authorization first"
            )
            raise Exception(
                f"MCP OAuth credentials not found for agent {agent_id}. "
                f"Please complete OAuth authorization first."
            )
        
        original_token = credentials.get("access_token")
        original_token_preview = f"{original_token[:15]}...{original_token[-10:]}" if len(original_token) > 25 else original_token[:25]
        
        logger.info(
            f"📋 [{self.provider_name}] Loaded credentials:\n"
            f"  - Has access_token: True\n"
            f"  - Token length: {len(original_token)}\n"
            f"  - Token preview: {original_token_preview}\n"
            f"  - Token starts with: {original_token[:20]}"
        )
        
        # Check token expiration before refresh
        expires_at = credentials.get("expires_at")
        if expires_at:
            from datetime import datetime, timezone
            try:
                expires_dt = datetime.fromisoformat(expires_at.replace('Z', '+00:00'))
                now = datetime.now(timezone.utc)
                if expires_dt.tzinfo:
                    now = now.replace(tzinfo=expires_dt.tzinfo)
                
                if expires_dt < now:
                    logger.warning(
                        f"⚠️ [{self.provider_name}] Token is EXPIRED!\n"
                        f"  - Expires at: {expires_at}\n"
                        f"  - Current time: {now.isoformat()}\n"
                        f"  - Will attempt refresh..."
                    )
                else:
                    time_until_expiry = expires_dt - now
                    logger.info(
                        f"✅ [{self.provider_name}] Token is valid:\n"
                        f"  - Expires at: {expires_at}\n"
                        f"  - Time until expiry: {time_until_expiry}\n"
                        f"  - Will check if refresh needed..."
                    )
            except Exception as e:
                logger.warning(f"Could not parse expires_at: {expires_at}, error: {e}")
        
        # Validate token format for Stripe before using
        if self.provider_name == "stripe" and original_token.startswith(("sk_", "rk_", "pk_")):
            logger.error(
                f"❌ [{self.provider_name}] INVALID TOKEN FORMAT!\n"
                f"  - Token starts with: {original_token[:4]}\n"
                f"  - Stripe MCP requires OAuth access token, not REST API key\n"
                f"  - This will cause 'Session terminated' error\n"
                f"  - Please complete OAuth flow to obtain proper token"
            )
            raise Exception(
                f"Stripe MCP requires OAuth access token, but REST API key found. "
                f"Please complete OAuth flow to obtain proper access token."
            )
        
        # Try to refresh token if needed
        access_token = await self.refresh_access_token(agent_id, effective_mcp_url, db=db)
        
        # If refresh failed, use existing token (may be expired, but MCP server will reject it)
        if not access_token:
            access_token = original_token
            logger.warning(
                f"⚠️ [{self.provider_name}] Token refresh failed or not attempted:\n"
                f"  - Using existing access_token (may be expired)\n"
                f"  - This may cause 'Session terminated' error if token is expired"
            )
        elif access_token != original_token:
            new_token_preview = f"{access_token[:15]}...{access_token[-10:]}" if len(access_token) > 25 else access_token[:25]
            logger.info(
                f"✅ [{self.provider_name}] Token refreshed successfully:\n"
                f"  - New token length: {len(access_token)}\n"
                f"  - New token preview: {new_token_preview}"
            )
        
        # Final validation before returning headers
        token_preview = f"{access_token[:15]}...{access_token[-10:]}" if len(access_token) > 25 else access_token[:25]
        logger.info(
            f"✅ [{self.provider_name}] MCP Headers ready:\n"
            f"  - Authorization header: Bearer {token_preview}\n"
            f"  - Token length: {len(access_token)}\n"
            f"  - Token starts with: {access_token[:20]}\n"
            f"  - Will be used for MCP requests to: {effective_mcp_url}"
        )
        
        # Return headers for MCP server
        # Format: Authorization: Bearer <token>
        return {
            "Authorization": f"Bearer {access_token}",
            "Content-Type": "application/json",
            "Accept": "application/json"
        }

    async def disconnect(
        self,
        agent_id: str,
        mcp_url: Optional[str] = None
    ) -> bool:
        """Disconnect MCP integration by deleting stored credentials."""
        try:
            url = f"{self.core_service_url}/agents/{agent_id}/integrations/{self.provider_name}"

            response = await self.http_client.delete(url)
            response.raise_for_status()
            logger.info(f"Disconnected {self.provider_name} integration (agent: {agent_id})")
            return True

        except httpx.HTTPStatusError as e:
            if e.response.status_code == 404:
                return True  # Already disconnected
            logger.error(f"Error disconnecting MCP integration: {e}")
            return False
        except Exception as e:
            logger.error(f"Error disconnecting MCP integration: {e}")
            return False

