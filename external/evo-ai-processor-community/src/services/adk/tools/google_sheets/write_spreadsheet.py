"""Google Sheets write tool."""

from typing import Optional, Dict, Any, List
from google.adk.tools import FunctionTool, ToolContext
import traceback

from .base import GoogleSheetsClient
from src.utils.logger import setup_logger

logger = setup_logger(__name__)


def create_write_spreadsheet_tool(
    agent_id: Optional[str] = None,
    sheets_config: Optional[Dict[str, Any]] = None,
    credentials_config: Optional[Dict[str, Any]] = None,
    db=None
) -> FunctionTool:
    """
    Create a tool for writing data to Google Sheets spreadsheets.

    Args:
        agent_id: Optional default agent ID
        sheets_config: Google Sheets configuration from agent.config.integrations
        credentials_config: Google Sheets credentials from agent.config.integrations
        db: Database session for direct database access

    Returns:
        FunctionTool for writing spreadsheet data
    """
    client = GoogleSheetsClient(db=db)

    async def write_spreadsheet(
        range_name: str,
        values: List[List[Any]],
        spreadsheet_id: str = "",
        tool_context: Optional[ToolContext] = None,
    ) -> Dict[str, Any]:
        """
        Write data to a Google Sheets spreadsheet.

        This tool writes data to a specific range in a spreadsheet, replacing any existing
        content in that range. The data should be provided as a 2D array (list of lists).

        Use this tool when:
        - You need to update existing data in a spreadsheet
        - You want to write new data to specific cells
        - You need to replace a range of cells with new values
        - You're updating a report or dashboard

        The tool will:
        - Replace existing content in the specified range
        - Auto-resize the range based on your data
        - Return the number of cells/rows/columns updated

        Args:
            spreadsheet_id: The ID of the spreadsheet to write to (found in the URL) Optional — when omitted, the spreadsheet selected in the integration settings is used.
            range_name: The starting range to write (e.g., 'Sheet1!A1' or 'Data!B2')
            values: 2D array of values to write [[row1], [row2], ...]
            tool_context: Tool execution context

        Returns:
            Dictionary with write results or error message
        """
        try:
            logger.info(f"Writing to Google Sheets spreadsheet: {spreadsheet_id}, range: {range_name}")

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
            # (settings.selectedSpreadsheetId) when the caller omits an explicit id.
            if not spreadsheet_id or not spreadsheet_id.strip():
                spreadsheet_id = ((sheets_config or {}).get("settings") or {}).get("selectedSpreadsheetId", "") or ""

            if not spreadsheet_id or not spreadsheet_id.strip():
                return {
                    "status": "error",
                    "message": "No spreadsheet_id was provided and no spreadsheet is selected in the integration settings"
                }

            if not range_name or not range_name.strip():
                return {
                    "status": "error",
                    "message": "Range name is required"
                }

            if not values or not isinstance(values, list):
                return {
                    "status": "error",
                    "message": "Values must be a 2D array (list of lists)"
                }

            # Validate values structure
            if not all(isinstance(row, list) for row in values):
                return {
                    "status": "error",
                    "message": "Each row in values must be a list"
                }

            # Write to the spreadsheet
            logger.info(f"Writing {len(values)} rows to Google Sheets")
            result = await client.write_spreadsheet(
                credentials_config=credentials_config,
                spreadsheet_id=spreadsheet_id,
                range_name=range_name,
                values=values
            )

            if result["status"] == "error":
                logger.error(f"Write failed: {result.get('message')}")
                return result

            # Build success response
            response = {
                "status": "success",
                "message": result.get("message", "Data written successfully"),
                "details": {
                    "updated_cells": result.get("updated_cells", 0),
                    "updated_range": result.get("updated_range", ""),
                    "updated_rows": result.get("updated_rows", 0),
                    "updated_columns": result.get("updated_columns", 0)
                }
            }

            logger.info(f"Successfully wrote {result.get('updated_cells', 0)} cells")
            return response

        except Exception as e:
            logger.error(f"Unexpected error in write_spreadsheet: {str(e)}")
            logger.error(traceback.format_exc())
            return {
                "status": "error",
                "message": f"Failed to write to spreadsheet: {str(e)}"
            }

    # Set function metadata
    write_spreadsheet.__name__ = "write_spreadsheet"

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

    write_spreadsheet.__doc__ = f"""Write data to a Google Sheets spreadsheet, replacing existing content.
{_default_hint}
Args:
    spreadsheet_id (str, optional): The spreadsheet ID (found in the URL after /d/).
        Omit to use the agent's configured spreadsheet.
    range_name (str): The starting cell or range where data should be written (e.g., 'Sheet1!A1').
    values (list): 2D array of values to write, e.g., [['Name', 'Email'], ['John', 'john@example.com']].

Returns:
    Dictionary with updated_cells, updated_range, updated_rows and updated_columns.

Note: This REPLACES existing content in the range. To add rows without replacing, use append_spreadsheet.
"""

    return FunctionTool(func=write_spreadsheet)
