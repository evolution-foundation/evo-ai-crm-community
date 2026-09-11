"""Tool-name sanitization for LLM tool/function payloads.

Providers constrain ``tools[].function.name`` to ``^[a-zA-Z0-9_-]+$`` (64 chars
max) and reject the whole turn otherwise, so a custom tool named with a space or
an accent breaks the chat. Only tools we dispatch by ``__name__`` (custom HTTP
tools) may be renamed here: MCP tool names come from the protocol and are the
key that routes execution back to the server.
"""

import re
from itertools import count
from typing import Container

# What the providers accept verbatim.
_VALID_NAME = re.compile(r"^[a-zA-Z0-9_-]+$")
# Anything outside that alphabet becomes a single separator.
_INVALID_RUN = re.compile(r"[^a-zA-Z0-9_-]+")
_REPEAT_UNDERSCORE = re.compile(r"_+")

# OpenAI caps function names at 64 characters.
MAX_TOOL_NAME_LENGTH = 64

# Last-resort name when sanitization leaves nothing usable (e.g. a name made
# entirely of invalid characters), so the payload is always valid.
FALLBACK_TOOL_NAME = "tool"


def sanitize_tool_name(name: str) -> str:
    """Coerce ``name`` into ``^[a-zA-Z0-9_-]+$`` for an LLM function name.

    A name the providers already accept comes back untouched — renaming a tool
    that works today would be a silent behaviour change. Otherwise invalid runs
    collapse to ``_``, repeated underscores are squeezed, the edges are trimmed
    and the result is capped at 64 chars, falling back to ``"tool"`` when
    nothing usable is left.
    """
    if not name:
        return FALLBACK_TOOL_NAME

    if _VALID_NAME.match(name) and len(name) <= MAX_TOOL_NAME_LENGTH:
        return name

    sanitized = _INVALID_RUN.sub("_", name)
    sanitized = _REPEAT_UNDERSCORE.sub("_", sanitized).strip("_-")
    sanitized = sanitized[:MAX_TOOL_NAME_LENGTH].strip("_-")
    return sanitized or FALLBACK_TOOL_NAME


def unique_tool_name(name: str, taken: Container[str] = ()) -> str:
    """Sanitized ``name``, numbered while another tool already answers to it.

    Distinct names can sanitize to the same string ("a b" and "a_b"), and so can
    two long names sharing their first 64 chars. Without this the provider gets
    two declarations under one name and the call lands on whichever tool the
    dispatch finds first.
    """
    candidate = sanitize_tool_name(name)
    if candidate not in taken:
        return candidate

    for suffix in count(2):
        marker = f"_{suffix}"
        numbered = candidate[: MAX_TOOL_NAME_LENGTH - len(marker)] + marker
        if numbered not in taken:
            return numbered
