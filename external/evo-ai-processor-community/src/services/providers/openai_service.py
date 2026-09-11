"""
OpenAI provider service for external agent integration.
"""

import logging
from typing import Dict, Any, Optional, List
import httpx
from openai import OpenAI

logger = logging.getLogger(__name__)


class OpenAIService:
    """Service for integrating with OpenAI Assistants or ChatCompletion API."""

    def __init__(self, config: Dict[str, Any]):
        """
        Initialize OpenAI service.

        Args:
            config: Configuration dictionary with:
                - apiKey: OpenAI API key
                - botType: Type of bot ('assistant' or 'chatCompletion')
                - assistantId: Assistant ID (required for assistant type)
                - model: Model name (required for chatCompletion type)
                - maxTokens: Maximum tokens (optional, default 500)
                - systemMessages: List of system messages (optional)
                - functionUrl: URL for function calls (optional)
        """
        self.api_key = config.get("apiKey")
        self.bot_type = config.get("botType", "assistant")
        self.assistant_id = config.get("assistantId")
        self.model = config.get("model")
        self.max_tokens = config.get("maxTokens", 500)
        self.system_messages = config.get("systemMessages", [])
        self.function_url = config.get("functionUrl")
        
        if not self.api_key:
            raise ValueError("OpenAI apiKey is required")
        if self.bot_type == "assistant" and not self.assistant_id:
            raise ValueError("OpenAI assistantId is required for assistant type")
        if self.bot_type == "chatCompletion" and not self.model:
            raise ValueError("OpenAI model is required for chatCompletion type")
        
        self.client = OpenAI(api_key=self.api_key)

    async def send_message(
        self,
        message: str,
        session_id: str,
        context: Optional[Dict[str, Any]] = None,
    ) -> str:
        """
        Send a message to OpenAI and get the response.

        Args:
            message: User message
            session_id: Thread ID (for assistant) or session identifier
            context: Optional context variables

        Returns:
            Response text from OpenAI
        """
        if self.bot_type == "assistant":
            return await self._process_assistant_message(message, session_id, context)
        else:
            return await self._process_chat_completion(message, session_id, context)

    async def _process_assistant_message(
        self,
        message: str,
        thread_id: str,
        context: Optional[Dict[str, Any]] = None,
    ) -> str:
        """Process message using OpenAI Assistant API."""
        import asyncio
        
        # Create or use existing thread
        if not thread_id or thread_id == "new":
            # Run in executor to avoid blocking
            loop = asyncio.get_event_loop()
            thread = await loop.run_in_executor(
                None,
                lambda: self.client.beta.threads.create()
            )
            thread_id = thread.id
        else:
            # Verify thread exists
            try:
                loop = asyncio.get_event_loop()
                await loop.run_in_executor(
                    None,
                    lambda: self.client.beta.threads.retrieve(thread_id)
                )
            except Exception:
                # Create new thread if invalid
                loop = asyncio.get_event_loop()
                thread = await loop.run_in_executor(
                    None,
                    lambda: self.client.beta.threads.create()
                )
                thread_id = thread.id

        # Add message to thread
        loop = asyncio.get_event_loop()
        await loop.run_in_executor(
            None,
            lambda: self.client.beta.threads.messages.create(
                thread_id,
                role="user",
                content=message,
            )
        )

        # Run the assistant
        loop = asyncio.get_event_loop()
        run = await loop.run_in_executor(
            None,
            lambda: self.client.beta.threads.runs.create(
                thread_id,
                assistant_id=self.assistant_id,
            )
        )

        # Wait for completion (simplified - in production should handle tool calls)
        max_retries = 60
        check_interval = 1.0
        
        for _ in range(max_retries):
            await asyncio.sleep(check_interval)
            loop = asyncio.get_event_loop()
            run_status = await loop.run_in_executor(
                None,
                lambda: self.client.beta.threads.runs.retrieve(thread_id, run.id)
            )
            
            if run_status.status == "completed":
                break
            elif run_status.status in ["failed", "cancelled", "expired"]:
                raise Exception(f"Assistant run {run_status.status}")
            elif run_status.status == "requires_action":
                # Handle tool calls if functionUrl is configured
                if self.function_url and run_status.required_action:
                    await self._handle_tool_calls(thread_id, run.id, run_status.required_action, context)
        
        # Get messages
        loop = asyncio.get_event_loop()
        messages = await loop.run_in_executor(
            None,
            lambda: self.client.beta.threads.messages.list(thread_id)
        )
        
        # Extract response text
        if messages.data:
            message_content = messages.data[0].content
            if message_content and len(message_content) > 0:
                text_content = message_content[0]
                if hasattr(text_content, "text") and hasattr(text_content.text, "value"):
                    return text_content.text.value
        
        return "I couldn't generate a proper response. Please try again."

    async def _process_chat_completion(
        self,
        message: str,
        session_id: str,
        context: Optional[Dict[str, Any]] = None,
    ) -> str:
        """Process message using OpenAI ChatCompletion API."""
        import asyncio
        
        # Build messages array
        messages: List[Dict[str, Any]] = []
        
        # Add system messages
        for sys_msg in self.system_messages:
            messages.append({"role": "system", "content": sys_msg})
        
        # Add user message
        messages.append({"role": "user", "content": message})
        
        # Create completion (run in executor to avoid blocking)
        loop = asyncio.get_event_loop()
        completion = await loop.run_in_executor(
            None,
            lambda: self.client.chat.completions.create(
                model=self.model,
                messages=messages,
                max_tokens=self.max_tokens,
            )
        )
        
        return completion.choices[0].message.content or ""

    async def _handle_tool_calls(
        self,
        thread_id: str,
        run_id: str,
        required_action: Any,
        context: Optional[Dict[str, Any]] = None,
    ):
        """Handle tool calls from assistant (simplified implementation)."""
        import asyncio
        
        if not self.function_url or not required_action.submit_tool_outputs:
            return
        
        tool_calls = required_action.submit_tool_outputs.tool_calls
        tool_outputs = []
        
        for tool_call in tool_calls:
            try:
                async with httpx.AsyncClient() as client:
                    response = await client.post(
                        self.function_url,
                        json={
                            "functionName": tool_call.function.name,
                            "functionArguments": tool_call.function.arguments,
                        },
                    )
                    tool_outputs.append({
                        "tool_call_id": tool_call.id,
                        "output": str(response.json()),
                    })
            except Exception as e:
                logger.error(f"Error calling function: {e}")
                tool_outputs.append({
                    "tool_call_id": tool_call.id,
                    "output": '{"error": "Function call failed"}',
                })
        
        # Submit tool outputs (run in executor to avoid blocking)
        loop = asyncio.get_event_loop()
        await loop.run_in_executor(
            None,
            lambda: self.client.beta.threads.runs.submit_tool_outputs(
                thread_id,
                run_id,
                tool_outputs=tool_outputs,
            )
        )
