"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: task_agent_builder.py                                                 │
│ Developed by: Davidson Gomes                                                 │
│ Creation date: May 17, 2025                                                  │
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

from typing import Tuple, Optional, List
from src.schemas.schemas import Agent
from src.schemas.agent_config import AgentTask
from src.utils.adk_utils import extract_state_params
from src.utils.logger import setup_logger
from src.services.adk.agents.task_agent import TaskAgent
from sqlalchemy.orm import Session

logger = setup_logger(__name__)


class TaskAgentBuilder:
    """Builder class for Task agents."""

    def __init__(self, db: Session):
        self.db = db

    async def build_task_agent(
        self, root_agent: Agent, processed_agents: set = None
    ) -> Tuple[TaskAgent, Optional[List[str]]]:
        """Build a task agent with its sub-agents."""
        logger.debug(f"Creating Task agent: {root_agent.name}")

        agent_config = root_agent.config or {}

        if not agent_config.get("tasks"):
            raise ValueError("tasks are required for Task agents")

        state_params = []

        try:
            # Get sub-agents if there are any
            sub_agents = []
            if root_agent.config.get("sub_agents"):
                # Import here to avoid circular import
                from .agent_utils import get_sub_agents

                sub_agents, params = await get_sub_agents(
                    self.db,
                    root_agent.config.get("sub_agents"),
                    root_agent.type,  # parent_type
                    root_agent.config,  # parent_config
                    processed_agents=processed_agents,
                )
                state_params.extend(params)

            # Additional configurations
            config = root_agent.config or {}

            # Convert tasks to the expected format by TaskAgent
            tasks = []
            for task_config in config.get("tasks", []):
                state_params.extend(
                    extract_state_params(task_config.get("description"))
                )

                task = AgentTask(
                    agent_id=task_config.get("agent_id"),
                    description=task_config.get("description", ""),
                    expected_output=task_config.get("expected_output", ""),
                    enabled_tools=task_config.get("enabled_tools", []),
                )
                tasks.append(task)

            # Create the Task agent
            task_agent = TaskAgent(
                name=root_agent.name,
                tasks=tasks,
                db=self.db,
                sub_agents=sub_agents,
            )

            logger.debug(f"Task agent created successfully: {root_agent.name}")

            return task_agent, state_params

        except Exception as e:
            logger.error(f"Error building Task agent: {str(e)}")
            raise ValueError(f"Error building Task agent: {str(e)}")
