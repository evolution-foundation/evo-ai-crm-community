"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: a2a_utils.py                                                          │
│ Developed by: Davidson Gomes                                                 │
│ Creation date: May 13, 2025                                                  │
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

import base64
import uuid
from typing import Dict, List, Any, Optional
from google.genai.types import Part, Blob

from src.schemas.a2a_types import (
    ContentTypeNotSupportedError,
    JSONRPCResponse,
    UnsupportedOperationError,
    Message,
)


def are_modalities_compatible(
    server_output_modes: list[str], client_output_modes: list[str]
):
    """Modalities are compatible if they are both non-empty
    and there is at least one common element.
    """
    if client_output_modes is None or len(client_output_modes) == 0:
        return True

    if server_output_modes is None or len(server_output_modes) == 0:
        return True

    return any(x in server_output_modes for x in client_output_modes)


def new_incompatible_types_error(request_id):
    return JSONRPCResponse(id=request_id, error=ContentTypeNotSupportedError())


def new_not_implemented_error(request_id):
    return JSONRPCResponse(id=request_id, error=UnsupportedOperationError())


def extract_files_from_message(message: Message) -> List[Dict[str, Any]]:
    """
    Extract file parts from an A2A message.

    Args:
        message: An A2A Message object

    Returns:
        List of file parts extracted from the message
    """
    if not message or not message.parts:
        return []

    files = []
    for part in message.parts:
        if hasattr(part, "type") and part.type == "file" and hasattr(part, "file"):
            files.append(part)

    return files


def a2a_part_to_adk_part(a2a_part: Dict[str, Any]) -> Optional[Part]:
    """
    Convert an A2A protocol part to an ADK Part object.

    Args:
        a2a_part: An A2A part dictionary

    Returns:
        Converted ADK Part object or None if conversion not possible
    """
    part_type = a2a_part.get("type")
    if part_type == "file" and "file" in a2a_part:
        file_data = a2a_part["file"]
        if "bytes" in file_data:
            try:
                # Convert base64 to bytes
                file_bytes = base64.b64decode(file_data["bytes"])
                mime_type = file_data.get("mimeType", "application/octet-stream")

                # Create ADK Part
                return Part(inline_data=Blob(mime_type=mime_type, data=file_bytes))
            except Exception:
                return None
    elif part_type == "text" and "text" in a2a_part:
        # For text parts, we could create a text blob if needed
        return None

    return None


def adk_part_to_a2a_part(
    adk_part: Part, filename: Optional[str] = None
) -> Optional[Dict[str, Any]]:
    """
    Convert an ADK Part object to an A2A protocol part.

    Args:
        adk_part: An ADK Part object
        filename: Optional filename to use

    Returns:
        Converted A2A Part dictionary or None if conversion not possible
    """
    if hasattr(adk_part, "inline_data") and adk_part.inline_data:
        if adk_part.inline_data.data and adk_part.inline_data.mime_type:
            # Convert binary data to base64
            file_bytes = adk_part.inline_data.data
            mime_type = adk_part.inline_data.mime_type

            # Generate filename if not provided
            if not filename:
                ext = get_extension_from_mime(mime_type)
                filename = f"file_{uuid.uuid4().hex}{ext}"

            # Convert to A2A FilePart dict
            return {
                "type": "file",
                "file": {
                    "name": filename,
                    "mimeType": mime_type,
                    "bytes": (
                        base64.b64encode(file_bytes).decode("utf-8")
                        if isinstance(file_bytes, bytes)
                        else str(file_bytes)
                    ),
                },
            }
        elif hasattr(adk_part, "text") and adk_part.text:
            # Convert text part
            return {"type": "text", "text": adk_part.text}

    return None


def get_extension_from_mime(mime_type: str) -> str:
    """
    Get a file extension from MIME type.

    Args:
        mime_type: MIME type string

    Returns:
        Appropriate file extension with leading dot
    """
    if not mime_type:
        return ""

    mime_map = {
        "image/jpeg": ".jpg",
        "image/png": ".png",
        "image/gif": ".gif",
        "application/pdf": ".pdf",
        "text/plain": ".txt",
        "text/html": ".html",
        "text/csv": ".csv",
        "application/json": ".json",
        "application/xml": ".xml",
        "application/msword": ".doc",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document": ".docx",
        "application/vnd.ms-excel": ".xls",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": ".xlsx",
    }

    return mime_map.get(mime_type, "")
