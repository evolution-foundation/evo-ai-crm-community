"""Google Sheets create spreadsheet tool."""

from typing import Optional, Dict, Any, List
from google.adk.tools import FunctionTool, ToolContext
import traceback

from .base import GoogleSheetsClient
from src.utils.logger import setup_logger

logger = setup_logger(__name__)


def create_create_spreadsheet_tool(
    agent_id: Optional[str] = None,
    sheets_config: Optional[Dict[str, Any]] = None,
    credentials_config: Optional[Dict[str, Any]] = None,
    db=None
) -> FunctionTool:
    """
    Create a tool for creating new Google Sheets spreadsheets.

    Args:
        agent_id: Optional default agent ID
        sheets_config: Google Sheets configuration from agent.config.integrations
        credentials_config: Google Sheets credentials from agent.config.integrations
        db: Database session for direct database access

    Returns:
        FunctionTool for creating spreadsheets
    """
    client = GoogleSheetsClient(db=db)

    async def create_spreadsheet(
        title: str,
        sheet_titles: Optional[List[str]] = None,
        tool_context: Optional[ToolContext] = None,
    ) -> Dict[str, Any]:
        """
        Create a new Google Sheets spreadsheet.

        This tool creates a brand new spreadsheet in Google Drive. You can specify
        the spreadsheet title and optionally create multiple named sheets within it.

        Use this tool when:
        - You need to create a new spreadsheet for a customer
        - You're starting a new report or data collection
        - You want to organize data in a fresh spreadsheet
        - You need separate sheets for different data categories

        The tool will:
        - Create a new spreadsheet with the specified title
        - Add custom named sheets if provided
        - Return the spreadsheet ID and URL for accessing it
        - Make the spreadsheet accessible via the configured Google account

        Args:
            title: The title for the new spreadsheet
            sheet_titles: Optional list of sheet names to create (e.g., ['Sales', 'Expenses', 'Summary'])
            tool_context: Tool execution context

        Returns:
            Dictionary with created spreadsheet details or error message
        """
        try:
            logger.info(f"Creating new Google Sheets spreadsheet: {title}")

            # Use agent_id from closure
            effective_agent_id = agent_id

            # Validate required parameters
            if not effective_agent_id:
                return {
                    "status": "error",
                    "message": "Agent ID is required but was not provided"
                }

            # Validate configs provided
            if not credentials_config:
                return {
                    "status": "error",
                    "message": "Google Sheets credentials not configured for this agent"
                }

            if not title or not title.strip():
                return {
                    "status": "error",
                    "message": "Spreadsheet title is required"
                }

            # Validate sheet_titles if provided
            if sheet_titles is not None:
                if not isinstance(sheet_titles, list):
                    return {
                        "status": "error",
                        "message": "Sheet titles must be a list of strings"
                    }
                if not all(isinstance(name, str) and name.strip() for name in sheet_titles):
                    return {
                        "status": "error",
                        "message": "Each sheet title must be a non-empty string"
                    }

            # Create the spreadsheet
            logger.info(f"Creating spreadsheet in Google Sheets")
            result = await client.create_spreadsheet(
                credentials_config=credentials_config,
                title=title,
                sheet_titles=sheet_titles
            )

            if result["status"] == "error":
                logger.error(f"Spreadsheet creation failed: {result.get('message')}")
                return result

            # Build success response
            response = {
                "status": "success",
                "message": result.get("message", "Spreadsheet created successfully"),
                "spreadsheet": {
                    "id": result.get("spreadsheet_id"),
                    "url": result.get("spreadsheet_url"),
                    "title": result.get("title")
                }
            }

            # Add sheet info if custom sheets were created
            if sheet_titles:
                response["spreadsheet"]["sheets"] = sheet_titles
                response["spreadsheet"]["sheet_count"] = len(sheet_titles)
                response["message"] += f" with {len(sheet_titles)} custom sheet(s)"

            logger.info(f"Successfully created spreadsheet: {result.get('spreadsheet_id')}")
            return response

        except Exception as e:
            logger.error(f"Unexpected error in create_spreadsheet: {str(e)}")
            logger.error(traceback.format_exc())
            return {
                "status": "error",
                "message": f"Failed to create spreadsheet: {str(e)}"
            }

    # Set function metadata
    create_spreadsheet.__name__ = "create_spreadsheet"

    create_spreadsheet.__doc__ = """Create a new Google Sheets spreadsheet.

Use this tool to create a brand new spreadsheet in Google Drive. The spreadsheet will be owned
by the Google account configured in the agent's integration.

Args:
    title (str): The title for the new spreadsheet
    sheet_titles (list, optional): List of sheet names to create within the spreadsheet
                                   If not provided, a default sheet will be created
                                   Examples: ['January', 'February', 'March']
                                            ['Data', 'Analysis', 'Summary']

Returns:
    Dictionary containing:
    - spreadsheet_id: The ID of the created spreadsheet (use this for other operations)
    - spreadsheet_url: Direct URL to open the spreadsheet
    - title: The spreadsheet title
    - sheets: List of sheet names created (if custom sheets were specified)

Examples:
- Simple spreadsheet: title='Customer Database'
- Spreadsheet with custom sheets: title='2024 Sales Report', sheet_titles=['Q1', 'Q2', 'Q3', 'Q4']
- Monthly tracker: title='Expense Tracker', sheet_titles=['January', 'February', 'March']
- Project management: title='Project Tasks', sheet_titles=['Todo', 'In Progress', 'Done']

Note: After creating the spreadsheet, use the returned spreadsheet_id with other tools like
write_spreadsheet, append_spreadsheet, or read_spreadsheet to work with the data.
"""

    return FunctionTool(func=create_spreadsheet)
