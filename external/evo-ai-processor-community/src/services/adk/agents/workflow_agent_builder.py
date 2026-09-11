"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: workflow_agent_builder.py                                             │
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
from src.utils.logger import setup_logger
from src.services.adk.agents.workflow_agent import WorkflowAgent
from sqlalchemy.orm import Session
from .agent_utils import get_sub_agents

logger = setup_logger(__name__)


class WorkflowAgentBuilder:
    """Builder class for Workflow agents."""

    def __init__(self, db: Session):
        self.db = db

    async def build_workflow_agent(
        self, root_agent: Agent, processed_agents: set = None
    ) -> Tuple[WorkflowAgent, Optional[List[str]]]:
        """Build a workflow agent with its sub-agents."""
        logger.debug(f"Creating Workflow agent from {root_agent.name}")

        agent_config = root_agent.config or {}

        if not agent_config.get("workflow"):
            raise ValueError("workflow is required for workflow agents")

        state_params = []

        try:
            sub_agents = []
            if root_agent.config.get("sub_agents"):
                # Import here to avoid circular import
                from .agent_utils import get_sub_agents

                sub_agents, params = await get_sub_agents(
                    self.db,
                    root_agent.config.get("sub_agents"),
                    root_agent.type,
                    root_agent.config,
                    processed_agents=processed_agents,
                )
                state_params.extend(params)

            config = root_agent.config or {}
            timeout = config.get("timeout", 300)

            workflow_agent = WorkflowAgent(
                name=root_agent.name,
                flow_json=agent_config.get("workflow"),
                timeout=timeout,
                description=root_agent.description
                or f"Workflow Agent for {root_agent.name}",
                sub_agents=sub_agents,
                db=self.db,
            )

            logger.debug(f"Workflow agent created successfully: {root_agent.name}")

            return workflow_agent, state_params

        except Exception as e:
            logger.error(f"Error building Workflow agent: {str(e)}")
            raise ValueError(f"Error building Workflow agent: {str(e)}")
