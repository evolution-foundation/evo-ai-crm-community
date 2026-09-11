"""
Link Product to Pipeline Item Tool

Lets the agent record a sale during the conversation by linking a product
(optionally a variant + quantity + notes) to the pipeline_item attached to
the conversation. The CRM endpoint snapshots the price at link time, so
later changes to Product.default_price never alter recorded sales.

Backend endpoint:
    POST /api/v1/pipeline_items/{pipeline_item_id}/products

Body:
    { product_id, product_variant_id?, quantity, notes?,
      created_by_type: "AiAgent", created_by_id: <agent_id> }
"""

from typing import Any, Dict, Optional

from google.adk.tools import FunctionTool, ToolContext

from src.services.adk.tools.evo_crm.base import EvoCrmClient
from src.utils.logger import setup_logger

logger = setup_logger(__name__)


def _extract_pipeline_item_id(tool_context: Optional[ToolContext]) -> Optional[str]:
    """Extract pipeline_item_id from tool_context.state.

    Looked up in order:
      - evoai_crm_data.pipeline_item_id
      - evoai_crm_data.pipeline_item.id
      - pipeline_item_id (direct)
      - pipelineItemId (camelCase)
    """
    if not tool_context or not hasattr(tool_context, "state"):
        return None

    state = tool_context.state

    evoai_crm_data = state.get("evoai_crm_data", {})
    if isinstance(evoai_crm_data, dict):
        direct = evoai_crm_data.get("pipeline_item_id")
        if direct:
            return str(direct)

        pipeline_item = evoai_crm_data.get("pipeline_item", {})
        if isinstance(pipeline_item, dict):
            value = pipeline_item.get("id")
            if value:
                return str(value)

    for key in ("pipeline_item_id", "pipelineItemId"):
        if key in state:
            return str(state[key])

    return None


def _extract_agent_id(tool_context: Optional[ToolContext]) -> Optional[str]:
    """Best-effort lookup for the AI agent id so the sale row records the actor."""
    if not tool_context or not hasattr(tool_context, "state"):
        return None

    state = tool_context.state
    for key in ("agent_id", "ai_agent_id", "agentId"):
        if key in state:
            return str(state[key])

    evoai_crm_data = state.get("evoai_crm_data", {})
    if isinstance(evoai_crm_data, dict):
        for key in ("agent_id", "ai_agent_id"):
            if key in evoai_crm_data:
                return str(evoai_crm_data[key])

    return None


def create_link_product_to_pipeline_item_tool() -> FunctionTool:
    """Factory for the link_product_to_pipeline_item tool."""

    client = EvoCrmClient()

    async def link_product_to_pipeline_item(
        product_id: str,
        quantity: int = 1,
        product_variant_id: Optional[str] = None,
        notes: Optional[str] = None,
        pipeline_item_id: Optional[str] = None,
        tool_context: Optional[ToolContext] = None,
    ) -> Dict[str, Any]:
        """Link a product (optionally a variant) to the current pipeline item.

        Use this tool when the user has confirmed they will purchase one or
        more of the catalog products listed in the <product-catalog> block of
        your instruction. It registers the sale on the pipeline card so a
        human can pick up follow-up actions. The unit price is locked at the
        moment of the call — do NOT call this tool just because the user
        asked about a product; only call it when the purchase intent is
        clear.

        Args:
            product_id: UUID of the product to link. Required.
            quantity: How many units. Must be a positive integer. Defaults to 1.
            product_variant_id: Optional UUID of the variant (e.g. size/color).
            notes: Optional free-form note recorded with the sale.
            pipeline_item_id: Optional UUID; auto-extracted from context when
                omitted (the conversation's pipeline_item).
            tool_context: Provided automatically by the runtime.

        Returns:
            Dictionary with status, the created link details and a
            human-readable message.
        """
        effective_pi_id = pipeline_item_id
        if not effective_pi_id and tool_context:
            effective_pi_id = _extract_pipeline_item_id(tool_context)
            if effective_pi_id:
                logger.info(f"Extracted pipeline_item_id from context: {effective_pi_id}")

        if not effective_pi_id:
            return {
                "status": "error",
                "message": (
                    "pipeline_item_id is required. It should be auto-extracted from the "
                    "conversation context; provide it explicitly only if the conversation "
                    "is not attached to a pipeline."
                ),
                "pipeline_item_id": None,
            }

        if not product_id:
            return {
                "status": "error",
                "message": "product_id is required.",
                "pipeline_item_id": effective_pi_id,
            }

        try:
            qty = int(quantity)
        except (TypeError, ValueError):
            return {
                "status": "error",
                "message": "quantity must be a positive integer.",
                "pipeline_item_id": effective_pi_id,
            }

        if qty < 1:
            return {
                "status": "error",
                "message": "quantity must be at least 1.",
                "pipeline_item_id": effective_pi_id,
            }

        agent_id = _extract_agent_id(tool_context)

        payload: Dict[str, Any] = {
            "product_id": str(product_id),
            "quantity": qty,
            "created_by_type": "AiAgent",
        }
        if product_variant_id:
            payload["product_variant_id"] = str(product_variant_id)
        if notes:
            payload["notes"] = str(notes)
        if agent_id:
            payload["created_by_id"] = agent_id

        endpoint = f"/pipeline_items/{effective_pi_id}/products"

        try:
            response = await client.post(endpoint=endpoint, json_data=payload)
        except Exception as api_error:
            error_message = str(api_error)
            if "404" in error_message or "not found" in error_message.lower():
                error_message = (
                    f"Pipeline item {effective_pi_id} or product {product_id} not found."
                )
            elif "401" in error_message or "unauthorized" in error_message.lower():
                error_message = (
                    "Authentication failed. Check EVOAI_CRM_API_TOKEN configuration."
                )
            elif "422" in error_message or "unprocessable" in error_message.lower():
                error_message = (
                    "The CRM rejected the link payload (validation error). "
                    "Double-check product_id, product_variant_id (must belong to the product) "
                    "and quantity (>0)."
                )

            logger.error(f"link_product_to_pipeline_item failed: {error_message}")
            return {
                "status": "error",
                "message": error_message,
                "pipeline_item_id": effective_pi_id,
                "product_id": product_id,
                "error": str(api_error),
            }

        data = response.get("data") if isinstance(response, dict) else None
        product_summary = data.get("product") if isinstance(data, dict) else None
        product_name = (
            product_summary.get("name") if isinstance(product_summary, dict) else None
        ) or product_id

        logger.info(
            f"Linked product {product_id} (qty={qty}) to pipeline_item {effective_pi_id}"
        )

        return {
            "status": "success",
            "message": f"Recorded {qty}x {product_name} on the pipeline card.",
            "pipeline_item_id": effective_pi_id,
            "product_id": product_id,
            "product_variant_id": product_variant_id,
            "quantity": qty,
            "details": data,
        }

    link_product_to_pipeline_item.__name__ = "link_product_to_pipeline_item"

    return FunctionTool(func=link_product_to_pipeline_item)
