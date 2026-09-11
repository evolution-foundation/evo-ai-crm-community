"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: http.py                                                               │
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

import httpx
import time
from typing import Dict, Any, Optional, TypeVar, Generic, Tuple
from fastapi import Request, HTTPException
from pydantic import BaseModel
from src.utils.logger import setup_logger

logger = setup_logger(__name__)

# Type variable for generic responses
T = TypeVar('T')

class HttpError(Exception):
    """Custom HTTP error for better error handling"""
    
    def __init__(self, message: str, status_code: int, details: Optional[str] = None):
        self.message = message
        self.status_code = status_code
        self.details = details
        super().__init__(self.message)

class HttpClient:
    """HTTP client utility for making requests to external services"""
    
    def __init__(self, timeout: float = 30.0):
        self.timeout = timeout
    
    def set_headers(self, headers: Optional[Dict[str, str]] = None) -> Dict[str, str]:
        """Set default headers for requests"""
        default_headers = {
            "Content-Type": "application/json",
            "Accept": "application/json"
        }
        
        if headers:
            default_headers.update(headers)
        
        return default_headers
    
    async def do_post_json(
        self,
        url: str,
        payload: Optional[Dict[str, Any]] = None,
        headers: Optional[Dict[str, str]] = None,
        expected_status: int = 200
    ) -> Dict[str, Any]:
        """
        Make a POST request with JSON payload
        
        Args:
            url: Target URL
            payload: JSON payload to send
            headers: Additional headers
            expected_status: Expected HTTP status code
            
        Returns:
            Response JSON data
            
        Raises:
            HttpError: If request fails or status code doesn't match
        """
        request_headers = self.set_headers(headers)
        
        try:
            async with httpx.AsyncClient(timeout=self.timeout) as client:
                response = await client.post(
                    url,
                    json=payload,
                    headers=request_headers
                )
                
                return self._process_response(response, expected_status)
                
        except httpx.RequestError as e:
            logger.error(f"HTTP request failed for URL {url}: {e}")
            raise HttpError(
                message="HTTP request failed",
                status_code=500,
                details=str(e)
            )
    
    async def do_get_json(
        self,
        url: str,
        headers: Optional[Dict[str, str]] = None,
        expected_status: int = 200
    ) -> Dict[str, Any]:
        """
        Make a GET request and return JSON
        
        Args:
            url: Target URL
            headers: Additional headers
            expected_status: Expected HTTP status code
            
        Returns:
            Response JSON data
            
        Raises:
            HttpError: If request fails or status code doesn't match
        """
        data, _ = await self.do_get_json_with_timing(url, headers, expected_status)
        return data
    
    async def do_get_json_with_timing(
        self,
        url: str,
        headers: Optional[Dict[str, str]] = None,
        expected_status: int = 200
    ) -> Tuple[Dict[str, Any], float]:
        """
        Make a GET request and return JSON
        
        Args:
            url: Target URL
            headers: Additional headers
            expected_status: Expected HTTP status code
            
        Returns:
            Response JSON data
            
        Raises:
            HttpError: If request fails or status code doesn't match
        """
        request_headers = self.set_headers(headers)
        
        try:
            start_time = time.time()
            async with httpx.AsyncClient(timeout=self.timeout) as client:
                response = await client.get(
                    url,
                    headers=request_headers
                )
            response_time = time.time() - start_time
                
            response_data = self._process_response(response, expected_status)
            return response_data, response_time
                
        except httpx.RequestError as e:
            logger.error(f"HTTP request failed for URL {url}: {e}")
            raise HttpError(
                message="HTTP request failed",
                status_code=500,
                details=str(e)
            )
    
    async def do_put_json(
        self,
        url: str,
        payload: Optional[Dict[str, Any]] = None,
        headers: Optional[Dict[str, str]] = None,
        expected_status: int = 200
    ) -> Dict[str, Any]:
        """
        Make a PUT request with JSON payload
        
        Args:
            url: Target URL
            payload: JSON payload to send
            headers: Additional headers
            expected_status: Expected HTTP status code
            
        Returns:
            Response JSON data
            
        Raises:
            HttpError: If request fails or status code doesn't match
        """
        request_headers = self.set_headers(headers)
        
        try:
            async with httpx.AsyncClient(timeout=self.timeout) as client:
                response = await client.put(
                    url,
                    json=payload,
                    headers=request_headers
                )
                
                return self._process_response(response, expected_status)
                
        except httpx.RequestError as e:
            logger.error(f"HTTP request failed for URL {url}: {e}")
            raise HttpError(
                message="HTTP request failed",
                status_code=500,
                details=str(e)
            )
    
    async def do_delete_json(
        self,
        url: str,
        payload: Optional[Dict[str, Any]] = None,
        headers: Optional[Dict[str, str]] = None,
        expected_status: int = 200
    ) -> Dict[str, Any]:
        """
        Make a DELETE request with optional JSON payload
        
        Args:
            url: Target URL
            payload: Optional JSON payload to send
            headers: Additional headers
            expected_status: Expected HTTP status code
            
        Returns:
            Response JSON data
            
        Raises:
            HttpError: If request fails or status code doesn't match
        """
        request_headers = self.set_headers(headers)
        
        try:
            async with httpx.AsyncClient(timeout=self.timeout) as client:
                response = await client.delete(
                    url,
                    json=payload,
                    headers=request_headers
                )
                
                return self._process_response(response, expected_status)
                
        except httpx.RequestError as e:
            logger.error(f"HTTP request failed for URL {url}: {e}")
            raise HttpError(
                message="HTTP request failed",
                status_code=500,
                details=str(e)
            )
    
    def _process_response(self, response: httpx.Response, expected_status: int) -> Dict[str, Any]:
        """
        Process HTTP response and return JSON data
        
        Args:
            response: HTTP response object
            expected_status: Expected status code
            
        Returns:
            Response JSON data
            
        Raises:
            HttpError: If status code doesn't match or JSON parsing fails
        """
        if response.status_code != expected_status:
            error_message = f"Unexpected status code: {response.status_code}"
            try:
                error_body = response.text
                if error_body:
                    error_message = f"{error_message}. Response: {error_body}"
            except:
                pass
            
            raise HttpError(
                message=error_message,
                status_code=response.status_code,
                details=response.text
            )
        
        # Handle empty responses
        if not response.content:
            return {}
        
        try:
            return response.json()
        except ValueError as e:
            raise HttpError(
                message="Failed to parse JSON response",
                status_code=500,
                details=str(e)
            )


# HTTP Utils for common operations
class HttpUtils:
    """Utility functions for HTTP operations"""
    
    @staticmethod
    def extract_bearer_token(request: Request) -> Optional[str]:
        """
        Extract Bearer token from Authorization header
        
        Args:
            request: FastAPI request object
            
        Returns:
            Bearer token string or None if not found
        """
        auth_header = request.headers.get("authorization", "")
        
        if not auth_header.startswith("Bearer "):
            return None
        
        return auth_header.replace("Bearer ", "")
    
    @staticmethod
    def extract_api_access_token(request: Request) -> Optional[str]:
        """
        Extract api_access_token from header (without Bearer prefix)

        Args:
            request: FastAPI request object

        Returns:
            API access token string or None if not found
        """
        # Check for api_access_token header
        token = request.headers.get("api_access_token") or request.headers.get("api-access-token")

        # Also check for x-api-key header (common alternative)
        if not token:
            token = request.headers.get("x-api-key")

        return token if token else None
    
    @staticmethod
    def create_auth_headers(token: str) -> Dict[str, str]:
        """
        Create headers with Authorization token
        
        Args:
            token: Bearer token
            
        Returns:
            Headers dictionary with Authorization
        """
        return {
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Accept": "application/json"
        }
    
    @staticmethod
    def create_api_access_token_headers(token: str) -> Dict[str, str]:
        """
        Create headers with api_access_token (no Bearer prefix)
        
        Args:
            token: API access token
            
        Returns:
            Headers dictionary with api_access_token
        """
        return {
            "api_access_token": token,
            "Content-Type": "application/json",
            "Accept": "application/json"
        }
    
    @staticmethod
    def validate_required_headers(request: Request, required_headers: list) -> None:
        """
        Validate that required headers are present
        
        Args:
            request: FastAPI request object
            required_headers: List of required header names
            
        Raises:
            HTTPException: If required headers are missing
        """
        missing_headers = []
        
        for header in required_headers:
            if header.lower() not in [h.lower() for h in request.headers.keys()]:
                missing_headers.append(header)
        
        if missing_headers:
            raise HTTPException(
                status_code=400,
                detail={
                    "error": "Missing required headers",
                    "code": "ERR_MISSING_HEADERS",
                    "missing_headers": missing_headers
                }
            )
    
    @staticmethod
    async def validate_endpoint_connectivity(
        url: str,
        timeout: float = 10.0,
        expected_status: int = 200,
        headers: Optional[Dict[str, str]] = None
    ) -> Dict[str, Any]:
        """
        Validate endpoint connectivity and return status information
        
        Args:
            url: URL to test
            timeout: Request timeout in seconds
            expected_status: Expected HTTP status code
            headers: Optional headers to send
            
        Returns:
            Dictionary with connectivity status and details
        """
        client = HttpClient(timeout=timeout)
        
        try:
            response_data, response_time = await client.do_get_json_with_timing(
                url=url,
                headers=headers,
                expected_status=expected_status
            )
            
            return {
                "status": "success",
                "url": url,
                "response_time": response_time,
                "status_code": expected_status,
                "reachable": True,
                "message": "Endpoint is reachable",
                "data": response_data
            }
            
        except HttpError as e:
            return {
                "status": "error",
                "url": url,
                "response_time": None,
                "status_code": e.status_code,
                "reachable": False,
                "message": e.message,
                "error": e.details
            }
        except Exception as e:
            return {
                "status": "error",
                "url": url,
                "response_time": None,
                "status_code": None,
                "reachable": False,
                "message": "Connection failed",
                "error": str(e)
            }


# Global HTTP client instance
http_client = HttpClient()

# Convenience functions for common operations
async def post_json(
    url: str,
    payload: Optional[Dict[str, Any]] = None,
    headers: Optional[Dict[str, str]] = None,
    expected_status: int = 200
) -> Dict[str, Any]:
    """Convenience function for POST requests"""
    return await http_client.do_post_json(url, payload, headers, expected_status)

async def get_json(
    url: str,
    headers: Optional[Dict[str, str]] = None,
    expected_status: int = 200
) -> Dict[str, Any]:
    """Convenience function for GET requests"""
    return await http_client.do_get_json(url, headers, expected_status)

async def put_json(
    url: str,
    payload: Optional[Dict[str, Any]] = None,
    headers: Optional[Dict[str, str]] = None,
    expected_status: int = 200
) -> Dict[str, Any]:
    """Convenience function for PUT requests"""
    return await http_client.do_put_json(url, payload, headers, expected_status)

async def delete_json(
    url: str,
    payload: Optional[Dict[str, Any]] = None,
    headers: Optional[Dict[str, str]] = None,
    expected_status: int = 200
) -> Dict[str, Any]:
    """Convenience function for DELETE requests"""
    return await http_client.do_delete_json(url, payload, headers, expected_status)