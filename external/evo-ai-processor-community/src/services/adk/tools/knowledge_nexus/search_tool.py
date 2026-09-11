"""Knowledge Nexus search tool — hybrid retrieval against EvoNexus Knowledge API."""

from typing import Any, Dict, List, Optional

import httpx
import logging

from google.adk.tools import FunctionTool, ToolContext

logger = logging.getLogger(__name__)


def _mask_api_key(api_key: str) -> str:
    if not api_key:
        return "<empty>"
    if api_key.startswith("evo_k_"):
        return "evo_k_***"
    return "***"


def create_knowledge_nexus_search_tool(
    nexus_base_url: str,
    nexus_api_key: str,
    space_id: str,
    default_top_k: int = 10,
    default_filters: Optional[Dict[str, Any]] = None,
    timeout_seconds: float = 15.0,
) -> FunctionTool:
    """Create the knowledge_nexus_search tool.

    Args:
        nexus_base_url: Base URL of the EvoNexus dashboard (e.g. https://nexus.example.io)
        nexus_api_key: External API key in the format ``evo_k_<prefix>.<secret>``
        space_id: UUID of the target Nexus knowledge space
        default_top_k: Default number of chunks to retrieve when the LLM doesn't override
        default_filters: Default filter payload forwarded to Nexus (``unit_id``,
            ``chunk_type``, ``content_type``)
        timeout_seconds: Timeout applied to the HTTP call
    """

    base_url = (nexus_base_url or "").rstrip("/")
    filters = dict(default_filters or {})

    async def knowledge_nexus_search(
        query: str,
        tool_context: "ToolContext",
        top_k: Optional[int] = None,
    ) -> Dict[str, Any]:
        """Search the EvoNexus knowledge base for chunks relevant to a query.

        Use this tool when factual grounding from indexed company knowledge is
        needed before answering the user.

        Args:
            query: Natural-language question or keywords to search for. Required.
            tool_context: Provided by Google ADK at runtime.
            top_k: Optional override for the number of chunks to retrieve.

        Returns:
            A dict with shape:
                {"status": "success", "total": N, "results": [
                    {"doc_title": str, "content": str,
                     "content_type": str, "final_score": float}, ...]}
            or, on failure:
                {"status": "failed", "error": "<human-readable message>"}
        """

        if not query or not query.strip():
            return {"status": "failed", "error": "query cannot be empty"}

        if top_k is not None:
            try:
                effective_top_k = int(top_k)
            except (TypeError, ValueError):
                return {
                    "status": "failed",
                    "error": "top_k must be an integer.",
                }
            if effective_top_k <= 0:
                return {
                    "status": "failed",
                    "error": "top_k must be a positive integer.",
                }
        else:
            effective_top_k = int(default_top_k)
        url = f"{base_url}/api/knowledge/v1/spaces/{space_id}/search"
        body: Dict[str, Any] = {"query": query.strip(), "top_k": effective_top_k}
        if filters:
            body["filters"] = filters

        headers = {
            "Authorization": f"Bearer {nexus_api_key}",
            "Content-Type": "application/json",
        }

        logger.info(
            "knowledge_nexus_search: space_id=%s query_len=%d top_k=%d api_key=%s",
            space_id,
            len(query),
            effective_top_k,
            _mask_api_key(nexus_api_key),
        )

        try:
            timeout = httpx.Timeout(timeout_seconds)
            async with httpx.AsyncClient(timeout=timeout) as client:
                response = await client.post(url, headers=headers, json=body)
        except httpx.TimeoutException:
            logger.warning("knowledge_nexus_search timed out after %ss", timeout_seconds)
            return {
                "status": "failed",
                "error": f"Nexus search timed out after {timeout_seconds}s.",
            }
        except httpx.RequestError as exc:
            logger.warning("knowledge_nexus_search network error: %s", exc)
            return {
                "status": "failed",
                "error": f"Network error reaching Nexus: {exc}",
            }
        except Exception as exc:  # noqa: BLE001
            # Use logger.error (no exc_info) — exception traceback may include
            # local frames that reference nexus_api_key.
            logger.error("knowledge_nexus_search unexpected error: %s", type(exc).__name__)
            return {"status": "failed", "error": f"Unexpected error: {exc!s}"}

        status_code = response.status_code
        logger.info(
            "knowledge_nexus_search response: space_id=%s status=%d",
            space_id,
            status_code,
        )

        if status_code == 200:
            try:
                payload = response.json()
            except ValueError:
                return {
                    "status": "failed",
                    "error": "Nexus returned a non-JSON 200 response.",
                }
            raw_results: List[Dict[str, Any]] = payload.get("results") or []
            slim: List[Dict[str, Any]] = [
                {
                    "doc_title": item.get("doc_title"),
                    "content": item.get("content"),
                    "content_type": item.get("content_type"),
                    "final_score": item.get("final_score"),
                }
                for item in raw_results
            ]
            return {"status": "success", "total": len(slim), "results": slim}

        if status_code == 400:
            try:
                error_msg = response.json().get("error") or response.text
            except ValueError:
                error_msg = response.text
            return {"status": "failed", "error": f"Bad request: {error_msg}"}

        if status_code == 401:
            return {
                "status": "failed",
                "error": "Unauthorized: check the Nexus API key for this agent's "
                "Knowledge integration.",
            }

        if status_code == 403:
            return {
                "status": "failed",
                "error": f"Forbidden: API key does not have access to space_id={space_id}.",
            }

        if status_code == 429:
            return {
                "status": "failed",
                "error": "Rate limit exceeded on Nexus Knowledge API. Try again shortly.",
            }

        snippet = (response.text or "")[:300]
        return {
            "status": "failed",
            "error": f"Nexus error: {status_code} - {snippet}",
        }

    knowledge_nexus_search.__name__ = "knowledge_nexus_search"

    return FunctionTool(func=knowledge_nexus_search)
