"""
Builder for External agents that integrate with external providers.
"""

from typing import Tuple, Optional, List
from src.schemas.schemas import Agent
from src.utils.logger import setup_logger
from src.services.adk.agents.external_agent import ExternalAgent
from src.services.agent_service import get_agent_integration_by_provider
from src.services.adk.integration_credentials import (
    DatabaseCredentialVault,
    apply_vault_credential,
)
from src.utils.crypto import decrypt_api_key
from sqlalchemy.orm import Session

logger = setup_logger(__name__)


class ExternalAgentBuilder:
    """Builder class for External agents."""

    def __init__(self, db: Session):
        self.db = db

    async def build_external_agent(
        self, root_agent: Agent, processed_agents: set = None
    ) -> Tuple[ExternalAgent, Optional[List[str]]]:
        """Build an external agent with its sub-agents."""
        logger.debug(f"Creating External agent: {root_agent.name}")

        agent_config = root_agent.config or {}

        # Get provider from config
        provider = agent_config.get("provider")
        if not provider:
            raise ValueError("provider is required for External agents")

        # Validate provider
        valid_providers = ["flowise", "n8n", "typebot", "dify", "openai"]
        if provider not in valid_providers:
            raise ValueError(
                f"Invalid provider: {provider}. Must be one of: {', '.join(valid_providers)}"
            )

        state_params = []

        try:
            # Get integration configuration from database
            integration_config = await get_agent_integration_by_provider(
                self.db,
                root_agent.id,
                provider,
            )

            if not integration_config:
                raise ValueError(
                    f"Integration not found for provider '{provider}'. "
                    "Please configure the integration first."
                )

            # when the integration points at the credential
            # vault, the secret comes from there; otherwise the inline value is
            # used exactly as before, so nothing breaks before the migration.
            integration_config = apply_vault_credential(
                provider,
                integration_config,
                vault=DatabaseCredentialVault(self.db),
                decrypt=decrypt_api_key,
            )

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

            # Create the External agent
            external_agent = ExternalAgent(
                name=root_agent.name,
                provider=provider,
                integration_config=integration_config,
                db=self.db,
                sub_agents=sub_agents,
            )

            logger.debug(f"External agent created successfully: {root_agent.name}")

            return external_agent, state_params

        except Exception as e:
            logger.error(f"Error building External agent: {str(e)}")
            raise ValueError(f"Error building External agent: {str(e)}")
