"""
Service to fetch global configuration from evo-ai-crm.

This service handles communication with the CRM's global_config API
to retrieve system-wide configuration values like OAuth credentials.
"""

import os
import logging
from typing import Optional, Dict, Any
import httpx

logger = logging.getLogger(__name__)


def _unwrap_envelope(body: Any) -> Dict[str, Any]:
    """Unwrap the CRM's success-response envelope.

    The CRM's service endpoints wrap their payload as
    ``{"success": true, "data": {...}, "meta": {...}}``. The credential
    fields (e.g. ``github_client_id``) live under ``data``, not at the root.
    Reading them off the root silently yields ``None`` for every field.

    Defensive: returns ``body["data"]`` when it's a dict, else the body itself
    (so a hypothetical un-enveloped endpoint keeps working), else ``{}``.
    """
    if isinstance(body, dict):
        inner = body.get("data")
        if isinstance(inner, dict):
            return inner
        return body
    return {}


class GlobalConfigService:
    """Service for fetching global configuration from evo-ai-crm."""

    def __init__(self):
        """Initialize global config service."""
        self.crm_base_url = os.getenv("EVO_AI_CRM_URL") or os.getenv("EVOLUTION_BASE_URL", "http://localhost:3000")
        self.api_token = os.getenv("EVOAI_CRM_API_TOKEN")
        self._config_cache: Optional[Dict[str, Any]] = None

        if not self.api_token:
            logger.warning("EVOAI_CRM_API_TOKEN not configured - global config fetching will fail")

    async def _fetch_all_config(self) -> Dict[str, Any]:
        """
        Fetch all global configuration from CRM.

        The CRM's /api/v1/global_config endpoint returns all configuration
        values in a single JSON object.

        Returns:
            Dictionary containing all global configuration values
        """
        try:
            url = f"{self.crm_base_url}/api/v1/global_config"

            headers = {
                "Authorization": f"Bearer {self.api_token}",
                "Content-Type": "application/json"
            }

            async with httpx.AsyncClient(timeout=10.0) as client:
                response = await client.get(url, headers=headers)

                if response.status_code == 200:
                    config = response.json()
                    logger.info(f"Successfully fetched global config with {len(config)} keys")
                    return config
                else:
                    logger.error(
                        f"Error fetching global config: "
                        f"status={response.status_code}, body={response.text}"
                    )
                    return {}

        except httpx.TimeoutException:
            logger.error("Timeout fetching global config from CRM")
            return {}
        except Exception as e:
            logger.error(f"Error fetching global config: {e}")
            return {}

    async def get_all_config(self, force_refresh: bool = False) -> Dict[str, Any]:
        """
        Get all global configuration, using cache if available.

        Args:
            force_refresh: If True, bypass cache and fetch fresh config

        Returns:
            Dictionary containing all global configuration values
        """
        if self._config_cache is None or force_refresh:
            self._config_cache = await self._fetch_all_config()

        return self._config_cache

    async def get_config(self, key: str) -> Optional[str]:
        """
        Fetch a configuration value from global_config.

        Args:
            key: Configuration key to fetch

        Returns:
            Configuration value or None if not found
        """
        config = await self.get_all_config()
        value = config.get(key)

        if value is None:
            logger.warning(f"Global config key '{key}' not found in CRM")

        return value

    async def get_google_calendar_credentials(self, tenant_id: Optional[str] = None) -> Dict[str, Optional[str]]:
        """
        Fetch Google Calendar OAuth credentials from CRM's service-authenticated endpoint.

        Args:
            tenant_id: Optional tenant id. When present (enterprise), forwarded as
                X-Evo-Tenant-Id so the CRM binds the tenant and resolves the
                BYO (per-tenant) credential. When None (community standalone),
                the header is omitted and the call is a no-op / global resolution.

        Returns:
            Dictionary with client_id, client_secret, and redirect_uri
        """
        try:
            url = f"{self.crm_base_url}/api/v1/integrations/google_calendar/credentials"

            headers = {
                "X-Service-Token": self.api_token,
                "Content-Type": "application/json"
            }
            # Only attach the tenant header when a tenant is bound (enterprise);
            # standalone/community leaves it off (no-op).
            if tenant_id:
                headers["X-Evo-Tenant-Id"] = tenant_id

            async with httpx.AsyncClient(timeout=10.0) as client:
                response = await client.get(url, headers=headers)

                if response.status_code == 200:
                    data = _unwrap_envelope(response.json())
                    client_id = data.get("google_calendar_client_id")
                    client_secret = data.get("google_calendar_client_secret")
                    redirect_uri = data.get("google_calendar_redirect_uri")

                    if not client_id or not client_secret or not redirect_uri:
                        missing = []
                        if not client_id:
                            missing.append("google_calendar_client_id")
                        if not client_secret:
                            missing.append("google_calendar_client_secret")
                        if not redirect_uri:
                            missing.append("google_calendar_redirect_uri")

                        logger.warning(
                            f"Missing Google Calendar credentials in global config: {', '.join(missing)}"
                        )

                    return {
                        "client_id": client_id,
                        "client_secret": client_secret,
                        "redirect_uri": redirect_uri
                    }
                else:
                    logger.error(
                        f"Error fetching Google Calendar credentials: "
                        f"status={response.status_code}, body={response.text}"
                    )
                    return {
                        "client_id": None,
                        "client_secret": None,
                        "redirect_uri": None
                    }

        except httpx.TimeoutException:
            logger.error("Timeout fetching Google Calendar credentials from CRM")
            return {
                "client_id": None,
                "client_secret": None,
                "redirect_uri": None
            }
        except Exception as e:
            logger.error(f"Error fetching Google Calendar credentials: {e}")
            return {
                "client_id": None,
                "client_secret": None,
                "redirect_uri": None
            }

    async def get_google_sheets_credentials(self, tenant_id: Optional[str] = None) -> Dict[str, Optional[str]]:
        """
        Fetch Google Sheets OAuth credentials from CRM's service-authenticated endpoint.

        Args:
            tenant_id: Optional tenant id. When present (enterprise), forwarded as
                X-Evo-Tenant-Id so the CRM binds the tenant and resolves the
                BYO (per-tenant) credential. When None (community standalone),
                the header is omitted and the call is a no-op / global resolution.

        Returns:
            Dictionary with client_id, client_secret, and redirect_uri
        """
        try:
            url = f"{self.crm_base_url}/api/v1/integrations/google_sheets/credentials"

            headers = {
                "X-Service-Token": self.api_token,
                "Content-Type": "application/json"
            }
            # Only attach the tenant header when a tenant is bound (enterprise);
            # standalone/community leaves it off (no-op).
            if tenant_id:
                headers["X-Evo-Tenant-Id"] = tenant_id

            async with httpx.AsyncClient(timeout=10.0) as client:
                response = await client.get(url, headers=headers)

                if response.status_code == 200:
                    data = _unwrap_envelope(response.json())
                    client_id = data.get("google_sheets_client_id")
                    client_secret = data.get("google_sheets_client_secret")
                    redirect_uri = data.get("google_sheets_redirect_uri")

                    if not client_id or not client_secret or not redirect_uri:
                        missing = []
                        if not client_id:
                            missing.append("google_sheets_client_id")
                        if not client_secret:
                            missing.append("google_sheets_client_secret")
                        if not redirect_uri:
                            missing.append("google_sheets_redirect_uri")

                        logger.warning(
                            f"Missing Google Sheets credentials in global config: {', '.join(missing)}"
                        )

                    return {
                        "client_id": client_id,
                        "client_secret": client_secret,
                        "redirect_uri": redirect_uri
                    }
                else:
                    logger.error(
                        f"Error fetching Google Sheets credentials: "
                        f"status={response.status_code}, body={response.text}"
                    )
                    return {
                        "client_id": None,
                        "client_secret": None,
                        "redirect_uri": None
                    }

        except httpx.TimeoutException:
            logger.error("Timeout fetching Google Sheets credentials from CRM")
            return {
                "client_id": None,
                "client_secret": None,
                "redirect_uri": None
            }
        except Exception as e:
            logger.error(f"Error fetching Google Sheets credentials: {e}")
            return {
                "client_id": None,
                "client_secret": None,
                "redirect_uri": None
            }

    async def get_github_credentials(self, tenant_id: Optional[str] = None) -> Dict[str, Optional[str]]:
        """
        Fetch GitHub OAuth credentials from CRM's service-authenticated endpoint.

        Args:
            tenant_id: Optional tenant id. When present (enterprise), forwarded as
                X-Evo-Tenant-Id so the CRM binds the tenant and resolves the
                BYO (per-tenant) credential. When None (community standalone),
                the header is omitted and the call is a no-op / global resolution.

        Returns:
            Dictionary with client_id, client_secret, and redirect_uri
        """
        try:
            url = f"{self.crm_base_url}/api/v1/integrations/github/credentials"

            headers = {
                "X-Service-Token": self.api_token,
                "Content-Type": "application/json"
            }
            # Only attach the tenant header when a tenant is bound (enterprise);
            # standalone/community leaves it off (no-op).
            if tenant_id:
                headers["X-Evo-Tenant-Id"] = tenant_id

            async with httpx.AsyncClient(timeout=10.0) as client:
                response = await client.get(url, headers=headers)

                if response.status_code == 200:
                    data = _unwrap_envelope(response.json())
                    client_id = data.get("github_client_id")
                    client_secret = data.get("github_client_secret")
                    redirect_uri = data.get("github_redirect_uri")

                    if not client_id or not client_secret or not redirect_uri:
                        missing = []
                        if not client_id:
                            missing.append("github_client_id")
                        if not client_secret:
                            missing.append("github_client_secret")
                        if not redirect_uri:
                            missing.append("github_redirect_uri")

                        logger.warning(
                            f"Missing GitHub credentials in global config: {', '.join(missing)}"
                        )

                    return {
                        "client_id": client_id,
                        "client_secret": client_secret,
                        "redirect_uri": redirect_uri
                    }
                else:
                    logger.error(
                        f"Error fetching GitHub credentials: "
                        f"status={response.status_code}, body={response.text}"
                    )
                    return {
                        "client_id": None,
                        "client_secret": None,
                        "redirect_uri": None
                    }

        except httpx.TimeoutException:
            logger.error("Timeout fetching GitHub credentials from CRM")
            return {
                "client_id": None,
                "client_secret": None,
                "redirect_uri": None
            }
        except Exception as e:
            logger.error(f"Error fetching GitHub credentials: {e}")
            return {
                "client_id": None,
                "client_secret": None,
                "redirect_uri": None
            }

    async def get_notion_credentials(self, tenant_id: Optional[str] = None) -> Dict[str, Optional[str]]:
        """
        Fetch Notion OAuth credentials from CRM's service-authenticated endpoint.

        Args:
            tenant_id: Optional tenant id. When present (enterprise), forwarded as
                X-Evo-Tenant-Id so the CRM binds the tenant and resolves the
                BYO (per-tenant) credential. When None (community standalone),
                the header is omitted and the call is a no-op / global resolution.

        Returns:
            Dictionary with client_id, client_secret, and redirect_uri
        """
        try:
            url = f"{self.crm_base_url}/api/v1/integrations/notion/credentials"

            headers = {
                "X-Service-Token": self.api_token,
                "Content-Type": "application/json"
            }
            # Only attach the tenant header when a tenant is bound (enterprise);
            # standalone/community leaves it off (no-op).
            if tenant_id:
                headers["X-Evo-Tenant-Id"] = tenant_id

            async with httpx.AsyncClient(timeout=10.0) as client:
                response = await client.get(url, headers=headers)

                if response.status_code == 200:
                    data = _unwrap_envelope(response.json())
                    client_id = data.get("notion_client_id")
                    client_secret = data.get("notion_client_secret")
                    redirect_uri = data.get("notion_redirect_uri")

                    logger.info(
                        f"Notion credentials loaded from CRM: "
                        f"client_id={'present' if client_id else 'None'}, "
                        f"client_secret={'present' if client_secret else 'None'}, "
                        f"redirect_uri={'present' if redirect_uri else 'None'}"
                    )

                    if not redirect_uri:
                        logger.warning(
                            "Missing Notion redirect_uri in global config. "
                            "Note: client_id and client_secret are optional and will be obtained via dynamic registration."
                        )

                    return {
                        "client_id": client_id,
                        "client_secret": client_secret,
                        "redirect_uri": redirect_uri
                    }
                else:
                    logger.error(
                        f"Error fetching Notion credentials: "
                        f"status={response.status_code}, body={response.text}"
                    )
                    return {
                        "client_id": None,
                        "client_secret": None,
                        "redirect_uri": None
                    }

        except httpx.TimeoutException:
            logger.error("Timeout fetching Notion credentials from CRM")
            return {
                "client_id": None,
                "client_secret": None,
                "redirect_uri": None
            }
        except Exception as e:
            logger.error(f"Error fetching Notion credentials: {e}")
            return {
                "client_id": None,
                "client_secret": None,
                "redirect_uri": None
            }

    async def get_stripe_credentials(self, tenant_id: Optional[str] = None) -> Dict[str, Optional[str]]:
        """
        Fetch Stripe OAuth credentials from CRM's service-authenticated endpoint.

        Args:
            tenant_id: Optional tenant id. When present (enterprise), forwarded as
                X-Evo-Tenant-Id so the CRM binds the tenant and resolves the
                BYO (per-tenant) credential. When None (community standalone),
                the header is omitted and the call is a no-op / global resolution.

        Returns:
            Dictionary with client_id, client_secret, redirect_uri, and authorization_url
        """
        try:
            url = f"{self.crm_base_url}/api/v1/integrations/stripe/credentials"

            headers = {
                "X-Service-Token": self.api_token,
                "Content-Type": "application/json"
            }
            # Only attach the tenant header when a tenant is bound (enterprise);
            # standalone/community leaves it off (no-op).
            if tenant_id:
                headers["X-Evo-Tenant-Id"] = tenant_id

            async with httpx.AsyncClient(timeout=10.0) as client:
                response = await client.get(url, headers=headers)

                if response.status_code == 200:
                    data = _unwrap_envelope(response.json())
                    client_id = data.get("stripe_client_id")
                    client_secret = data.get("stripe_client_secret")
                    redirect_uri = data.get("stripe_redirect_uri")
                    authorization_url = data.get("stripe_authorization_url")

                    if not redirect_uri:
                        logger.warning(
                            "Missing Stripe redirect_uri in global config. "
                            "Note: client_id and client_secret are optional and will be obtained via dynamic registration."
                        )

                    return {
                        "client_id": client_id,
                        "client_secret": client_secret,
                        "redirect_uri": redirect_uri,
                        "authorization_url": authorization_url
                    }
                else:
                    logger.error(
                        f"Error fetching Stripe credentials: "
                        f"status={response.status_code}, body={response.text}"
                    )
                    return {
                        "client_id": None,
                        "client_secret": None,
                        "redirect_uri": None
                    }

        except httpx.TimeoutException:
            logger.error("Timeout fetching Stripe credentials from CRM")
            return {
                "client_id": None,
                "client_secret": None,
                "redirect_uri": None
            }
        except Exception as e:
            logger.error(f"Error fetching Stripe credentials: {e}")
            return {
                "client_id": None,
                "client_secret": None,
                "redirect_uri": None
            }

    async def get_monday_credentials(self, tenant_id: Optional[str] = None) -> Dict[str, Optional[str]]:
        """
        Fetch Monday OAuth credentials from CRM's service-authenticated endpoint.

        Args:
            tenant_id: Optional tenant id. When present (enterprise), forwarded as
                X-Evo-Tenant-Id so the CRM binds the tenant and resolves the
                BYO (per-tenant) credential. When None (community standalone),
                the header is omitted and the call is a no-op / global resolution.

        Returns:
            Dictionary with client_id, client_secret, and redirect_uri
        """
        try:
            url = f"{self.crm_base_url}/api/v1/integrations/monday/credentials"

            headers = {
                "X-Service-Token": self.api_token,
                "Content-Type": "application/json"
            }
            # Only attach the tenant header when a tenant is bound (enterprise);
            # standalone/community leaves it off (no-op).
            if tenant_id:
                headers["X-Evo-Tenant-Id"] = tenant_id

            async with httpx.AsyncClient(timeout=10.0) as client:
                response = await client.get(url, headers=headers)

                if response.status_code == 200:
                    data = _unwrap_envelope(response.json())
                    client_id = data.get("monday_client_id")
                    client_secret = data.get("monday_client_secret")
                    redirect_uri = data.get("monday_redirect_uri")

                    if not redirect_uri:
                        logger.warning(
                            "Missing Monday redirect_uri in global config. "
                            "Note: client_id and client_secret are optional and will be obtained via dynamic registration."
                        )

                    return {
                        "client_id": client_id,
                        "client_secret": client_secret,
                        "redirect_uri": redirect_uri
                    }
                else:
                    logger.error(
                        f"Error fetching Monday credentials: "
                        f"status={response.status_code}, body={response.text}"
                    )
                    return {
                        "client_id": None,
                        "client_secret": None,
                        "redirect_uri": None
                    }

        except httpx.TimeoutException:
            logger.error("Timeout fetching Monday credentials from CRM")
            return {
                "client_id": None,
                "client_secret": None,
                "redirect_uri": None
            }
        except Exception as e:
            logger.error(f"Error fetching Monday credentials: {e}")
            return {
                "client_id": None,
                "client_secret": None,
                "redirect_uri": None
            }

    async def get_atlassian_credentials(self, tenant_id: Optional[str] = None) -> Dict[str, Optional[str]]:
        """
        Fetch Atlassian OAuth credentials from CRM's service-authenticated endpoint.

        Args:
            tenant_id: Optional tenant id. When present (enterprise), forwarded as
                X-Evo-Tenant-Id so the CRM binds the tenant and resolves the
                BYO (per-tenant) credential. When None (community standalone),
                the header is omitted and the call is a no-op / global resolution.

        Returns:
            Dictionary with client_id, client_secret, and redirect_uri
        """
        try:
            url = f"{self.crm_base_url}/api/v1/integrations/atlassian/credentials"

            headers = {
                "X-Service-Token": self.api_token,
                "Content-Type": "application/json"
            }
            # Only attach the tenant header when a tenant is bound (enterprise);
            # standalone/community leaves it off (no-op).
            if tenant_id:
                headers["X-Evo-Tenant-Id"] = tenant_id

            async with httpx.AsyncClient(timeout=10.0) as client:
                response = await client.get(url, headers=headers)

                if response.status_code == 200:
                    data = _unwrap_envelope(response.json())
                    client_id = data.get("atlassian_client_id")
                    client_secret = data.get("atlassian_client_secret")
                    redirect_uri = data.get("atlassian_redirect_uri")

                    if not redirect_uri:
                        logger.warning(
                            "Missing Atlassian redirect_uri in global config. "
                            "Note: client_id and client_secret are optional and will be obtained via dynamic registration."
                        )

                    return {
                        "client_id": client_id,
                        "client_secret": client_secret,
                        "redirect_uri": redirect_uri
                    }
                else:
                    logger.error(
                        f"Error fetching Atlassian credentials: "
                        f"status={response.status_code}, body={response.text}"
                    )
                    return {
                        "client_id": None,
                        "client_secret": None,
                        "redirect_uri": None
                    }

        except httpx.TimeoutException:
            logger.error("Timeout fetching Atlassian credentials from CRM")
            return {
                "client_id": None,
                "client_secret": None,
                "redirect_uri": None
            }
        except Exception as e:
            logger.error(f"Error fetching Atlassian credentials: {e}")
            return {
                "client_id": None,
                "client_secret": None,
                "redirect_uri": None
            }

    async def get_asana_credentials(self, tenant_id: Optional[str] = None) -> Dict[str, Optional[str]]:
        """
        Fetch Asana OAuth credentials from CRM's service-authenticated endpoint.

        Args:
            tenant_id: Optional tenant id. When present (enterprise), forwarded as
                X-Evo-Tenant-Id so the CRM binds the tenant and resolves the
                BYO (per-tenant) credential. When None (community standalone),
                the header is omitted and the call is a no-op / global resolution.

        Returns:
            Dictionary with client_id, client_secret, and redirect_uri
        """
        try:
            url = f"{self.crm_base_url}/api/v1/integrations/asana/credentials"

            headers = {
                "X-Service-Token": self.api_token,
                "Content-Type": "application/json"
            }
            # Only attach the tenant header when a tenant is bound (enterprise);
            # standalone/community leaves it off (no-op).
            if tenant_id:
                headers["X-Evo-Tenant-Id"] = tenant_id

            async with httpx.AsyncClient(timeout=10.0) as client:
                response = await client.get(url, headers=headers)

                if response.status_code == 200:
                    data = _unwrap_envelope(response.json())
                    client_id = data.get("asana_client_id")
                    client_secret = data.get("asana_client_secret")
                    redirect_uri = data.get("asana_redirect_uri")

                    if not redirect_uri:
                        logger.warning(
                            "Missing Asana redirect_uri in global config. "
                            "Note: client_id and client_secret are optional and will be obtained via dynamic registration."
                        )

                    return {
                        "client_id": client_id,
                        "client_secret": client_secret,
                        "redirect_uri": redirect_uri
                    }
                else:
                    logger.error(
                        f"Error fetching Asana credentials: "
                        f"status={response.status_code}, body={response.text}"
                    )
                    return {
                        "client_id": None,
                        "client_secret": None,
                        "redirect_uri": None
                    }

        except httpx.TimeoutException:
            logger.error("Timeout fetching Asana credentials from CRM")
            return {
                "client_id": None,
                "client_secret": None,
                "redirect_uri": None
            }
        except Exception as e:
            logger.error(f"Error fetching Asana credentials: {e}")
            return {
                "client_id": None,
                "client_secret": None,
                "redirect_uri": None
            }

    async def get_hubspot_credentials(self, tenant_id: Optional[str] = None) -> Dict[str, Optional[str]]:
        """
        Fetch HubSpot OAuth credentials from CRM's service-authenticated endpoint.

        Args:
            tenant_id: Optional tenant id. When present (enterprise), forwarded as
                X-Evo-Tenant-Id so the CRM binds the tenant and resolves the
                BYO (per-tenant) credential. When None (community standalone),
                the header is omitted and the call is a no-op / global resolution.

        Returns:
            Dictionary with client_id, client_secret, and redirect_uri
        """
        try:
            url = f"{self.crm_base_url}/api/v1/integrations/hubspot/credentials"

            headers = {
                "X-Service-Token": self.api_token,
                "Content-Type": "application/json"
            }
            # Only attach the tenant header when a tenant is bound (enterprise);
            # standalone/community leaves it off (no-op).
            if tenant_id:
                headers["X-Evo-Tenant-Id"] = tenant_id

            async with httpx.AsyncClient(timeout=10.0) as client:
                response = await client.get(url, headers=headers)

                if response.status_code == 200:
                    data = _unwrap_envelope(response.json())
                    client_id = data.get("hubspot_client_id")
                    client_secret = data.get("hubspot_client_secret")
                    redirect_uri = data.get("hubspot_redirect_uri")

                    # Normalize empty strings to None
                    client_id = client_id if client_id and client_id.strip() else None
                    client_secret = client_secret if client_secret and client_secret.strip() else None
                    redirect_uri = redirect_uri if redirect_uri and redirect_uri.strip() else None

                    logger.info(
                        f"HubSpot credentials from global config: "
                        f"client_id={'present' if client_id else 'MISSING'} "
                        f"(length: {len(client_id) if client_id else 0}), "
                        f"client_secret={'present' if client_secret else 'MISSING'} "
                        f"(length: {len(client_secret) if client_secret else 0}), "
                        f"redirect_uri={'present' if redirect_uri else 'MISSING'}"
                    )

                    if not client_id or not client_secret or not redirect_uri:
                        missing = []
                        if not client_id:
                            missing.append("hubspot_client_id")
                        if not client_secret:
                            missing.append("hubspot_client_secret")
                        if not redirect_uri:
                            missing.append("hubspot_redirect_uri")

                        logger.warning(
                            f"Missing HubSpot credentials in global config: {', '.join(missing)}"
                        )

                    return {
                        "client_id": client_id,
                        "client_secret": client_secret,
                        "redirect_uri": redirect_uri
                    }
                else:
                    logger.error(
                        f"Error fetching HubSpot credentials: "
                        f"status={response.status_code}, body={response.text}"
                    )
                    return {
                        "client_id": None,
                        "client_secret": None,
                        "redirect_uri": None
                    }

        except httpx.TimeoutException:
            logger.error("Timeout fetching HubSpot credentials from CRM")
            return {
                "client_id": None,
                "client_secret": None,
                "redirect_uri": None
            }
        except Exception as e:
            logger.error(f"Error fetching HubSpot credentials: {e}")
            return {
                "client_id": None,
                "client_secret": None,
                "redirect_uri": None
            }

    async def get_linear_credentials(self, tenant_id: Optional[str] = None) -> Dict[str, Optional[str]]:
        """
        Fetch Linear OAuth credentials from CRM's service-authenticated endpoint.

        Args:
            tenant_id: Optional tenant id. When present (enterprise), forwarded as
                X-Evo-Tenant-Id so the CRM binds the tenant and resolves the
                BYO (per-tenant) credential. When None (community standalone),
                the header is omitted and the call is a no-op / global resolution.

        Returns:
            Dictionary with client_id, client_secret, and redirect_uri
        """
        try:
            url = f"{self.crm_base_url}/api/v1/integrations/linear/credentials"

            headers = {
                "X-Service-Token": self.api_token,
                "Content-Type": "application/json"
            }
            # Only attach the tenant header when a tenant is bound (enterprise);
            # standalone/community leaves it off (no-op).
            if tenant_id:
                headers["X-Evo-Tenant-Id"] = tenant_id

            async with httpx.AsyncClient(timeout=10.0) as client:
                response = await client.get(url, headers=headers)

                if response.status_code == 200:
                    data = _unwrap_envelope(response.json())
                    client_id = data.get("linear_client_id")
                    client_secret = data.get("linear_client_secret")
                    redirect_uri = data.get("linear_redirect_uri")

                    if not redirect_uri:
                        logger.warning(
                            "Missing Linear redirect_uri in global config. "
                            "Note: client_id and client_secret are optional and will be obtained via dynamic registration."
                        )

                    return {
                        "client_id": client_id,
                        "client_secret": client_secret,
                        "redirect_uri": redirect_uri
                    }
                else:
                    logger.error(
                        f"Error fetching Linear credentials: "
                        f"status={response.status_code}, body={response.text}"
                    )
                    return {
                        "client_id": None,
                        "client_secret": None,
                        "redirect_uri": None
                    }

        except httpx.TimeoutException:
            logger.error("Timeout fetching Linear credentials from CRM")
            return {
                "client_id": None,
                "client_secret": None,
                "redirect_uri": None
            }
        except Exception as e:
            logger.error(f"Error fetching Linear credentials: {e}")
            return {
                "client_id": None,
                "client_secret": None,
                "redirect_uri": None
            }

    async def get_paypal_credentials(self, tenant_id: Optional[str] = None) -> Dict[str, Optional[str]]:
        """
        Fetch PayPal OAuth credentials from CRM's service-authenticated endpoint.

        Args:
            tenant_id: Optional tenant id. When present (enterprise), forwarded as
                X-Evo-Tenant-Id so the CRM binds the tenant and resolves the
                BYO (per-tenant) credential. When None (community standalone),
                the header is omitted and the call is a no-op / global resolution.

        Returns:
            Dictionary with client_id, client_secret, and redirect_uri
        """
        try:
            url = f"{self.crm_base_url}/api/v1/integrations/paypal/credentials"

            headers = {
                "X-Service-Token": self.api_token,
                "Content-Type": "application/json"
            }
            # Only attach the tenant header when a tenant is bound (enterprise);
            # standalone/community leaves it off (no-op).
            if tenant_id:
                headers["X-Evo-Tenant-Id"] = tenant_id

            async with httpx.AsyncClient(timeout=10.0) as client:
                response = await client.get(url, headers=headers)

                if response.status_code == 200:
                    data = _unwrap_envelope(response.json())
                    client_id = data.get("paypal_client_id")
                    client_secret = data.get("paypal_client_secret")
                    redirect_uri = data.get("paypal_redirect_uri")
                    environment = data.get("paypal_environment")  # Optional: "sandbox" or "production"

                    if not client_id or not client_secret or not redirect_uri:
                        logger.warning(
                            "Missing PayPal OAuth credentials in global config: "
                            f"client_id={'missing' if not client_id else 'present'}, "
                            f"client_secret={'missing' if not client_secret else 'present'}, "
                            f"redirect_uri={'missing' if not redirect_uri else 'present'}"
                        )

                    return {
                        "client_id": client_id,
                        "client_secret": client_secret,
                        "redirect_uri": redirect_uri,
                        "environment": environment
                    }
                else:
                    logger.error(
                        f"Error fetching PayPal credentials: "
                        f"status={response.status_code}, body={response.text}"
                    )
                    return {
                        "client_id": None,
                        "client_secret": None,
                        "redirect_uri": None
                    }

        except httpx.TimeoutException:
            logger.error("Timeout fetching PayPal credentials from CRM")
            return {
                "client_id": None,
                "client_secret": None,
                "redirect_uri": None
            }
        except Exception as e:
            logger.error(f"Error fetching PayPal credentials: {e}")
            return {
                "client_id": None,
                "client_secret": None,
                "redirect_uri": None
            }

    async def get_canva_credentials(self, tenant_id: Optional[str] = None) -> Dict[str, Optional[str]]:
        """
        Fetch Canva OAuth credentials from CRM's service-authenticated endpoint.

        Args:
            tenant_id: Optional tenant id. When present (enterprise), forwarded as
                X-Evo-Tenant-Id so the CRM binds the tenant and resolves the
                BYO (per-tenant) credential. When None (community standalone),
                the header is omitted and the call is a no-op / global resolution.

        Returns:
            Dictionary with client_id, client_secret, and redirect_uri
        """
        try:
            url = f"{self.crm_base_url}/api/v1/integrations/canva/credentials"

            headers = {
                "X-Service-Token": self.api_token,
                "Content-Type": "application/json"
            }
            # Only attach the tenant header when a tenant is bound (enterprise);
            # standalone/community leaves it off (no-op).
            if tenant_id:
                headers["X-Evo-Tenant-Id"] = tenant_id

            async with httpx.AsyncClient(timeout=10.0) as client:
                response = await client.get(url, headers=headers)

                if response.status_code == 200:
                    data = _unwrap_envelope(response.json())
                    client_id = data.get("canva_client_id")
                    client_secret = data.get("canva_client_secret")
                    redirect_uri = data.get("canva_redirect_uri")

                    if not redirect_uri:
                        logger.warning(
                            "Missing Canva redirect_uri in global config. "
                            "Note: client_id and client_secret are optional and will be obtained via dynamic registration."
                        )

                    return {
                        "client_id": client_id,
                        "client_secret": client_secret,
                        "redirect_uri": redirect_uri
                    }
                else:
                    logger.error(
                        f"Error fetching Canva credentials: "
                        f"status={response.status_code}, body={response.text}"
                    )
                    return {
                        "client_id": None,
                        "client_secret": None,
                        "redirect_uri": None
                    }

        except httpx.TimeoutException:
            logger.error("Timeout fetching Canva credentials from CRM")
            return {
                "client_id": None,
                "client_secret": None,
                "redirect_uri": None
            }
        except Exception as e:
            logger.error(f"Error fetching Canva credentials: {e}")
            return {
                "client_id": None,
                "client_secret": None,
                "redirect_uri": None
            }

    async def get_supabase_credentials(self, tenant_id: Optional[str] = None) -> Dict[str, Optional[str]]:
        """
        Fetch Supabase OAuth credentials from CRM's service-authenticated endpoint.

        Args:
            tenant_id: Optional tenant id. When present (enterprise), forwarded as
                X-Evo-Tenant-Id so the CRM binds the tenant. Supabase carries only
                a redirect_uri (no BYO client_id/secret), so this is forwarded for
                consistency with the other providers; standalone leaves it off.

        Returns:
            Dictionary with redirect_uri only
            Note: Supabase OAuth only requires redirect_uri, no client_id/secret needed
            Authorization URL and MCP endpoint are hardcoded
        """
        try:
            url = f"{self.crm_base_url}/api/v1/integrations/supabase/credentials"

            headers = {
                "X-Service-Token": self.api_token,
                "Content-Type": "application/json"
            }
            # Only attach the tenant header when a tenant is bound (enterprise);
            # standalone/community leaves it off (no-op).
            if tenant_id:
                headers["X-Evo-Tenant-Id"] = tenant_id

            async with httpx.AsyncClient(timeout=10.0) as client:
                response = await client.get(url, headers=headers)

                if response.status_code == 200:
                    data = _unwrap_envelope(response.json())
                    redirect_uri = data.get("supabase_redirect_uri")

                    logger.info(
                        f"Supabase credentials loaded from CRM: "
                        f"redirect_uri={'present' if redirect_uri else 'None'}"
                    )

                    if not redirect_uri:
                        logger.warning(
                            "Missing Supabase redirect_uri in global config. "
                            "Note: Supabase OAuth only requires redirect_uri, no client_id/secret needed."
                        )

                    return {
                        "redirect_uri": redirect_uri
                    }
                else:
                    logger.error(
                        f"Error fetching Supabase credentials: "
                        f"status={response.status_code}, body={response.text}"
                    )
                    return {
                        "redirect_uri": None
                    }

        except httpx.TimeoutException:
            logger.error("Timeout fetching Supabase credentials from CRM")
            return {
                "redirect_uri": None
            }
        except Exception as e:
            logger.error(f"Error fetching Supabase credentials: {e}")
            return {
                "redirect_uri": None
            }


# Global instance
_global_config_service: Optional[GlobalConfigService] = None


def get_global_config_service() -> GlobalConfigService:
    """Get or create global config service instance."""
    global _global_config_service

    if _global_config_service is None:
        _global_config_service = GlobalConfigService()

    return _global_config_service
