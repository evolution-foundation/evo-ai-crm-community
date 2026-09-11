"""
Typebot provider service for external agent integration.
"""

import logging
import json
from typing import Dict, Any, Optional, List, Tuple, Union
import httpx

logger = logging.getLogger(__name__)


class TypebotService:
    """Service for integrating with Typebot."""

    _session_cache: Dict[str, Dict[str, Optional[str]]] = {}
    _structured_prefix = "EVO_STRUCTURED:"

    def __init__(self, config: Dict[str, Any]):
        """
        Initialize Typebot service.

        Args:
            config: Configuration dictionary with:
                - url: Base URL of Typebot instance
                - typebot: Public ID of the typebot
                - apiVersion: API version ('latest' or legacy version)
        """
        self.url = config.get("url")
        self.typebot = config.get("typebot")
        self.api_version = config.get("apiVersion", "latest")
        self.integration_config = config
        self.is_only_registering = bool(config.get("isOnlyRegistering")) if isinstance(config, dict) else False
        self._cache_ns = f"{self.url}:{self.typebot}"
        
        if not self.url:
            raise ValueError("Typebot url is required")
        if not self.typebot:
            raise ValueError("Typebot typebot ID is required")

    async def start_session(
        self,
        session_id: str,
        context: Optional[Dict[str, Any]] = None,
    ) -> Optional[Dict[str, Optional[str]]]:
        """
        Start a new Typebot session.

        Args:
            session_id: Session identifier
            context: Optional context variables

        Returns:
            Typebot session ID or None
        """
        prefilled = {
            "remoteJid": context.get("remoteJid", "") if context else "",
            "pushName": context.get("pushName", "") if context else "",
            "instanceName": context.get("instanceName", "") if context else "",
            "serverUrl": context.get("serverUrl", "") if context else "",
            "apiKey": context.get("apiKey", "") if context else "",
            "ownerJid": context.get("ownerJid", "") if context else "",
        }

        if self.api_version == "latest":
            endpoint = f"{self.url}/api/v1/typebots/{self.typebot}/startChat"
            payload = {
                "resultId": session_id,
                "isOnlyRegistering": self.is_only_registering,
                "prefilledVariables": prefilled,
                "textBubbleContentFormat": "richText",
            }
        else:
            endpoint = f"{self.url}/api/v1/sendMessage"
            payload = {
                "startParams": {
                    "publicId": self.typebot,
                    "prefilledVariables": prefilled,
                },
            }

        try:
            async with httpx.AsyncClient(timeout=30.0) as client:
                response = await client.post(endpoint, json=payload)
                response.raise_for_status()
                response_data = response.json()
                typebot_session_id = response_data.get("sessionId")
                if not typebot_session_id:
                    logger.error("Typebot startChat response missing sessionId")
                    return None

                reply_id = None
                input_obj = response_data.get("input") if isinstance(response_data, dict) else None
                if isinstance(input_obj, dict):
                    reply_id = input_obj.get("id")

                initial_messages = response_data.get("messages", [])
                initial_text = self._format_messages(initial_messages) if initial_messages else ""
                if isinstance(input_obj, dict):
                    logger.debug(f"[Typebot startChat] input type='{input_obj.get('type')}' keys={list(input_obj.keys())}")
                initial_structured_input = self._extract_structured_input(input_obj)
                logger.debug(f"[Typebot startChat] structured_input found: {initial_structured_input is not None}")
                input_block = self._format_input_block(input_obj)
                if input_block:
                    initial_text = (initial_text.strip() + "\n\n" + input_block).strip() if initial_text else input_block

                return {
                    "session_id": typebot_session_id,
                    "reply_id": reply_id,
                    "initial_text": initial_text,
                    "initial_structured_input": json.dumps(initial_structured_input) if initial_structured_input else None,
                }
        except Exception as e:
            logger.error(f"Error starting Typebot session: {e}")
            return None

    async def send_message(
        self,
        message: str,
        session_id: str,
        context: Optional[Dict[str, Any]] = None,
    ) -> Union[str, Dict[str, Any]]:
        """
        Send a message to Typebot and get the response.

        Args:
            message: User message
            session_id: ADK session ID (used as correlation, not Typebot session)
            context: Optional context variables

        Returns:
            Formatted response text from Typebot messages
        """
        cache_key = f"{self._cache_ns}:{session_id or 'default'}"
        session_info = TypebotService._session_cache.get(cache_key)
        logger.info(f"Typebot send_message: session_id={session_id!r} cache_hit={session_info is not None}")

        if session_info:
            try:
                response_text, next_reply_id, structured_input = await self._continue_chat(
                    session_info["session_id"],
                    message,
                    session_info.get("reply_id"),
                )
                session_info["reply_id"] = next_reply_id
                return self._build_structured_response(response_text, structured_input)
            except Exception as e:
                if "404" in str(e):
                    logger.info("Typebot session expired, starting new one")
                    TypebotService._session_cache.pop(cache_key, None)
                    session_info = None
                else:
                    raise

        if not session_info:
            session_info = await self.start_session(session_id or cache_key, context)
            if not session_info:
                raise Exception("Failed to start Typebot session")
            TypebotService._session_cache[cache_key] = session_info

        initial_text = session_info.pop("initial_text", "") or ""
        initial_structured_input_raw = session_info.pop("initial_structured_input", None)
        initial_structured_input = None
        if initial_structured_input_raw:
            try:
                initial_structured_input = json.loads(initial_structured_input_raw)
            except Exception:
                initial_structured_input = None

        if initial_text and session_info.get("reply_id"):
            logger.debug("Typebot new session: returning greeting, waiting for user input")
            return self._build_structured_response(initial_text, initial_structured_input)

        response_text, next_reply_id, structured_input = await self._continue_chat(
            session_info["session_id"],
            message,
            session_info.get("reply_id"),
        )
        session_info["reply_id"] = next_reply_id

        if initial_text:
            combined = (initial_text.strip() + "\n\n" + response_text.strip()).strip()
            return self._build_structured_response(combined, structured_input)
        return self._build_structured_response(response_text, structured_input)

    async def _continue_chat(
        self,
        typebot_session_id: str,
        message: str,
        reply_id: Optional[str] = None,
    ) -> Tuple[str, Optional[str], Optional[Dict[str, Any]]]:
        """Continue an existing Typebot chat session."""
        actual_session_id = typebot_session_id

        if self.api_version == "latest":
            metadata: Dict[str, Any] = {}
            if reply_id:
                metadata["replyId"] = reply_id

            message_payload = {
                "type": "text",
                "text": message,
                "metadata": metadata,
                "attachedFileUrls": [],
            }
            endpoint = f"{self.url}/api/v1/sessions/{actual_session_id}/continueChat"
            payload = {
                "message": message_payload,
                "textBubbleContentFormat": "richText",
            }
        else:
            endpoint = f"{self.url}/api/v1/sendMessage"
            payload = {
                "message": message,
                "sessionId": actual_session_id,
            }

        try:
            async with httpx.AsyncClient(timeout=30.0) as client:
                response = await client.post(endpoint, json=payload)
                response.raise_for_status()
                response_data = response.json()

                # Process messages array and format text
                messages = response_data.get("messages", [])
                next_input = response_data.get("input") if isinstance(response_data, dict) else None
                next_reply_id = next_input.get("id") if isinstance(next_input, dict) else None
                if isinstance(next_input, dict):
                    logger.debug(f"[Typebot] input type='{next_input.get('type')}' keys={list(next_input.keys())}")
                formatted = self._format_messages(messages)
                structured_input = self._extract_structured_input(next_input)
                logger.debug(f"[Typebot] structured_input found: {structured_input is not None}")
                input_block = self._format_input_block(next_input)
                if input_block:
                    formatted = (formatted.strip() + "\n\n" + input_block).strip() if formatted else input_block
                return formatted, next_reply_id, structured_input
        except httpx.HTTPStatusError as e:
            logger.error(f"Typebot API error: {e.response.status_code} - {e.response.text}")
            raise Exception(f"Typebot API error: {e.response.status_code}")
        except Exception as e:
            logger.error(f"Error calling Typebot: {e}")
            raise

    def _build_structured_response(
        self,
        text: str,
        structured_input: Optional[Dict[str, Any]] = None,
    ) -> Union[str, Dict[str, Any]]:
        if structured_input:
            return {"text": text, "structured": {"input": structured_input}}
        return text

    def _extract_structured_input(self, input_obj: Optional[Dict[str, Any]]) -> Optional[Dict[str, Any]]:
        if not isinstance(input_obj, dict):
            return None

        input_type = str(input_obj.get("type") or "").strip()
        input_type_norm = input_type.lower()

        if "choice" in input_type_norm:
            return self._parse_select_input(input_obj, source_type=input_type)

        if "button" in input_type_norm:
            return self._parse_select_input(input_obj, source_type=input_type)

        if input_type_norm == "rating":
            return self._parse_rating_input(input_obj, source_type=input_type)

        return None

    def _parse_select_input(self, input_obj: Dict[str, Any], source_type: str) -> Optional[Dict[str, Any]]:
        raw_items: Any = self._find_items_list(input_obj)

        if not isinstance(raw_items, list) or not raw_items:
            return None

        items: List[Dict[str, str]] = []
        for item in raw_items:
            if isinstance(item, str):
                title = item.strip()
                if title:
                    items.append({"title": title, "value": title})
                continue

            if not isinstance(item, dict):
                continue

            title = (
                (item.get("content") or item.get("title") or item.get("label") or item.get("text") or "")
                .strip()
            )
            if not title:
                continue

            value = (item.get("internalValue") or item.get("value") or item.get("id") or title)
            value = str(value).strip() if value is not None else title
            items.append({"title": title, "value": value})

        if not items:
            return None

        options = input_obj.get("options") if isinstance(input_obj.get("options"), dict) else {}
        is_multiple = bool(options.get("isMultipleChoice")) if isinstance(options, dict) else False

        return {
            "type": "select",
            "sourceType": source_type,
            "isMultiple": is_multiple,
            "items": items,
        }

    def _find_items_list(self, input_obj: Dict[str, Any]) -> Any:
        direct_candidates = [
            input_obj.get("items"),
            input_obj.get("choices"),
            input_obj.get("buttons"),
            input_obj.get("options"),
        ]

        options = input_obj.get("options")
        if isinstance(options, dict):
            direct_candidates.extend(
                [
                    options.get("items"),
                    options.get("choices"),
                    options.get("buttons"),
                    options.get("rows"),
                    options.get("options"),
                ]
            )

        for candidate in direct_candidates:
            if isinstance(candidate, list) and candidate:
                return candidate

        visited: set[int] = set()

        def walk(value: Any) -> Optional[List[Any]]:
            if isinstance(value, dict):
                obj_id = id(value)
                if obj_id in visited:
                    return None
                visited.add(obj_id)

                for k, v in value.items():
                    if isinstance(v, list) and v and self._looks_like_items_list(v):
                        return v
                    found = walk(v)
                    if found is not None:
                        return found
            elif isinstance(value, list):
                for v in value:
                    found = walk(v)
                    if found is not None:
                        return found
            return None

        found = walk(input_obj)
        return found

    def _looks_like_items_list(self, items: List[Any]) -> bool:
        sample = items[:5]
        for item in sample:
            if isinstance(item, str) and item.strip():
                return True
            if isinstance(item, dict):
                keys = {str(k).lower() for k in item.keys()}
                if keys & {"content", "title", "label", "text"}:
                    return True
        return False

    def _parse_rating_input(self, input_obj: Dict[str, Any], source_type: str) -> Optional[Dict[str, Any]]:
        options = input_obj.get("options") if isinstance(input_obj.get("options"), dict) else {}
        max_value = None
        if isinstance(options, dict):
            max_value = options.get("length") or options.get("max")
        try:
            max_n = int(max_value) if max_value is not None else 5
        except Exception:
            max_n = 5

        if max_n <= 0:
            return None

        items = [{"title": str(i), "value": str(i)} for i in range(1, max_n + 1)]
        return {
            "type": "select",
            "sourceType": source_type,
            "isMultiple": False,
            "items": items,
        }

    def _format_input_block(self, input_obj: Optional[Dict[str, Any]]) -> str:
        """
        Format a Typebot input block (choice, pictureChoice) as a numbered list.

        Returns empty string for free-text inputs (text, number, email, etc.)
        """
        if not isinstance(input_obj, dict):
            return ""

        input_type = input_obj.get("type", "")
        structured_input = self._extract_structured_input(input_obj)
        if structured_input and structured_input.get("type") == "select":
            items = structured_input.get("items", [])
            lines = []
            for i, item in enumerate(items, 1):
                title = (item.get("title") or "").strip()
                if title:
                    lines.append(f"{i}. {title}")
            return "\n".join(lines)

        if "choice" in input_type.lower() or "button" in input_type.lower():
            items = input_obj.get("items", [])
            lines = []
            for i, item in enumerate(items, 1):
                content = (item.get("content") or item.get("title") or item.get("label") or "").strip()
                if content:
                    lines.append(f"{i}. {content}")
            return "\n".join(lines)

        if input_type == "pictureChoice":
            items = input_obj.get("items", [])
            lines = []
            for i, item in enumerate(items, 1):
                title = (item.get("title") or "").strip()
                pic_src = (item.get("pictureSrc") or "").strip()
                if title and pic_src:
                    lines.append(f"{i}. {title}\n   {pic_src}")
                elif title:
                    lines.append(f"{i}. {title}")
            return "\n".join(lines)

        return ""

    def _format_messages(self, messages: List[Dict[str, Any]]) -> str:
        """
        Format Typebot messages array into plain text.

        Args:
            messages: Array of Typebot message objects

        Returns:
            Formatted text string
        """
        formatted_parts = []
        
        for message in messages:
            msg_type = message.get("type")
            
            if msg_type == "text":
                content_obj = message.get("content") if isinstance(message.get("content"), dict) else {}
                rich_text = content_obj.get("richText", []) if isinstance(content_obj, dict) else []

                if isinstance(rich_text, list) and rich_text:
                    for text_block in rich_text:
                        if isinstance(text_block, dict):
                            text_content = self._extract_text_from_rich_text(text_block)
                            if text_content:
                                formatted_parts.append(text_content)

                plain_text = content_obj.get("plainText") if isinstance(content_obj, dict) else None
                if plain_text and isinstance(plain_text, str):
                    formatted_parts.append(plain_text.strip())
            elif msg_type == "image":
                url = message.get("content", {}).get("url", "")
                if url:
                    formatted_parts.append(f"[Image: {url}]")
            elif msg_type == "video":
                url = message.get("content", {}).get("url", "")
                if url:
                    formatted_parts.append(f"[Video: {url}]")
            elif msg_type == "audio":
                url = message.get("content", {}).get("url", "")
                if url:
                    formatted_parts.append(f"[Audio: {url}]")
        
        return "\n".join(formatted_parts)

    def _extract_text_from_rich_text(self, element: Dict[str, Any]) -> str:
        """Recursively extract text from rich text element."""
        own_text = element.get("text") if isinstance(element.get("text"), str) else ""
        node_type = element.get("type") if isinstance(element.get("type"), str) else ""
        node_type_norm = node_type.lower()

        children = element.get("children", [])
        child_text = ""
        if isinstance(children, list):
            for child in children:
                if isinstance(child, dict):
                    child_text += self._extract_text_from_rich_text(child)

        if node_type_norm == "a":
            href = element.get("href") or element.get("url")
            label = (own_text + child_text).strip()
            if href and label:
                return f"{label} ({href})"
            if label:
                return label
            return str(href) if href else ""

        text = own_text + child_text

        if node_type_norm == "li":
            text = text.strip() + "\n"
        elif node_type_norm == "p":
            text = text.strip() + "\n"
        elif node_type_norm == "ul":
            lines = [line.strip() for line in text.split("\n") if line.strip()]
            text = ("\n".join(f"- {line}" for line in lines) + ("\n" if lines else ""))
        elif node_type_norm == "ol":
            lines = [line.strip() for line in text.split("\n") if line.strip()]
            text = ("\n".join(f"{i + 1}. {line}" for i, line in enumerate(lines)) + ("\n" if lines else ""))

        formats = ""
        if element.get("bold"):
            formats += "*"
        if element.get("italic"):
            formats += "_"
        if element.get("underline"):
            formats += "~"

        if formats and text:
            text = f"{formats}{text}{formats[::-1]}"

        return text
