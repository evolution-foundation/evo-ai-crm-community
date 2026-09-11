"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: evo_auth_service.py                                                   │
│ Developed by: Davidson Gomes                                                 │
│ Creation date: January 27, 2025                                              │
│ Contact: contato@evolution-api.com                                           │
├──────────────────────────────────────────────────────────────────────────────┤
│ @copyright © Evolution API 2025. All rights reserved.                        │
│ Licensed under the Apache License, Version 2.0                               │
│                                                                              │
│ You may not use this file except in compliance with the License.             │
│ You may obtain a copy of the License at                                      │
│                                                                              │
│    http://www.apache.org/licenses/LICENSE-2.0                                │
│                                                                              │
│ Unless required by applicable law or agreed to in writing, software          │
│ distributed under the License is distributed on an "AS IS" BASIS,            │
│ WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.     │
│ See the License for the specific language governing permissions and          │
│ limitations under the License.                                               │
├──────────────────────────────────────────────────────────────────────────────┤
│ @important                                                                   │
│ For any future changes to the code in this file, it is recommended to        │
│ include, together with the modification, the information of the developer    │
│ who changed it and the date of modification.                                 │
└──────────────────────────────────────────────────────────────────────────────┘
"""

from typing import Optional, Dict, Any
# Aliased: this module defines its own ValidationError below, which would
# otherwise shadow pydantic's and silently change what the except clauses catch.
from pydantic import ValidationError as PydanticValidationError
import httpx
from src.utils.logger import setup_logger
from src.config.settings import settings
from src.utils.http import HttpError
from src.schemas.auth import EvoAuthResponse

logger = setup_logger(__name__)


def describe_payload_shape(payload: Any) -> str:
    """Field names and types of a payload, never its values.

    The validate payload embeds the token itself, so it must not reach the logs.
    A field-name map is what a wire-shape drift (EVO-2123: `token` vs
    `access_token`) actually needs to be diagnosed.
    """
    if isinstance(payload, dict):
        return "{" + ", ".join(
            f"{key}: {describe_payload_shape(value)}" for key, value in payload.items()
        ) + "}"
    if isinstance(payload, list):
        inner = describe_payload_shape(payload[0]) if payload else "?"
        return f"[{inner}]"
    return type(payload).__name__


class AuthenticationError(Exception):
    """Raised when token validation fails"""
    pass


class ValidationError(Exception):
    """Raised when response validation fails"""
    pass


class NetworkError(Exception):
    """Raised when network/connectivity issues occur"""
    pass


class ServiceUnavailableError(Exception):
    """Raised when auth service is unavailable"""
    pass


class EvoAuthService:
    """Service for Evo Auth authentication validation and user management
    
    Provides unified interface for:
    - Token validation (bearer and api_access_token)
    - User and account management
    - Permission checking
    - Role management
    """
    
    def __init__(self, evo_auth_base_url: str = None):
        self.base_url = (evo_auth_base_url or settings.EVO_AUTH_BASE_URL).rstrip("/")
        self.timeout = httpx.Timeout(connect=5.0, read=10.0, write=5.0, pool=5.0)
    
    # ============================================================================
    # Authentication Methods
    # ============================================================================
    
    async def validate_token(self, token: str, token_type: str) -> Optional[EvoAuthResponse]:
        """Validate token with Evo Auth API - Primary authentication method
        
        Args:
            token: The authentication token
            token_type: Either 'bearer' or 'api_access_token'
            
        Returns:
            EvoAuthResponse with user and accounts data, or None if validation fails
        """
        headers = self.build_headers(token, token_type)
        
        logger.info(f"EvoAuth: Validating {token_type} token at {self.base_url}/api/v1/auth/validate")
        
        try:
            response_json = await self._post_request('/api/v1/auth/validate', {}, headers)
            
            if not response_json:
                logger.warning("EvoAuth: Empty response from validation endpoint")
                return None
            
            # Check for error in response
            if not response_json.get('success', False):
                error_info = response_json.get('error', {})
                logger.warning(f"EvoAuth: Validation failed: {error_info.get('message', 'Unknown error')}")
                return None
            
            # Extract data from response
            response_data = response_json.get('data')
            if not response_data:
                logger.warning(f"EvoAuth: Invalid response format - missing 'data' field")
                return None
            
            try:
                auth_response = EvoAuthResponse(**response_data)
                logger.info(f"Token validation successful for user: {auth_response.user.email}")
                return auth_response
            except PydanticValidationError as e:
                # Never log the payload or the pydantic error verbatim: both carry
                # the token value. The field names are what a shape drift like
                # EVO-2123 needs anyway.
                safe_errors = [
                    {"loc": err.get("loc"), "type": err.get("type"), "msg": err.get("msg")}
                    for err in e.errors()
                ]
                logger.error(f"Validation error parsing EvoAuth response: {safe_errors}")
                logger.error(f"EvoAuth response shape: {describe_payload_shape(response_data)}")
                return None
            except (ValueError, KeyError) as e:
                logger.error(f"Error parsing EvoAuth response: {type(e).__name__}: {e}")
                return None
                
        except AuthenticationError:
            # Token is invalid - return None to allow fallback to Agent API Key
            return None
        except NetworkError:
            # Network errors should be re-raised
            raise
        except Exception as e:
            logger.error(f"Unexpected error during token validation: {e}")
            return None
    
    def build_headers(self, token: str, token_type: str) -> Dict[str, str]:
        """Build HTTP headers based on token type
        
        Args:
            token: The authentication token
            token_type: Either 'bearer' or 'api_access_token'
            
        Returns:
            Dictionary with appropriate headers
            
        Raises:
            ValueError: When token_type is invalid
        """
        if token_type == "bearer":
            return {
                'Authorization': f'Bearer {token}',
                'Content-Type': 'application/json',
                'Accept': 'application/json'
            }
        elif token_type == "api_access_token":
            return {
                'api_access_token': token,
                'Content-Type': 'application/json',
                'Accept': 'application/json'
            }
        else:
            raise ValueError(f"Invalid token type: {token_type}")
    
    # ============================================================================
    # Permission Management Methods
    # ============================================================================
    
    async def check_user_permission(self, user_id: str, permission_key: str, 
                                   auth_token: str = None, token_type: str = "bearer") -> bool:
        """Check global user permission
        
        Args:
            user_id: The user UUID
            permission_key: Permission key (e.g., 'ai_clients.usage')
            auth_token: Optional authentication token
            token_type: Type of auth_token ('bearer' or 'api_access_token')
            
        Returns:
            True if user has permission, False otherwise
        """
        try:
            headers = self.build_headers(auth_token, token_type) if auth_token else {}
            response_json = await self._post_request(
                f'/api/v1/users/check_permission',
                {'permission_key': permission_key},
                headers
            )
            
            if response_json and response_json.get('success'):
                response_data = response_json.get('data', {})
                if response_data.get('has_permission'):
                    return True
            
            error_info = response_json.get('error', {}) if response_json else {}
            logger.error(f"Failed to check user permission: {error_info.get('message', 'Unknown error')}")
            return False
        except Exception as e:
            logger.error(f"Error checking user permission: {e}")
            return False
    
    async def check_permission(self, auth_token: str, permission_key: str, token_type: str = "bearer") -> bool:
        """Check if authenticated user has specific permission
        
        Args:
            auth_token: Authentication token
            permission_key: Permission key (e.g., 'ai_clients.usage')
            token_type: Type of auth_token ('bearer' or 'api_access_token')
            
        Returns:
            True if user has permission, False otherwise
        """
        try:
            headers = self.build_headers(auth_token, token_type)
            response_json = await self._post_request(
                '/api/v1/permissions/check',
                {'permission_key': permission_key},
                headers
            )
            
            if response_json and response_json.get('success'):
                response_data = response_json.get('data', {})
                has_permission = response_data.get('has_permission', False)
            else:
                has_permission = False
            
            logger.debug(f"Permission check for {permission_key}: {has_permission}")
            return has_permission
        except HttpError as e:
            if e.status_code == 404:
                # Endpoint not found - permissions system not implemented yet
                logger.warning(f"Permission endpoint not found (404) - allowing access for authenticated user (permission: {permission_key})")
                return True
            logger.warning(f"Permission check failed for {permission_key}: {e.message} (status: {e.status_code})")
            return False
        except Exception as e:
            logger.error(f"Unexpected error checking permission {permission_key}: {e}")
            return False
    
    # ============================================================================
    # Private HTTP Methods
    # ============================================================================
    
    async def _post_request(self, endpoint: str, payload: Dict[str, Any], headers: Dict[str, str] = None) -> Optional[Dict[str, Any]]:
        """Execute POST request to evo-auth-service
        
        Args:
            endpoint: API endpoint (e.g., '/api/v1/auth/validate')
            payload: Request body as dictionary
            headers: Optional HTTP headers
            
        Returns:
            Response JSON as dictionary (complete response with success, data, meta) or None on error
        """
        url = f"{self.base_url}{endpoint}"
        headers = headers or {}
        
        try:
            async with httpx.AsyncClient(timeout=self.timeout) as client:
                response = await client.post(url, json=payload, headers=headers)
                response.raise_for_status()
                return response.json()
        except httpx.TimeoutException as e:
            logger.error(f"EvoAuth: Request timeout for POST {endpoint}: {e}")
            raise NetworkError("Request timeout")
        except httpx.HTTPStatusError as e:
            logger.error(f"EvoAuth: HTTP error for POST {endpoint}: {e.response.status_code} - {e.response.text}")
            if e.response.status_code == 401:
                raise AuthenticationError("Invalid or expired token")
            raise NetworkError(f"HTTP error: {e.response.status_code}")
        except httpx.RequestError as e:
            logger.error(f"EvoAuth: Network error for POST {endpoint}: {e}")
            raise NetworkError(f"Network error: {e}")
        except Exception as e:
            logger.error(f"EvoAuth: Unexpected error for POST {endpoint}: {e}")
            return None


# Global instance
evo_auth_service: Optional[EvoAuthService] = None

def get_auth_service() -> EvoAuthService:
    """Get or create singleton auth service instance"""
    global evo_auth_service
    if evo_auth_service is None:
        evo_auth_service = EvoAuthService(evo_auth_base_url=settings.EVO_AUTH_BASE_URL)
    return evo_auth_service

