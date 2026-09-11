"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: agent_builder.py                                                      │
│ Developed by: Davidson Gomes                                                 │
│ Creation date: May 13, 2025                                                  │
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

from typing import List, Tuple, Union, Optional
from google.adk.agents.llm_agent import LlmAgent
from google.adk.agents import SequentialAgent, ParallelAgent, LoopAgent, BaseAgent
from src.schemas.schemas import Agent
from src.utils.logger import setup_logger
from src.services.adk.agents.llm_agent_builder import LlmAgentBuilder
from src.services.adk.agents.a2a_agent_builder import A2AAgentBuilder
from src.services.adk.agents.workflow_agent_builder import WorkflowAgentBuilder
from src.services.adk.agents.task_agent_builder import TaskAgentBuilder
from src.services.adk.agents.external_agent_builder import ExternalAgentBuilder
from src.services.adk.agents.composite_agent_builder import CompositeAgentBuilder
from src.services.adk.agents.a2a_agent import A2ACustomAgent
from src.services.adk.agents.workflow_agent import WorkflowAgent
from src.services.adk.agents.task_agent import TaskAgent
from src.services.adk.agents.external_agent import ExternalAgent
from sqlalchemy.orm import Session

logger = setup_logger(__name__)


class AgentBuilder:
    """Main agent builder that coordinates all specific builders."""

    def __init__(self, db: Session):
        self.db = db
        self.llm_builder = LlmAgentBuilder(db)
        self.a2a_builder = A2AAgentBuilder(db)
        self.workflow_builder = WorkflowAgentBuilder(db)
        self.task_builder = TaskAgentBuilder(db)
        self.external_builder = ExternalAgentBuilder(db)
        self.composite_builder = CompositeAgentBuilder(db)

    async def build_llm_agent(
        self,
        root_agent: Agent,
        processed_agents: set = None,
        enabled_tools: List[str] = [],
    ) -> Tuple[LlmAgent, Optional[List[str]]]:
        """Build an LLM agent with its sub-agents."""
        return await self.llm_builder.build_llm_agent(
            root_agent, processed_agents, enabled_tools
        )

    async def build_a2a_agent(
        self, root_agent: Agent, processed_agents: set = None
    ) -> Tuple[BaseAgent, Optional[List[str]]]:
        """Build an A2A agent with its sub-agents."""
        return await self.a2a_builder.build_a2a_agent(root_agent, processed_agents)

    async def build_workflow_agent(
        self, root_agent: Agent, processed_agents: set = None
    ) -> Tuple[WorkflowAgent, Optional[List[str]]]:
        """Build a workflow agent with its sub-agents."""
        return await self.workflow_builder.build_workflow_agent(
            root_agent, processed_agents
        )

    async def build_task_agent(
        self, root_agent: Agent, processed_agents: set = None
    ) -> Tuple[TaskAgent, Optional[List[str]]]:
        """Build a task agent with its sub-agents."""
        return await self.task_builder.build_task_agent(root_agent, processed_agents)

    async def build_external_agent(
        self, root_agent: Agent, processed_agents: set = None
    ) -> Tuple[ExternalAgent, Optional[List[str]]]:
        """Build an external agent with its sub-agents."""
        return await self.external_builder.build_external_agent(root_agent, processed_agents)

    async def build_composite_agent(
        self, root_agent: Agent, processed_agents: set = None
    ) -> Tuple[SequentialAgent | ParallelAgent | LoopAgent, Optional[List[str]]]:
        """Build a composite agent (Sequential, Parallel or Loop) with its sub-agents."""
        return await self.composite_builder.build_composite_agent(
            root_agent, processed_agents
        )

    async def build_agent(
        self,
        root_agent: Agent,
        processed_agents: set = None,
        enabled_tools: List[str] = [],
    ) -> Tuple[
        Union[
            LlmAgent,
            SequentialAgent,
            ParallelAgent,
            LoopAgent,
            A2ACustomAgent,
            WorkflowAgent,
            TaskAgent,
            ExternalAgent,
        ],
        Optional[List[str]],
    ]:
        """Build the appropriate agent based on the type of the root agent."""
        if root_agent.type == "llm":
            return await self.build_llm_agent(
                root_agent, processed_agents, enabled_tools
            )
        elif root_agent.type == "a2a":
            return await self.build_a2a_agent(root_agent, processed_agents)
        elif root_agent.type == "workflow":
            return await self.build_workflow_agent(root_agent, processed_agents)
        elif root_agent.type == "task":
            return await self.build_task_agent(root_agent, processed_agents)
        elif root_agent.type == "external":
            return await self.build_external_agent(root_agent, processed_agents)
        else:
            return await self.build_composite_agent(root_agent, processed_agents)
