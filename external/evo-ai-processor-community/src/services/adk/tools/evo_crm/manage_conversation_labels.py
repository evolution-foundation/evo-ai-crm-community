"""
Manage Conversation Labels Tool

This tool allows agents to list, add and remove labels on the current
conversation. Backend endpoints used:

- GET  /api/v1/conversations/{id}/labels  -> list current labels
- POST /api/v1/conversations/{id}/labels  -> replace labels (with `{labels: [...]}`)

The upstream POST is destructive (it replaces the full label list), so this
tool reads the current labels first and computes the union/difference before
writing back, preserving labels the user did not explicitly remove.
"""

from typing import Any, Dict, List, Optional

from google.adk.tools import FunctionTool, ToolContext

from src.services.adk.tools.evo_crm.base import EvoCrmClient
from src.utils.logger import setup_logger

logger = setup_logger(__name__)


def _extract_conversation_id_from_metadata(tool_context: Optional[ToolContext]) -> Optional[str]:
    """Extract conversation_id from tool_context metadata.

    Looks for conversation_id in various possible locations:
    - evoai_crm_data.conversation_id (UUID)
    - evoai_crm_data.conversation.id (display_id)
    - conversation_id (direct)
    - conversationId (camelCase)
    """
    if not tool_context or not hasattr(tool_context, "state"):
        return None

    state = tool_context.state

    evoai_crm_data = state.get("evoai_crm_data", {})
    if isinstance(evoai_crm_data, dict):
        conversation_id = evoai_crm_data.get("conversation_id")
        if conversation_id:
            return str(conversation_id)

        conversation = evoai_crm_data.get("conversation", {})
        if isinstance(conversation, dict):
            conv_id = conversation.get("id")
            if conv_id:
                return str(conv_id)

    for key in ("conversation_id", "conversationId"):
        if key in state:
            return str(state[key])

    return None


def _normalize_labels(raw: Any) -> List[str]:
    """Normalize a labels payload coming from the API to a flat list of titles."""
    if raw is None:
        return []

    if isinstance(raw, list):
        return [str(item).strip() for item in raw if str(item).strip()]

    if isinstance(raw, dict):
        for key in ("data", "labels", "payload"):
            if key in raw:
                return _normalize_labels(raw[key])

    return []


def _coerce_input_list(value: Any) -> List[str]:
    """Accept either a single string or a list, return a deduped list of strings."""
    if value is None:
        return []
    if isinstance(value, str):
        items = [value]
    elif isinstance(value, list):
        items = list(value)
    else:
        items = [value]

    seen = set()
    result: List[str] = []
    for item in items:
        if item is None:
            continue
        text = str(item).strip()
        if not text or text in seen:
            continue
        seen.add(text)
        result.append(text)
    return result


def create_manage_conversation_labels_tool() -> FunctionTool:
    """Create the manage_conversation_labels tool.

    The tool exposes three actions on the current conversation:
    - ``list``: returns the current labels.
    - ``add``: appends one or more labels, preserving existing ones.
    - ``remove``: removes one or more labels, preserving the rest.
    """

    client = EvoCrmClient()

    async def manage_conversation_labels(
        action: str,
        labels: Optional[Any] = None,
        conversation_id: Optional[str] = None,
        tool_context: Optional[ToolContext] = None,
    ) -> Dict[str, Any]:
        """Manage labels on the current conversation.

        Use this tool when:
        - You need to tag the conversation for routing or reporting
          (e.g. ``vip``, ``aguardando-pagamento``, ``followup``).
        - You need to remove a label that no longer applies.
        - You want to inspect which labels are currently attached.

        Important: ``add`` and ``remove`` are idempotent and additive — the
        tool reads the current labels first and merges your request, so it
        never erases labels the user did not ask to remove.

        Args:
            action: One of ``list``, ``add``, ``remove``.
            labels: For ``add`` / ``remove``: a label title (string) or a list
                of titles. Ignored when action is ``list``.
            conversation_id: Optional UUID of the conversation. Auto-extracted
                from the tool context when omitted.
            tool_context: Provided automatically by the runtime.

        Returns:
            Dictionary with the executed action and the resulting label list:
            ``{"status": "success"|"error", "message": "...",
               "conversation_id": "...", "action": "...",
               "labels": ["label-a", "label-b"], ...}``.
        """
        effective_conversation_id = conversation_id
        if not effective_conversation_id and tool_context:
            effective_conversation_id = _extract_conversation_id_from_metadata(tool_context)
            if effective_conversation_id:
                logger.info(f"Extracted conversation_id from metadata: {effective_conversation_id}")

        if not effective_conversation_id:
            return {
                "status": "error",
                "message": (
                    "conversation_id is required. It should be auto-extracted from the "
                    "conversation context; provide it explicitly if not available."
                ),
                "conversation_id": None,
                "action": action,
            }

        normalized_action = (action or "").strip().lower()
        if normalized_action not in {"list", "add", "remove"}:
            return {
                "status": "error",
                "message": "action must be one of: list, add, remove.",
                "conversation_id": effective_conversation_id,
                "action": action,
            }

        endpoint = f"/conversations/{effective_conversation_id}/labels"

        try:
            current_labels_raw = await client.get(endpoint=endpoint)
            current_labels = _normalize_labels(current_labels_raw)
            # The CRM /labels endpoint replaces (not appends) the whole set on POST,
            # so this read is what protects existing labels. A 204/empty body or an
            # intermittent auth failure makes the read look like "no labels", and a
            # subsequent add would then POST only the requested labels — WIPING every
            # existing label, including the `atendimento_ia` gate that keeps the bot
            # active. Detect a read that returned nothing usable and refuse to do a
            # destructive add rather than silently clobbering the conversation.
            read_is_empty = not current_labels
            read_is_unreliable = (
                isinstance(current_labels_raw, dict)
                and "status_code" in current_labels_raw
                and current_labels_raw.get("status_code") != 200
            )
        except Exception as api_error:
            logger.error(
                f"Failed to load labels for conversation {effective_conversation_id}: {api_error}"
            )
            return {
                "status": "error",
                "message": f"Failed to load current labels: {api_error}",
                "conversation_id": effective_conversation_id,
                "action": normalized_action,
                "error": str(api_error),
            }

        if normalized_action == "list":
            return {
                "status": "success",
                "message": f"Conversation has {len(current_labels)} label(s).",
                "conversation_id": effective_conversation_id,
                "action": "list",
                "labels": current_labels,
            }

        requested = _coerce_input_list(labels)
        if not requested:
            return {
                "status": "error",
                "message": "Provide at least one label for 'add' or 'remove'.",
                "conversation_id": effective_conversation_id,
                "action": normalized_action,
            }

        existing_set = {label.lower(): label for label in current_labels}

        if normalized_action == "add":
            # Defense-in-depth: refuse a destructive add. If the read came back empty
            # *because it was unreliable* (non-200/204 with no body), POSTing only the
            # requested labels would replace and wipe every existing label, including
            # the `atendimento_ia` gate. In that case abort instead of clobbering.
            if read_is_empty and read_is_unreliable:
                logger.error(
                    "manage_conversation_labels: refusing to add labels to "
                    f"{effective_conversation_id} — the labels read was unreliable "
                    f"(raw={current_labels_raw}); a replace would wipe existing labels."
                )
                return {
                    "status": "error",
                    "message": (
                        "Could not read the conversation's current labels reliably, "
                        "so the add was skipped to avoid removing existing labels. "
                        "Please retry."
                    ),
                    "conversation_id": effective_conversation_id,
                    "action": "add",
                }

            merged = list(current_labels)
            added: List[str] = []
            for label in requested:
                if label.lower() not in existing_set:
                    merged.append(label)
                    existing_set[label.lower()] = label
                    added.append(label)

            if not added:
                return {
                    "status": "success",
                    "message": "All requested labels were already present; nothing to update.",
                    "conversation_id": effective_conversation_id,
                    "action": "add",
                    "labels": current_labels,
                    "added": [],
                }

            payload = {"labels": merged}
        else:
            removed_lookup = {label.lower() for label in requested}
            merged = [label for label in current_labels if label.lower() not in removed_lookup]
            removed = [label for label in current_labels if label.lower() in removed_lookup]

            if not removed:
                return {
                    "status": "success",
                    "message": "None of the requested labels were present; nothing to update.",
                    "conversation_id": effective_conversation_id,
                    "action": "remove",
                    "labels": current_labels,
                    "removed": [],
                }

            payload = {"labels": merged}

        try:
            response = await client.post(endpoint=endpoint, json_data=payload)
            resulting_labels = _normalize_labels(response) or payload["labels"]
        except Exception as api_error:
            error_message = str(api_error)
            if "404" in error_message or "not found" in error_message.lower():
                error_message = (
                    f"Conversation {effective_conversation_id} not found. "
                    "Please verify the ID is correct."
                )
            elif "401" in error_message or "unauthorized" in error_message.lower():
                error_message = "Authentication failed. Please check EVOAI_CRM_API_TOKEN configuration."
            elif "400" in error_message or "bad request" in error_message.lower():
                error_message = (
                    f"Invalid request when updating labels on conversation "
                    f"{effective_conversation_id}. Labels: {payload['labels']}"
                )

            logger.error(f"Failed to update conversation labels: {error_message}")
            return {
                "status": "error",
                "message": error_message,
                "conversation_id": effective_conversation_id,
                "action": normalized_action,
                "labels": current_labels,
                "error": str(api_error),
            }

        if normalized_action == "add":
            logger.info(
                f"Added labels {added} to conversation {effective_conversation_id}; "
                f"now has {resulting_labels}"
            )
            return {
                "status": "success",
                "message": f"Added {len(added)} label(s) to the conversation.",
                "conversation_id": effective_conversation_id,
                "action": "add",
                "labels": resulting_labels,
                "added": added,
            }

        logger.info(
            f"Removed labels {removed} from conversation {effective_conversation_id}; "
            f"now has {resulting_labels}"
        )
        return {
            "status": "success",
            "message": f"Removed {len(removed)} label(s) from the conversation.",
            "conversation_id": effective_conversation_id,
            "action": "remove",
            "labels": resulting_labels,
            "removed": removed,
        }

    manage_conversation_labels.__name__ = "manage_conversation_labels"
    manage_conversation_labels.__doc__ = """Manage labels (tags) on the current conversation.

    Actions:
      - list:   returns the labels currently attached to the conversation
      - add:    appends one or more labels, preserving existing ones
      - remove: removes one or more labels, preserving the rest

    Args:
        action: "list" | "add" | "remove"
        labels: label title or list of titles (required for add/remove)
        conversation_id: optional UUID, auto-extracted from context when omitted

    Returns:
        Dictionary with action result and the resulting label list.
    """

    return FunctionTool(func=manage_conversation_labels)
