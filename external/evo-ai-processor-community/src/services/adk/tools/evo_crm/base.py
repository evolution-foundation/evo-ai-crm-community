"""
Base HTTP client for Evo AI CRM API interactions.

This module provides a base client class for making authenticated requests
to the Evo AI CRM API using service token authentication.
"""

import os
import httpx
from typing import Dict, Any, Optional
from src.utils.logger import setup_logger

logger = setup_logger(__name__)


class EvoCrmClient:
    """HTTP client for Evo AI CRM API with service token authentication."""

    def __init__(self):
        """Initialize the Evo CRM client with configuration from environment."""
        self.api_token = os.getenv("EVOAI_CRM_API_TOKEN")
        self.base_url = os.getenv("EVO_AI_CRM_URL", "http://localhost:3000")
        
        if not self.api_token:
            logger.warning(
                "EVOAI_CRM_API_TOKEN not set. CRM tools may not work correctly."
            )
        
        # Remove trailing slash from base_url if present
        self.base_url = self.base_url.rstrip("/")
        
        # Default timeout for requests
        self.timeout = httpx.Timeout(30.0, connect=10.0)
        
        logger.info(f"EvoCrmClient initialized with base_url: {self.base_url}")

    def _get_headers(self, additional_headers: Optional[Dict[str, str]] = None) -> Dict[str, str]:
        """Get default headers with service token authentication.

        Args:
            additional_headers: Optional additional headers to include

        Returns:
            Dictionary with headers including service token
        """
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json",
        }

        if self.api_token:
            headers["X-Service-Token"] = self.api_token
        else:
            logger.warning("No API token available for CRM requests")

        if additional_headers:
            headers.update(additional_headers)

        return headers

    async def _make_request(
        self,
        method: str,
        endpoint: str,
        params: Optional[Dict[str, Any]] = None,
        json_data: Optional[Dict[str, Any]] = None,
    ) -> Dict[str, Any]:
        """Make an authenticated HTTP request to the CRM API.

        Args:
            method: HTTP method (GET, POST, PUT, DELETE)
            endpoint: API endpoint (relative to base_url, should be /api/v1/...)
                     Examples: "/api/v1/contacts/{id}", "/api/v1/conversations/{id}/messages"
            params: Optional query parameters
            json_data: Optional JSON body data

        Returns:
            Response JSON data as dictionary

        Raises:
            httpx.HTTPError: If request fails
            ValueError: If API token is not configured
        """
        if not self.api_token:
            raise ValueError(
                "EVOAI_CRM_API_TOKEN not configured. Cannot make CRM API requests."
            )

        clean_endpoint = endpoint

        # Ensure endpoint starts with /api/v1/
        if not clean_endpoint.startswith("/api/v1/"):
            if clean_endpoint.startswith("/"):
                # Relative path starting with /, prepend /api/v1
                clean_endpoint = f"/api/v1{clean_endpoint}"
            else:
                # No leading slash, add /api/v1/
                clean_endpoint = f"/api/v1/{clean_endpoint}"

        full_url = f"{self.base_url}{clean_endpoint}"

        headers = self._get_headers()

        logger.info(
            f"Making {method} request to CRM API: {full_url}"
            + (f" with params: {params}" if params else "")
            + (f" with body: {json_data}" if json_data else "")
        )
        
        try:
            async with httpx.AsyncClient(timeout=self.timeout) as client:
                response = await client.request(
                    method=method,
                    url=full_url,
                    headers=headers,
                    params=params,
                    json=json_data,
                )
                
                logger.info(
                    f"CRM API response: {response.status_code} - {response.text[:200]}"
                )
                
                # Raise exception for error status codes
                response.raise_for_status()
                
                # Try to parse JSON response
                try:
                    return response.json()
                except Exception:
                    # If not JSON, return text response wrapped in dict
                    return {"content": response.text, "status_code": response.status_code}
                    
        except httpx.HTTPStatusError as e:
            error_detail = f"HTTP {e.response.status_code}"
            try:
                error_body = e.response.json()
                error_detail += f": {error_body}"
            except Exception:
                error_detail += f": {e.response.text[:200]}"
            
            logger.error(f"CRM API request failed: {error_detail}")
            raise httpx.HTTPError(f"CRM API request failed: {error_detail}") from e
            
        except httpx.RequestError as e:
            logger.error(f"CRM API request error: {str(e)}")
            raise httpx.HTTPError(f"CRM API request error: {str(e)}") from e

    async def post(
        self,
        endpoint: str,
        json_data: Optional[Dict[str, Any]] = None,
        params: Optional[Dict[str, Any]] = None,
    ) -> Dict[str, Any]:
        """Make a POST request to the CRM API.

        Args:
            endpoint: API endpoint
            json_data: JSON body data
            params: Optional query parameters

        Returns:
            Response JSON data
        """
        return await self._make_request("POST", endpoint, params, json_data)

    async def get(
        self,
        endpoint: str,
        params: Optional[Dict[str, Any]] = None,
    ) -> Dict[str, Any]:
        """Make a GET request to the CRM API.

        Args:
            endpoint: API endpoint
            params: Optional query parameters

        Returns:
            Response JSON data
        """
        return await self._make_request("GET", endpoint, params)

    async def put(
        self,
        endpoint: str,
        json_data: Optional[Dict[str, Any]] = None,
        params: Optional[Dict[str, Any]] = None,
    ) -> Dict[str, Any]:
        """Make a PUT request to the CRM API.

        Args:
            endpoint: API endpoint
            json_data: JSON body data
            params: Optional query parameters

        Returns:
            Response JSON data
        """
        return await self._make_request("PUT", endpoint, params, json_data)

    async def patch(
        self,
        endpoint: str,
        json_data: Optional[Dict[str, Any]] = None,
        params: Optional[Dict[str, Any]] = None,
    ) -> Dict[str, Any]:
        """Make a PATCH request to the CRM API."""
        return await self._make_request("PATCH", endpoint, params, json_data)

    async def delete(
        self,
        endpoint: str,
        params: Optional[Dict[str, Any]] = None,
    ) -> Dict[str, Any]:
        """Make a DELETE request to the CRM API.

        Args:
            endpoint: API endpoint
            params: Optional query parameters

        Returns:
            Response JSON data
        """
        return await self._make_request("DELETE", endpoint, params)

