from google.adk.tools import ToolContext
from google.adk.agents import BaseAgent
from google.adk.agents.invocation_context import InvocationContext
from google.adk.events import Event, EventActions
from google.genai.types import Content, Part
from typing import AsyncGenerator


def exit_loop(tool_context: ToolContext) -> str:
    """
    Call this function ONLY when the process indicates no further iterations are needed, signaling the loop should end.

    Args:
        output_key_agent: The key of the output message in the tool context state.
        tool_context: The tool context object.

    Returns:
        The final message from the tool context state.
    """
    # add exit_loop to state equals to yes
    tool_context.state["exit_loop"] = "yes"

    return {
        "status": "success",
        "message": "Called exit_loop and set exit_loop to yes",
    }


class ExitLoopAgent(BaseAgent):
    async def _run_async_impl(
        self, ctx: InvocationContext
    ) -> AsyncGenerator[Event, None]:
        status = ctx.session.state.get("exit_loop", "no")
        should_stop = status == "yes"

        if should_stop and ctx.session.state.get("loop_output"):
            yield Event(
                author=self.name,
                content=Content(
                    parts=[Part(text=ctx.session.state.get("loop_output"))]
                ),
            )
        yield Event(author=self.name, actions=EventActions(escalate=should_stop))
