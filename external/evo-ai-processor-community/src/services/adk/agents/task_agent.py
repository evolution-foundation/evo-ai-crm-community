"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: task_agent.py                                                         │
│ Developed by: Davidson Gomes                                                 │
│ Creation date: May 14, 2025                                                  │
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

from attr import Factory
from google.adk.agents import BaseAgent
from google.adk.agents.invocation_context import InvocationContext
from google.adk.events import Event
from google.genai.types import Content, Part
from src.services.agent_service import get_agent

from sqlalchemy.orm import Session

from typing import AsyncGenerator, List

from src.schemas.agent_config import AgentTask


class TaskAgent(BaseAgent):
    """
    Custom agent that implements the Task function.

    This agent implements the interaction with an external Task service.
    """

    # Field declarations for Pydantic
    tasks: List[AgentTask]
    db: Session

    def __init__(
        self,
        name: str,
        tasks: List[AgentTask],
        db: Session,
        sub_agents: List[BaseAgent] = [],
        **kwargs,
    ):
        """
        Initialize the Task agent.

        Args:
            name: Agent name
            tasks: List of tasks to be executed
            db: Database session
            sub_agents: List of sub-agents to be executed after the Task agent
        """
        # Initialize base class
        super().__init__(
            name=name,
            tasks=tasks,
            db=db,
            sub_agents=sub_agents,
            **kwargs,
        )

    async def _run_async_impl(
        self, ctx: InvocationContext
    ) -> AsyncGenerator[Event, None]:
        """
        Implementation of the Task agent.

        This method follows the pattern of implementing custom agents,
        sending the user's message to the Task service and monitoring the response.
        """
        try:
            # Extract the user's message from the context
            user_message = None

            # Search for the user's message in the session events
            if ctx.session and hasattr(ctx.session, "events") and ctx.session.events:
                for event in reversed(ctx.session.events):
                    if event.author == "user" and event.content and event.content.parts:
                        user_message = event.content.parts[0].text
                        print("Message found in session events")
                        break

            # Check in the session state if the message was not found in the events
            if not user_message and ctx.session and ctx.session.state:
                if "user_message" in ctx.session.state:
                    user_message = ctx.session.state["user_message"]
                elif "message" in ctx.session.state:
                    user_message = ctx.session.state["message"]

            if not user_message:
                yield Event(
                    author=self.name,
                    content=Content(
                        role="agent",
                        parts=[Part(text="User message not found")],
                    ),
                )
                return

            # Start the agent status
            yield Event(
                author=self.name,
                content=Content(
                    role="agent",
                    parts=[Part(text=f"Starting {self.name} task processing...")],
                ),
            )

            try:
                # Replace any {content} in the task descriptions with the user's input
                task = self.tasks[0]
                task.description = task.description.replace("{content}", user_message)
                task.enabled_tools = task.enabled_tools or []

                agent = await get_agent(self.db, task.agent_id)

                if not agent:
                    yield Event(
                        author=self.name,
                        content=Content(parts=[Part(text="Agent not found")]),
                    )
                    return

                # Prepare task instructions
                task_message_instructions = f"""
                <task>
                    <instructions>
                        Execute the following task:
                    </instructions>
                    <description>{task.description}</description>
                    <expected_output>{task.expected_output}</expected_output>
                </task>
                """

                # Send task instructions as an event
                yield Event(
                    author=f"{self.name} - Task executor",
                    content=Content(
                        role="user",
                        parts=[Part(text=task_message_instructions)],
                    ),
                )

                from src.services.adk.agent_builder import AgentBuilder

                print(f"Building agent in Task agent: {agent.name}")
                agent_builder = AgentBuilder(self.db)
                root_agent, _ = await agent_builder.build_agent(
                    agent, task.enabled_tools
                )

                # Store task instructions in context for reference by sub-agents
                ctx.session.state["task_instructions"] = task_message_instructions

                # Process the agent responses
                try:
                    async for event in root_agent.run_async(ctx):
                        yield event
                except GeneratorExit:
                    print("Generator was closed prematurely, handling cleanup...")
                    # Allow the exception to propagate after cleanup
                    raise
                except Exception as e:
                    error_msg = f"Error during agent execution: {str(e)}"
                    print(error_msg)
                    yield Event(
                        author=self.name,
                        content=Content(
                            role="agent",
                            parts=[Part(text=error_msg)],
                        ),
                    )

            except Exception as e:
                error_msg = f"Error sending request: {str(e)}"
                print(error_msg)
                print(f"Error type: {type(e).__name__}")
                print(f"Error details: {str(e)}")

                yield Event(
                    author=self.name,
                    content=Content(role="agent", parts=[Part(text=error_msg)]),
                )

        except Exception as e:
            # Handle any uncaught error
            print(f"Error executing Task agent: {str(e)}")
            yield Event(
                author=self.name,
                content=Content(
                    role="agent",
                    parts=[Part(text=f"Error interacting with Task agent: {str(e)}")],
                ),
            )
        finally:
            # Execute sub-agents only if no exception occurred
            try:
                if "e" not in locals():
                    for sub_agent in self.sub_agents:
                        async for event in sub_agent.run_async(ctx):
                            yield event
            except Exception as sub_e:
                print(f"Error executing sub-agents: {str(sub_e)}")
                # We don't yield a new event here to avoid raising during cleanup
