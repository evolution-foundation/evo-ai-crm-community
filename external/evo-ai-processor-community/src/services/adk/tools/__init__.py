"""
This module contains the tools for the ADK.
"""

from .exit_loop import exit_loop
from .text_to_speech import create_text_to_speech_tool

# CRM tools are imported conditionally to avoid circular imports
# They are accessed via: from src.services.adk.tools.evo_crm import create_transfer_to_human_tool

# Google Calendar tools are imported conditionally to avoid circular imports
# They are accessed via: from src.services.adk.tools.google_calendar import create_check_availability_tool, create_calendar_event_tool

# Google Sheets tools are imported conditionally to avoid circular imports
# They are accessed via: from src.services.adk.tools.google_sheets import create_read_spreadsheet_tool, create_write_spreadsheet_tool, create_append_spreadsheet_tool, create_create_spreadsheet_tool

# Knowledge Nexus tools are imported lazily inside tool_builder.py to avoid circular imports
# They are accessed via: from src.services.adk.tools.knowledge_nexus import create_knowledge_nexus_search_tool

__all__ = [
    "exit_loop",
    "create_text_to_speech_tool",
]
