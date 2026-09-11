"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: composite_agent_builder.py                                            │
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

from typing import Tuple, Optional, List, Union
from google.adk.agents import SequentialAgent, ParallelAgent, LoopAgent
from src.schemas.schemas import Agent
from src.utils.logger import setup_logger
from sqlalchemy.orm import Session

logger = setup_logger(__name__)


class CompositeAgentBuilder:
    """Builder class for composite agents (Sequential, Parallel, Loop)."""

    def __init__(self, db: Session):
        self.db = db

    async def build_composite_agent(
        self, root_agent: Agent, processed_agents: set = None
    ) -> Tuple[Union[SequentialAgent, ParallelAgent, LoopAgent], Optional[List[str]]]:
        """Build a composite agent (Sequential, Parallel or Loop) with its sub-agents."""
        logger.debug(
            f"Processing sub-agents for agent {root_agent.type} (ID: {root_agent.id}, Name: {root_agent.name})"
        )

        state_params = []

        if not root_agent.config.get("sub_agents"):
            logger.error(
                f"Sub_agents configuration not found or empty for agent {root_agent.name}"
            )
            raise ValueError(f"Missing sub_agents configuration for {root_agent.name}")

        logger.debug(
            f"Sub-agents IDs to be processed: {root_agent.config.get('sub_agents', [])}"
        )

        # Import here to avoid circular import
        from .agent_utils import get_sub_agents

        sub_agents, params = await get_sub_agents(
            self.db,
            root_agent.config.get("sub_agents", []),
            root_agent.type,
            root_agent.config,
            processed_agents=processed_agents,
        )
        state_params.extend(params)

        logger.debug(
            f"Sub-agents processed: {len(sub_agents)} of {len(root_agent.config.get('sub_agents', []))}"
        )

        logger.debug(f"Extracted sub-agents: {[agent.name for agent in sub_agents]}")

        if root_agent.type == "sequential":
            logger.debug(f"Creating SequentialAgent with {len(sub_agents)} sub-agents")
            return (
                SequentialAgent(
                    name=root_agent.name,
                    sub_agents=sub_agents,
                    description=root_agent.config.get("description", ""),
                ),
                state_params,
            )
        elif root_agent.type == "parallel":
            logger.debug(f"Creating ParallelAgent with {len(sub_agents)} sub-agents")
            return (
                ParallelAgent(
                    name=root_agent.name,
                    sub_agents=sub_agents,
                    description=root_agent.config.get("description", ""),
                ),
                state_params,
            )
        elif root_agent.type == "loop":
            logger.debug(f"Creating LoopAgent with {len(sub_agents)} sub-agents")
            return (
                LoopAgent(
                    name=root_agent.name,
                    sub_agents=sub_agents,
                    description=root_agent.config.get("description", ""),
                    max_iterations=root_agent.config.get("max_iterations", 5),
                ),
                state_params,
            )
        else:
            raise ValueError(f"Invalid agent type: {root_agent.type}")
