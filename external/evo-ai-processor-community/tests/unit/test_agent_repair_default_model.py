"""Both repair entry points stamp a model and commit, so a retired default here is
written into the customer's agent rather than merely tried once."""

from __future__ import annotations

import asyncio
import uuid
from types import SimpleNamespace
from unittest.mock import MagicMock

from src.services.agent_service import get_agent, get_agents_by_account

# Spelled out rather than imported from the module under test: an assertion that
# reads the constant back passes whatever the constant rots into.
EXPECTED_MODEL = "openai/gpt-5.6-luna"


def malformed_agent(model=""):
    """Sequential agent with no sub_agents — the shape the repair path catches."""
    return SimpleNamespace(
        id=uuid.uuid4(),
        name="agent",
        type="sequential",
        model=model,
        config={"sub_agents": []},
        folder_id=None,
    )


def db_returning(agent):
    db = MagicMock()
    db.query.return_value.filter.return_value.first.return_value = agent
    query = db.query.return_value
    query.order_by.return_value.offset.return_value.limit.return_value.all.return_value = [
        agent
    ]
    return db


def test_get_agent_repair_stamps_a_model_openai_still_serves():
    agent = malformed_agent()
    db = db_returning(agent)

    result = asyncio.run(get_agent(db, agent.id))

    assert result.type == "llm", "repair did not run"
    assert result.model == EXPECTED_MODEL
    assert db.commit.called, "repair must persist — that is what puts the id in the DB"


def test_get_agents_by_account_repair_stamps_the_same_model():
    agent = malformed_agent()
    db = db_returning(agent)

    agents = get_agents_by_account(db)

    assert agents[0].type == "llm", "repair did not run"
    assert agents[0].model == EXPECTED_MODEL
    assert db.commit.called, "the list path commits too — that is what puts the id in the DB"


def test_repair_keeps_a_model_the_agent_already_has():
    """The customer's running agent is never re-pointed by the repair, whatever
    the state of the model it is on."""
    agent = malformed_agent(model="perplexity/sonar-pro")
    db = db_returning(agent)

    result = asyncio.run(get_agent(db, agent.id))

    # Without this the assertion below is vacuous: a repair path that stopped
    # matching would leave the model untouched and the test would still pass.
    assert result.type == "llm", "repair did not run"
    assert result.model == "perplexity/sonar-pro"
    assert db.commit.called, "the repair still writes — the model just has to survive the write"
