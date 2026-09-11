"""Google Sheets read tool."""

from typing import Optional, Dict, Any
from google.adk.tools import FunctionTool, ToolContext
import traceback

from .base import GoogleSheetsClient
from src.utils.logger import setup_logger

logger = setup_logger(__name__)


def create_read_spreadsheet_tool(
    agent_id: Optional[str] = None,
    sheets_config: Optional[Dict[str, Any]] = None,
    credentials_config: Optional[Dict[str, Any]] = None,
    db=None
) -> FunctionTool:
    """
    Create a tool for reading data from Google Sheets spreadsheets.

    Args:
        agent_id: Optional default agent ID
        sheets_config: Google Sheets configuration from agent.config.integrations
        credentials_config: Google Sheets credentials from agent.config.integrations
        db: Database session for direct database access

    Returns:
        FunctionTool for reading spreadsheet data
    """
    client = GoogleSheetsClient(db=db)

    async def read_spreadsheet(
        spreadsheet_id: str = "",
        range_name: str = 'A1:Z1000',
        tool_context: Optional[ToolContext] = None,
    ) -> Dict[str, Any]:
        """
        Read data from a Google Sheets spreadsheet.

        This tool retrieves data from a spreadsheet, returning it as a structured format
        that you can analyze, summarize, or process further.

        Use this tool when:
        - You need to fetch data from a spreadsheet
        - A customer asks about information stored in a spreadsheet
        - You need to analyze or report on spreadsheet data
        - You want to verify existing data before making changes

        The tool will return:
        - All values in the specified range
        - Row and column counts
        - The actual range that was read

        Args:
            spreadsheet_id: The ID of the spreadsheet to read from (found in the URL) Optional — when omitted, the spreadsheet selected in the integration settings is used.
            range_name: The range to read (e.g., 'Sheet1!A1:D10' or 'A1:Z1000')
            tool_context: Tool execution context

        Returns:
            Dictionary with spreadsheet data or error message
        """
        try:
            logger.info(f"Reading Google Sheets spreadsheet: {spreadsheet_id}, range: {range_name}")

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

            # Default to the spreadsheet selected in the integration config
            # (settings.selectedSpreadsheetId) when the caller omits an explicit id,
            # mirroring how Google Calendar defaults to the 'primary' calendar.
            if not spreadsheet_id or not spreadsheet_id.strip():
                spreadsheet_id = ((sheets_config or {}).get("settings") or {}).get("selectedSpreadsheetId", "") or ""

            if not spreadsheet_id or not spreadsheet_id.strip():
                return {
                    "status": "error",
                    "message": "No spreadsheet_id was provided and no spreadsheet is selected in the integration settings"
                }

            # Read the spreadsheet
            logger.info(f"Fetching data from Google Sheets")
            result = await client.read_spreadsheet(
                credentials_config=credentials_config,
                spreadsheet_id=spreadsheet_id,
                range_name=range_name
            )

            if result["status"] == "error":
                logger.error(f"Read failed: {result.get('message')}")
                return result

            # Build success response
            response = {
                "status": "success",
                "message": f"Successfully read {result.get('row_count', 0)} rows from spreadsheet",
                "data": {
                    "values": result.get("values", []),
                    "range": result.get("range", ""),
                    "row_count": result.get("row_count", 0),
                    "column_count": result.get("column_count", 0)
                }
            }

            logger.info(f"Successfully read {result.get('row_count', 0)} rows")
            return response

        except Exception as e:
            logger.error(f"Unexpected error in read_spreadsheet: {str(e)}")
            logger.error(traceback.format_exc())
            return {
                "status": "error",
                "message": f"Failed to read spreadsheet: {str(e)}"
            }

    # Set function metadata
    read_spreadsheet.__name__ = "read_spreadsheet"

    # Surface the agent's configured spreadsheet in the tool description so the
    # model calls the tool WITHOUT asking the user for an id.
    _settings = (sheets_config or {}).get("settings") or {}
    _selected_id = _settings.get("selectedSpreadsheetId", "") or ""
    _selected_name = next(
        (sp.get("name", "") for sp in ((sheets_config or {}).get("spreadsheets") or [])
         if sp.get("id") == _selected_id),
        "",
    )
    _default_hint = (
        f"\nThis agent has a default spreadsheet configured: '{_selected_name}' (id: {_selected_id}).\n"
        "When the user refers to 'the spreadsheet', 'my spreadsheet' or the connected sheet "
        "WITHOUT giving an id, call this tool WITHOUT the spreadsheet_id argument to use it. "
        "Do NOT ask the user for a spreadsheet id unless they explicitly want a DIFFERENT spreadsheet.\n"
    ) if _selected_id else ""

    read_spreadsheet.__doc__ = f"""Read data from a Google Sheets spreadsheet.
{_default_hint}
Args:
    spreadsheet_id (str, optional): The spreadsheet ID (found in the URL after /d/).
        Omit to use the agent's configured spreadsheet.
    range_name (str, optional): The range to read in A1 notation (default: 'A1:Z1000').
        Examples: 'Sheet1!A1:D10', 'Data!A:E', 'A1:Z1000'.

Returns:
    Dictionary with values (2D array), range, row_count and column_count.
"""

    return FunctionTool(func=read_spreadsheet)
