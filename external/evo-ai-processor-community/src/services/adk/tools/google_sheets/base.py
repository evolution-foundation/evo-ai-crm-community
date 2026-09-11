"""Base client for Google Sheets integration tools."""

import os
from typing import Any, Dict, Optional, List
from google.oauth2.credentials import Credentials
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError


class GoogleSheetsClient:
    """Client for Google Sheets API with integration configuration."""

    def __init__(self, db=None):
        """
        Initialize Google Sheets client.

        Args:
            db: Database session for direct database access (bypasses API sanitization)
        """
        self.db = db
        self._integration_cache: Dict[str, Dict[str, Any]] = {}

    async def get_integration(
        self,
        agent_id: str
    ) -> Optional[Dict[str, Any]]:
        """
        Fetch Google Sheets integration configuration for an agent directly from database.

        Args:
            agent_id: The agent ID

        Returns:
            Integration configuration with credentials and settings, or None if not found
        """
        cache_key = agent_id
        if cache_key in self._integration_cache:
            return self._integration_cache[cache_key]

        # Load directly from database (no sanitization)
        from src.services.agent_service import get_agent_integration_by_provider

        integration_config = await get_agent_integration_by_provider(
            self.db, agent_id, "google_sheets"
        )

        if integration_config:
            integration = {
                "provider": "google_sheets",
                "config": integration_config
            }
            self._integration_cache[cache_key] = integration
            return integration

        return None

    def _create_credentials(self, credentials_dict: Dict[str, Any]) -> Credentials:
        """
        Create Google OAuth credentials from stored credentials.

        Args:
            credentials_dict: Dictionary with OAuth tokens

        Returns:
            Google OAuth2 Credentials object
        """
        # Support both 'token' and 'access_token' formats
        access_token = credentials_dict.get("token") or credentials_dict.get("access_token")

        return Credentials(
            token=access_token,
            refresh_token=credentials_dict.get("refresh_token"),
            token_uri=credentials_dict.get("token_uri", "https://oauth2.googleapis.com/token"),
            client_id=credentials_dict.get("client_id"),
            client_secret=credentials_dict.get("client_secret"),
            scopes=credentials_dict.get("scopes", [
                "https://www.googleapis.com/auth/spreadsheets",
                "https://www.googleapis.com/auth/drive.readonly"
            ])
        )

    def get_sheets_service(self, credentials_dict: Dict[str, Any]):
        """
        Create Google Sheets API service instance.

        Args:
            credentials_dict: Dictionary with OAuth tokens

        Returns:
            Google Sheets API service
        """
        credentials = self._create_credentials(credentials_dict)
        return build('sheets', 'v4', credentials=credentials)

    def get_drive_service(self, credentials_dict: Dict[str, Any]):
        """
        Create Google Drive API service instance (for listing spreadsheets).

        Args:
            credentials_dict: Dictionary with OAuth tokens

        Returns:
            Google Drive API service
        """
        credentials = self._create_credentials(credentials_dict)
        return build('drive', 'v3', credentials=credentials)

    async def read_spreadsheet(
        self,
        credentials_config: Dict[str, Any],
        spreadsheet_id: str,
        range_name: str = 'A1:Z1000'
    ) -> Dict[str, Any]:
        """
        Read data from a spreadsheet.

        Args:
            credentials_config: Google Sheets credentials configuration
            spreadsheet_id: Spreadsheet ID
            range_name: Range to read (e.g., 'Sheet1!A1:D10')

        Returns:
            Dictionary with spreadsheet values or error
        """
        try:
            service = self.get_sheets_service(credentials_config)

            # Read spreadsheet values
            result = service.spreadsheets().values().get(
                spreadsheetId=spreadsheet_id,
                range=range_name
            ).execute()

            values = result.get('values', [])

            return {
                "status": "success",
                "values": values,
                "range": result.get('range', ''),
                "row_count": len(values),
                "column_count": len(values[0]) if values else 0
            }

        except HttpError as e:
            return {
                "status": "error",
                "message": f"Google Sheets API error: {str(e)}"
            }

    async def write_spreadsheet(
        self,
        credentials_config: Dict[str, Any],
        spreadsheet_id: str,
        range_name: str,
        values: List[List[Any]]
    ) -> Dict[str, Any]:
        """
        Write data to a spreadsheet.

        Args:
            credentials_config: Google Sheets credentials configuration
            spreadsheet_id: Spreadsheet ID
            range_name: Range to write (e.g., 'Sheet1!A1')
            values: 2D array of values to write

        Returns:
            Dictionary with write results or error
        """
        try:
            service = self.get_sheets_service(credentials_config)

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
                "status": "success",
                "message": "Data written successfully",
                "updated_cells": result.get('updatedCells', 0),
                "updated_range": result.get('updatedRange', ''),
                "updated_rows": result.get('updatedRows', 0),
                "updated_columns": result.get('updatedColumns', 0)
            }

        except HttpError as e:
            return {
                "status": "error",
                "message": f"Google Sheets API error: {str(e)}"
            }

    async def append_spreadsheet(
        self,
        credentials_config: Dict[str, Any],
        spreadsheet_id: str,
        range_name: str,
        values: List[List[Any]]
    ) -> Dict[str, Any]:
        """
        Append data to a spreadsheet.

        Args:
            credentials_config: Google Sheets credentials configuration
            spreadsheet_id: Spreadsheet ID
            range_name: Range to append to (e.g., 'Sheet1!A1')
            values: 2D array of values to append

        Returns:
            Dictionary with append results or error
        """
        try:
            service = self.get_sheets_service(credentials_config)

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

            updates = result.get('updates', {})

            return {
                "status": "success",
                "message": "Data appended successfully",
                "updated_cells": updates.get('updatedCells', 0),
                "updated_range": updates.get('updatedRange', ''),
                "updated_rows": updates.get('updatedRows', 0),
                "updated_columns": updates.get('updatedColumns', 0)
            }

        except HttpError as e:
            return {
                "status": "error",
                "message": f"Google Sheets API error: {str(e)}"
            }

    async def create_spreadsheet(
        self,
        credentials_config: Dict[str, Any],
        title: str,
        sheet_titles: Optional[List[str]] = None
    ) -> Dict[str, Any]:
        """
        Create a new spreadsheet.

        Args:
            credentials_config: Google Sheets credentials configuration
            title: Spreadsheet title
            sheet_titles: Optional list of sheet names

        Returns:
            Dictionary with created spreadsheet info or error
        """
        try:
            service = self.get_sheets_service(credentials_config)

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
                "status": "success",
                "message": "Spreadsheet created successfully",
                "spreadsheet_id": result['spreadsheetId'],
                "spreadsheet_url": result['spreadsheetUrl'],
                "title": title
            }

        except HttpError as e:
            return {
                "status": "error",
                "message": f"Google Sheets API error: {str(e)}"
            }
