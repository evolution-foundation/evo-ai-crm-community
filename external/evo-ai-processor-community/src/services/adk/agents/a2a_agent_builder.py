"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: a2a_agent_builder.py                                                  │
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
from google.adk.agents import BaseAgent
from src.schemas.schemas import Agent
from src.utils.logger import setup_logger
from src.services.adk.agents.a2a_agent import A2ACustomAgent
from sqlalchemy.orm import Session
from .agent_utils import get_sub_agents

logger = setup_logger(__name__)


class A2AAgentBuilder:
    """Builder class for A2A agents."""

    def __init__(self, db: Session):
        self.db = db

    async def build_a2a_agent(
        self, root_agent: Agent, processed_agents: set = None
    ) -> Tuple[BaseAgent, Optional[List[str]]]:
        """Build an A2A agent with its sub-agents."""
        logger.debug(f"Creating A2A agent from {root_agent.card_url}")

        if not root_agent.card_url:
            raise ValueError("card_url is required for a2a agents")

        state_params = []

        try:
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

            config = root_agent.config or {}
            timeout = config.get("timeout", 300)

            a2a_agent = A2ACustomAgent(
                name=root_agent.name,
                card_url=root_agent.card_url,
                timeout=timeout,
                description=root_agent.description
                or f"A2A Agent for {root_agent.name}",
                sub_agents=sub_agents,
            )

            logger.debug(
                f"A2A agent created successfully: {root_agent.name} ({root_agent.card_url})"
            )

            return a2a_agent, state_params

        except Exception as e:
            logger.error(f"Error building A2A agent: {str(e)}")
            raise ValueError(f"Error building A2A agent: {str(e)}")
