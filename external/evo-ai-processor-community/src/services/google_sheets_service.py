"""
Google Sheets OAuth and API integration service.

This service handles:
- OAuth 2.0 authorization flow
- Token management and refresh
- Spreadsheet listing and operations
- Configuration storage
"""

import json
import logging
import os
from typing import Optional, Dict, Any, List
from datetime import datetime, timedelta

import httpx
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import Flow
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError

logger = logging.getLogger(__name__)


class GoogleSheetsService:
    """Service for Google Sheets OAuth and API operations."""

    # OAuth 2.0 scopes required for Sheets integration
    SCOPES = [
        'https://www.googleapis.com/auth/spreadsheets',
        'https://www.googleapis.com/auth/drive.readonly',
        'openid',
        'email',
        'profile'
    ]

    def __init__(
        self,
        client_id: str,
        client_secret: str,
        redirect_uri: str,
        core_service_url: str,
        user_token: str
    ):
        """
        Initialize Google Sheets service.

        Args:
            client_id: Google OAuth client ID
            client_secret: Google OAuth client secret
            redirect_uri: OAuth redirect URI
            core_service_url: Base URL for evo-ai-core-service API
            user_token: User authentication token for API calls
        """
        self.client_id = client_id
        self.client_secret = client_secret
        self.redirect_uri = redirect_uri
        self.core_service_url = core_service_url.rstrip('/')
        self.user_token = user_token
        self.http_client = httpx.AsyncClient(
            headers={"Authorization": f"Bearer {user_token}"},
            timeout=30.0
        )

    def generate_authorization_url(
        self,
        agent_id: str,
        email: Optional[str] = None
    ) -> str:
        """
        Generate OAuth 2.0 authorization URL.

        Args:
            agent_id: Agent ID
            email: Optional email hint for OAuth flow

        Returns:
            Authorization URL for user to visit
        """
        # Log the redirect_uri being used
        logger.info(f"Authorization URL generation - redirect_uri: {self.redirect_uri}")

        # Create flow instance
        flow = Flow.from_client_config(
            {
                "web": {
                    "client_id": self.client_id,
                    "client_secret": self.client_secret,
                    "auth_uri": "https://accounts.google.com/o/oauth2/auth",
                    "token_uri": "https://oauth2.googleapis.com/token",
                    "redirect_uris": [self.redirect_uri],
                }
            },
            scopes=self.SCOPES,
            redirect_uri=self.redirect_uri
        )

        # Create state parameter with account and agent IDs
        # We'll use a simple JWT-like encoding
        import base64
        state_data = {
            "agent_id": agent_id,
            "timestamp": datetime.utcnow().isoformat()
        }
        state = base64.urlsafe_b64encode(
            json.dumps(state_data).encode()
        ).decode()

        # Generate authorization URL
        authorization_url, _ = flow.authorization_url(
            access_type='offline',
            include_granted_scopes='true',
            state=state,
            prompt='consent',
            login_hint=email if email else None
        )

        return authorization_url

    async def complete_authorization(
        self,
        agent_id: str,
        code: str,
        state: str,
        db: Optional[Any] = None
    ) -> Dict[str, Any]:
        """
        Complete OAuth authorization flow and store tokens.

        Args:
            agent_id: Agent ID
            code: Authorization code from OAuth callback
            state: State parameter from OAuth callback

        Returns:
            Dictionary with success status, email, and spreadsheets
        """
        try:
            # Verify state parameter
            import base64
            state_data = json.loads(
                base64.urlsafe_b64decode(state.encode()).decode()
            )

            if state_data.get('agent_id') != agent_id:
                raise ValueError("Invalid state parameter")

            # Manual token exchange without scope validation
            # Google may return normalized scopes (e.g., "email" -> "userinfo.email")
            # or additional scopes configured in Cloud Console, so we skip
            # the library's strict scope validation and do the exchange ourselves
            import requests

            logger.info(f"Token exchange - client_id: {self.client_id[:20]}...")
            logger.info(f"Token exchange - redirect_uri: {self.redirect_uri}")
            logger.info(f"Token exchange - code (first 30 chars): {code[:30]}...")

            token_response = requests.post(
                "https://oauth2.googleapis.com/token",
                data={
                    "code": code,
                    "client_id": self.client_id,
                    "client_secret": self.client_secret,
                    "redirect_uri": self.redirect_uri,
                    "grant_type": "authorization_code"
                }
            )

            logger.info(f"Token exchange response status: {token_response.status_code}")
            logger.info(f"Token exchange response: {token_response.text[:200]}")

            if token_response.status_code != 200:
                raise Exception(f"Token exchange failed: {token_response.text}")

            token_data = token_response.json()

            # Create credentials from token response
            credentials = Credentials(
                token=token_data["access_token"],
                refresh_token=token_data.get("refresh_token"),
                token_uri="https://oauth2.googleapis.com/token",
                client_id=self.client_id,
                client_secret=self.client_secret,
                scopes=token_data.get("scope", "").split()
            )

            # Decode ID token to get user info
            import jwt
            email = None
            id_token = token_data.get("id_token")
            if id_token:
                # Decode without verification (we trust Google's token)
                id_info = jwt.decode(id_token, options={"verify_signature": False})
                email = id_info.get('email')

            # Store credentials in database
            await self._store_credentials(agent_id, credentials, email, db=db)

            # Fetch available spreadsheets
            spreadsheets = await self.get_spreadsheets(agent_id, db=db)

            return {
                "success": True,
                "email": email,
                "spreadsheets": spreadsheets
            }

        except Exception as e:
            logger.error(f"Error completing Google Sheets authorization: {e}")
            return {
                "success": False,
                "error": str(e)
            }

    async def get_spreadsheets(
        self,
        agent_id: str,
        db: Optional[Any] = None
    ) -> List[Dict[str, Any]]:
        """
        Get list of available Google Sheets spreadsheets for the user.

        Args:
            agent_id: Agent ID
            db: Optional database session

        Returns:
            List of spreadsheet dictionaries
        """
        try:
            logger.info(f"get_spreadsheets called with db={bool(db)}")
            credentials = await self._load_credentials(agent_id, db=db)
            logger.info(f"Credentials loaded: token={bool(credentials.token) if credentials else None}, refresh={bool(credentials.refresh_token) if credentials else None}")
            if not credentials:
                raise ValueError("No credentials found")

            # Build Drive API service to list spreadsheets
            service = build('drive', 'v3', credentials=credentials)

            # List spreadsheets (Google Sheets files)
            # Query for files with mimeType application/vnd.google-apps.spreadsheet
            results = service.files().list(
                q="mimeType='application/vnd.google-apps.spreadsheet'",
                pageSize=100,
                fields="files(id, name, webViewLink)",
                orderBy="modifiedTime desc"
            ).execute()

            spreadsheets = []
            for file in results.get('files', []):
                spreadsheets.append({
                    "id": file['id'],
                    "name": file['name'],
                    "url": file.get('webViewLink', ''),
                    "selected": False
                })

            return spreadsheets

        except HttpError as e:
            logger.error(f"Error fetching spreadsheets: {e}")
            raise
        except Exception as e:
            logger.error(f"Error getting spreadsheets: {e}")
            raise

    async def save_configuration(
        self,
        agent_id: str,
        config: Dict[str, Any]
    ) -> bool:
        """
        Save Google Sheets configuration.

        Args:
            agent_id: Agent ID
            config: Configuration dictionary

        Returns:
            Success status
        """
        try:
            # Store configuration via evo-ai-core API
            url = f"{self.core_service_url}/agents/{agent_id}/integrations"

            response = await self.http_client.post(
                url,
                json={
                    "provider": "google_sheets",
                    "config": config
                }
            )

            response.raise_for_status()
            return True

        except Exception as e:
            logger.error(f"Error saving Google Sheets configuration: {e}")
            raise

    async def get_configuration(
        self,
        agent_id: str
    ) -> Optional[Dict[str, Any]]:
        """
        Get Google Sheets configuration.

        Args:
            agent_id: Agent ID

        Returns:
            Configuration dictionary or None
        """
        try:
            # Get configuration via evo-ai-core API
            url = f"{self.core_service_url}/agents/{agent_id}/integrations/google_sheets"

            response = await self.http_client.get(url)

            if response.status_code == 404:
                return None

            response.raise_for_status()
            data = response.json()
            return data.get('config')

        except httpx.HTTPStatusError as e:
            if e.response.status_code == 404:
                return None
            logger.error(f"Error getting Google Sheets configuration: {e}")
            raise
        except Exception as e:
            logger.error(f"Error getting Google Sheets configuration: {e}")
            raise

    async def disconnect(
        self,
        agent_id: str
    ) -> bool:
        """
        Disconnect Google Sheets integration.

        Args:
            agent_id: Agent ID

        Returns:
            Success status
        """
        try:
            # Revoke tokens
            credentials = await self._load_credentials(agent_id)
            if credentials and credentials.token:
                try:
                    from google.auth.transport.requests import Request
                    credentials.revoke(Request())
                except Exception as e:
                    logger.warning(f"Error revoking token: {e}")

            # Delete credentials and configuration via evo-ai-core API
            for provider in ['google_sheets', 'google_sheets_credentials']:
                url = f"{self.core_service_url}/agents/{agent_id}/integrations/{provider}"
                try:
                    response = await self.http_client.delete(url)
                    response.raise_for_status()
                except httpx.HTTPStatusError as e:
                    if e.response.status_code != 404:
                        raise

            return True

        except Exception as e:
            logger.error(f"Error disconnecting Google Sheets: {e}")
            raise

    async def read_spreadsheet(
        self,
        agent_id: str,
        spreadsheet_id: str,
        range_name: str = 'A1:Z1000'
    ) -> Dict[str, Any]:
        """
        Read data from a spreadsheet.

        Args:
            agent_id: Agent ID
            spreadsheet_id: Spreadsheet ID
            range_name: Range to read (e.g., 'Sheet1!A1:D10')

        Returns:
            Dictionary with spreadsheet values
        """
        try:
            credentials = await self._load_credentials(agent_id)
            if not credentials:
                raise ValueError("No credentials found")

            service = build('sheets', 'v4', credentials=credentials)

            # Read spreadsheet values
            result = service.spreadsheets().values().get(
                spreadsheetId=spreadsheet_id,
                range=range_name
            ).execute()

            values = result.get('values', [])

            return {
                "success": True,
                "values": values,
                "range": result.get('range', '')
            }

        except HttpError as e:
            logger.error(f"Error reading spreadsheet: {e}")
            raise
        except Exception as e:
            logger.error(f"Error reading spreadsheet: {e}")
            raise

    async def write_spreadsheet(
        self,
        agent_id: str,
        spreadsheet_id: str,
        range_name: str,
        values: List[List[Any]]
    ) -> Dict[str, Any]:
        """
        Write data to a spreadsheet.

        Args:
            agent_id: Agent ID
            spreadsheet_id: Spreadsheet ID
            range_name: Range to write (e.g., 'Sheet1!A1')
            values: 2D array of values to write

        Returns:
            Dictionary with success status and updated range
        """
        try:
            credentials = await self._load_credentials(agent_id)
            if not credentials:
                raise ValueError("No credentials found")

            service = build('sheets', 'v4', credentials=credentials)

            # Write spreadsheet values
            body = {
                'values': values
            }

            result = service.spreadsheets().values().update(
                spreadsheetId=spreadsheet_id,
                range=range_name,
                valueInputOption='USER_ENTERED',
                body=body
            ).execute()

            return {
                "success": True,
                "updatedCells": result.get('updatedCells', 0),
                "updatedRange": result.get('updatedRange', '')
            }

        except HttpError as e:
            logger.error(f"Error writing to spreadsheet: {e}")
            raise
        except Exception as e:
            logger.error(f"Error writing to spreadsheet: {e}")
            raise

    async def append_spreadsheet(
        self,
        agent_id: str,
        spreadsheet_id: str,
        range_name: str,
        values: List[List[Any]]
    ) -> Dict[str, Any]:
        """
        Append data to a spreadsheet.

        Args:
            agent_id: Agent ID
            spreadsheet_id: Spreadsheet ID
            range_name: Range to append to (e.g., 'Sheet1!A1')
            values: 2D array of values to append

        Returns:
            Dictionary with success status and updated range
        """
        try:
            credentials = await self._load_credentials(agent_id)
            if not credentials:
                raise ValueError("No credentials found")

            service = build('sheets', 'v4', credentials=credentials)

            # Append spreadsheet values
            body = {
                'values': values
            }

            result = service.spreadsheets().values().append(
                spreadsheetId=spreadsheet_id,
                range=range_name,
                valueInputOption='USER_ENTERED',
                body=body
            ).execute()

            return {
                "success": True,
                "updatedCells": result.get('updates', {}).get('updatedCells', 0),
                "updatedRange": result.get('updates', {}).get('updatedRange', '')
            }

        except HttpError as e:
            logger.error(f"Error appending to spreadsheet: {e}")
            raise
        except Exception as e:
            logger.error(f"Error appending to spreadsheet: {e}")
            raise

    async def create_spreadsheet(
        self,
        agent_id: str,
        title: str,
        sheet_titles: Optional[List[str]] = None
    ) -> Dict[str, Any]:
        """
        Create a new spreadsheet.

        Args:
            agent_id: Agent ID
            title: Spreadsheet title
            sheet_titles: Optional list of sheet names

        Returns:
            Dictionary with success status, spreadsheet ID and URL
        """
        try:
            credentials = await self._load_credentials(agent_id)
            if not credentials:
                raise ValueError("No credentials found")

            service = build('sheets', 'v4', credentials=credentials)

            # Create spreadsheet body
            spreadsheet = {
                'properties': {
                    'title': title
                }
            }

            # Add custom sheets if specified
            if sheet_titles:
                spreadsheet['sheets'] = [
                    {'properties': {'title': sheet_title}}
                    for sheet_title in sheet_titles
                ]

            # Create spreadsheet
            result = service.spreadsheets().create(body=spreadsheet).execute()

            return {
                "success": True,
                "spreadsheetId": result['spreadsheetId'],
                "spreadsheetUrl": result['spreadsheetUrl']
            }

        except HttpError as e:
            logger.error(f"Error creating spreadsheet: {e}")
            raise
        except Exception as e:
            logger.error(f"Error creating spreadsheet: {e}")
            raise

    async def _store_credentials(
        self,
        agent_id: str,
        credentials: Credentials,
        email: Optional[str] = None,
        db: Optional[Any] = None
    ) -> None:
        """Store OAuth credentials directly to database or via evo-ai-core API."""
        credentials_data = {
            'token': credentials.token,
            'refresh_token': credentials.refresh_token,
            'token_uri': credentials.token_uri,
            'client_id': credentials.client_id,
            'client_secret': credentials.client_secret,
            'scopes': credentials.scopes,
            'email': email,
            'provider': 'google_sheets',
            'connected': True
        }

        if db:
            from src.services.agent_service import upsert_agent_integration
            success = await upsert_agent_integration(db, agent_id, "google_sheets_credentials", credentials_data)
            if success:
                logger.info("Successfully stored Google Sheets credentials directly to DB")
            else:
                logger.error("Failed to store Google Sheets credentials directly to DB")
        else:
            # Store credentials via evo-ai-core API
            url = f"{self.core_service_url}/agents/{agent_id}/integrations"

            response = await self.http_client.post(
                url,
                json={
                    "provider": "google_sheets_credentials",
                    "config": credentials_data
                }
            )

            response.raise_for_status()

    async def _load_credentials(
        self,
        agent_id: str,
        db: Optional[Any] = None
    ) -> Optional[Credentials]:
        """Load OAuth credentials directly from database (bypasses API sanitization)."""
        try:
            logger.info(f"_load_credentials called - agent_id={agent_id}, has_db={bool(db)}")
            credentials_data = None

            # Try to load from database first (no sanitization)
            if db:
                from src.services.agent_service import get_agent_integration_by_provider
                credentials_data = await get_agent_integration_by_provider(
                    db, agent_id, "google_sheets_credentials"
                )
                if credentials_data:
                    logger.info("Loaded credentials directly from database (no sanitization)")

            # Fallback to API if no db or not found
            if not credentials_data:
                logger.info("Loading credentials from evo-ai-core API")
                url = f"{self.core_service_url}/agents/{agent_id}/integrations/google_sheets_credentials"
                response = await self.http_client.get(url)

                if response.status_code == 404:
                    return None

                response.raise_for_status()
                data = response.json()
                credentials_data = data.get('config')

            if not credentials_data:
                return None

            # Debug logging
            logger.info(f"Loaded credentials_data with keys: {list(credentials_data.keys())}")
            logger.info(f"Has token: {bool(credentials_data.get('token'))}")
            logger.info(f"Has refresh_token: {bool(credentials_data.get('refresh_token'))}")
            logger.info(f"Has token_uri: {bool(credentials_data.get('token_uri'))}")
            logger.info(f"Has client_id: {bool(credentials_data.get('client_id'))}")
            logger.info(f"Has client_secret: {bool(credentials_data.get('client_secret'))}")

            credentials = Credentials(
                token=credentials_data.get('token'),
                refresh_token=credentials_data.get('refresh_token'),
                token_uri=credentials_data.get('token_uri'),
                client_id=credentials_data.get('client_id'),
                client_secret=credentials_data.get('client_secret'),
                scopes=credentials_data.get('scopes')
            )

            logger.info(f"Created Credentials object - expired: {credentials.expired}, has_refresh: {bool(credentials.refresh_token)}")

            # Refresh token if expired
            if credentials.expired and credentials.refresh_token:
                from google.auth.transport.requests import Request
                credentials.refresh(Request())

                # Update stored credentials
                await self._store_credentials(
                    agent_id,
                    credentials,
                    credentials_data.get('email'),
                    db=db
                )

            return credentials

        except httpx.HTTPStatusError as e:
            if e.response.status_code == 404:
                return None
            raise
