"""Unit tests for Custom HTTP Tools — EVO-2125.

Covers the three broken links in the chain: the by-id getter the ADK builder
depends on, the rebuild of tools attached to an agent through `custom_tool_ids`,
and the reserved metadata keys that must never reach the wire.

No database: the session is a fake exposing only the query chain the service
uses.
"""

from __future__ import annotations

import inspect
import uuid
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import pytest
from sqlalchemy.exc import SQLAlchemyError

from src.services import agent_service, custom_tool_service
from src.services.adk.custom_tools import MODES_META_KEYS, CustomToolBuilder
from src.services.adk.tool_builder import ToolBuilder
from src.utils.tool_naming import sanitize_tool_name


MODES_META = {"input": "nothing", "output": "an advice"}

# Tools attached by id are built by CustomToolBuilder; tools stored inline in the
# agent config go through ToolBuilder. Each carries its own _create_http_tool, so
# both have to strip the metadata.
BUILDERS = [CustomToolBuilder, ToolBuilder]


def _fake_db(result=None, raises: Exception | None = None) -> MagicMock:
    """A Session stand-in whose query(...).filter(...).first() is scripted."""

    db = MagicMock()
    query = db.query.return_value.filter.return_value
    if raises is not None:
        query.first.side_effect = raises
    else:
        query.first.return_value = result
    return db


def _tool(name: str = "advice", **overrides) -> SimpleNamespace:
    """A CustomTool row as the ORM model returns it — note: no `is_active`."""

    tool = SimpleNamespace(
        id=uuid.uuid4(),
        name=name,
        description="Gets an advice",
        method="GET",
        endpoint="https://api.adviceslip.com/advice",
        headers={},
        path_params={},
        query_params={},
        body_params={},
        error_handling={},
        values={"lang": "pt", "__evo_modes_meta__": MODES_META},
    )
    for key, value in overrides.items():
        setattr(tool, key, value)
    return tool


class TestGetCustomTool:
    def test_returns_the_row_for_a_known_id(self):
        expected = _tool()
        db = _fake_db(result=expected)

        assert custom_tool_service.get_custom_tool(db, expected.id) is expected

    def test_returns_none_for_an_unknown_id(self):
        assert (
            custom_tool_service.get_custom_tool(_fake_db(result=None), uuid.uuid4())
            is None
        )

    def test_swallows_database_errors(self):
        db = _fake_db(raises=SQLAlchemyError("connection lost"))

        assert custom_tool_service.get_custom_tool(db, uuid.uuid4()) is None

    def test_queries_the_orm_model_not_the_pydantic_schema(self):
        """db.query() must receive a mapped class, or SQLAlchemy raises."""

        from src.models.models import CustomTool as CustomToolModel

        assert custom_tool_service.CustomTool is CustomToolModel


class TestBuildToolsFromIds:
    def test_builds_a_tool_attached_by_id(self):
        tool = _tool()
        with patch.object(custom_tool_service, "get_custom_tool", return_value=tool):
            built = CustomToolBuilder().build_tools(
                {"custom_tool_ids": [str(tool.id)]}, db=_fake_db()
            )

        assert len(built) == 1
        assert built[0].func.__name__ == "advice"

    def test_skips_an_unknown_id_without_breaking_the_build(self):
        with patch.object(custom_tool_service, "get_custom_tool", return_value=None):
            built = CustomToolBuilder().build_tools(
                {"custom_tool_ids": [str(uuid.uuid4())]}, db=_fake_db()
            )

        assert built == []

    def test_requires_a_db_session(self):
        with pytest.raises(ValueError):
            CustomToolBuilder().build_tools({"custom_tool_ids": [str(uuid.uuid4())]})


class TestHttpToolNameSanitization:
    """CRM-499: a custom tool name with a space/accent reached the LLM verbatim
    as tools[].function.name and was rejected (must match ^[a-zA-Z0-9_-]+$),
    breaking the whole turn. Both builders that emit HTTP tools must sanitize
    the __name__ they dispatch by. Reverting the sanitize call at either site
    makes these fail (the raw space survives)."""

    @staticmethod
    def _config(name):
        return {
            "name": name,
            "description": "x",
            "endpoint": "https://example.com",
            "method": "GET",
        }

    @pytest.mark.parametrize("builder_cls", BUILDERS)
    def test_a_space_in_the_name_is_sanitized(self, builder_cls):
        built = builder_cls()._create_http_tool(self._config("testando ferramenta"))
        assert built.func.__name__ == "testando_ferramenta"
        # FunctionTool captures the dispatch name on construction while the
        # declaration is generated from the live __name__: renaming after this
        # point would send one name and answer to another.
        assert built.name == built.func.__name__

    @pytest.mark.parametrize("builder_cls", BUILDERS)
    def test_a_valid_name_is_preserved(self, builder_cls):
        built = builder_cls()._create_http_tool(self._config("get_weather"))
        assert built.func.__name__ == "get_weather"

    @pytest.mark.parametrize("builder_cls", BUILDERS)
    def test_two_names_that_collapse_alike_get_distinct_ones(self, builder_cls):
        builder = builder_cls()
        first = builder._create_http_tool(self._config("minha ferramenta"))
        second = builder._create_http_tool(
            self._config("minha_ferramenta"), {first.name}
        )
        assert (first.name, second.name) == ("minha_ferramenta", "minha_ferramenta_2")


class TestReconstructCustomConfigurations:
    """The agent config carries only the ids; the http_tools are rebuilt on read."""

    def test_rebuilds_http_tools_from_the_attached_ids(self):
        tool = _tool()
        agent = SimpleNamespace(
            id=uuid.uuid4(), config={"custom_tool_ids": [str(tool.id)]}
        )
        db = _fake_db()

        with patch.object(custom_tool_service, "get_custom_tool", return_value=tool):
            agent_service._reconstruct_custom_configurations(db, agent)

        http_tools = agent.config["custom_tools"]["http_tools"]
        assert [t["name"] for t in http_tools] == ["advice"]

    def test_the_expansion_is_never_written_back(self):
        """Persisting it would freeze a copy of the tool inside the agent: the
        guard skips the expansion once http_tools is populated, so the stale copy
        would be served forever and editing the tool would never reach the agent.
        It is a read-path hydration — a GET must not write."""

        tool = _tool()
        agent = SimpleNamespace(
            id=uuid.uuid4(), config={"custom_tool_ids": [str(tool.id)]}
        )
        db = _fake_db()

        with patch.object(custom_tool_service, "get_custom_tool", return_value=tool):
            agent_service._reconstruct_custom_configurations(db, agent)

        db.commit.assert_not_called()

    def test_an_edit_to_the_tool_reaches_the_agent_on_the_next_read(self):
        """The expansion is recomputed from the catalog row on every read, so a
        tool edited in the catalog takes effect without touching the agent."""

        tool = _tool(endpoint="https://api.adviceslip.com/advice")
        agent = SimpleNamespace(
            id=uuid.uuid4(), config={"custom_tool_ids": [str(tool.id)]}
        )

        with patch.object(custom_tool_service, "get_custom_tool", return_value=tool):
            agent_service._reconstruct_custom_configurations(_fake_db(), agent)
        assert agent.config["custom_tools"]["http_tools"][0]["endpoint"] == (
            "https://api.adviceslip.com/advice"
        )

        # the user edits the tool in the catalog, then the agent is read again
        tool.endpoint = "https://api.adviceslip.com/advice/search"
        agent.config["custom_tools"]["http_tools"] = []
        with patch.object(custom_tool_service, "get_custom_tool", return_value=tool):
            agent_service._reconstruct_custom_configurations(_fake_db(), agent)

        assert agent.config["custom_tools"]["http_tools"][0]["endpoint"] == (
            "https://api.adviceslip.com/advice/search"
        )

    def test_the_reserved_metadata_is_not_copied_into_the_agent_config(self):
        tool = _tool()
        agent = SimpleNamespace(
            id=uuid.uuid4(), config={"custom_tool_ids": [str(tool.id)]}
        )

        with patch.object(custom_tool_service, "get_custom_tool", return_value=tool):
            agent_service._reconstruct_custom_configurations(_fake_db(), agent)

        values = agent.config["custom_tools"]["http_tools"][0]["values"]
        assert values == {"lang": "pt"}

    def test_an_unknown_id_is_skipped_not_raised(self):
        agent = SimpleNamespace(
            id=uuid.uuid4(), config={"custom_tool_ids": [str(uuid.uuid4())]}
        )

        with patch.object(custom_tool_service, "get_custom_tool", return_value=None):
            agent_service._reconstruct_custom_configurations(agent=agent, db=_fake_db())

        assert agent.config["custom_tools"]["http_tools"] == []

    def test_is_synchronous(self):
        """get_agents_by_account is sync and calls it without await: as a
        coroutine it would silently never run."""

        assert not inspect.iscoroutinefunction(
            agent_service._reconstruct_custom_configurations
        )


class TestAToolAttachedByIdIsRegisteredOnce:
    """The config the builders receive is the expanded one: it carries the
    custom_tool_ids AND the http_tools those IDs expand to. Reading both sources
    naively registers the same tool under one name several times — the LLM then
    gets N identical function declarations."""

    def _expanded_config(self, tool):
        agent = SimpleNamespace(
            id=uuid.uuid4(), config={"custom_tool_ids": [str(tool.id)]}
        )
        with patch.object(custom_tool_service, "get_custom_tool", return_value=tool):
            agent_service._reconstruct_custom_configurations(_fake_db(), agent)
        return agent.config

    def test_the_expanded_config_builds_exactly_one_tool(self):
        tool = _tool()
        config = self._expanded_config(tool)
        assert config["custom_tool_ids"] and config["custom_tools"]["http_tools"]

        with patch.object(custom_tool_service, "get_custom_tool", return_value=tool):
            built = ToolBuilder().build_tools(config, db=_fake_db())

        assert [t.func.__name__ for t in built] == ["advice"]

    @pytest.mark.parametrize("builder", BUILDERS, ids=lambda b: b.__name__)
    @pytest.mark.parametrize("name", ["testando ferramenta", "my__tool"])
    def test_a_name_that_gets_sanitized_is_still_built_once(self, builder, name):
        """CRM-499: the tool built from the id answers to the sanitized name
        while the expanded copy still carries the raw one. Comparing the two
        spellings let the copy through — the tool was registered twice under a
        single name, which is the same rejected payload by another route."""

        tool = _tool(name)
        config = self._expanded_config(tool)

        with patch.object(custom_tool_service, "get_custom_tool", return_value=tool):
            built = builder().build_tools(config, db=_fake_db())

        assert [t.func.__name__ for t in built] == [sanitize_tool_name(name)]

    def test_an_inline_tool_of_its_own_still_gets_built(self):
        """Only the expanded copies are dropped — a legacy inline tool that is not
        one of the attached IDs must survive."""

        tool = _tool()
        config = self._expanded_config(tool)
        config["custom_tools"]["http_tools"].append(
            {
                "name": "legacy_inline",
                "description": "Configured by hand, not in the catalog",
                "method": "GET",
                "endpoint": "https://example.test/legacy",
                "parameters": {},
                "values": {},
            }
        )

        with patch.object(custom_tool_service, "get_custom_tool", return_value=tool):
            built = ToolBuilder().build_tools(config, db=_fake_db())

        assert sorted(t.func.__name__ for t in built) == ["advice", "legacy_inline"]


@pytest.mark.parametrize("builder", BUILDERS, ids=lambda b: b.__name__)
class TestReservedMetadataKeysNeverReachTheWire:
    def _call(self, builder, tool_config, **kwargs):
        """Build the tool, invoke it, and hand back the intercepted request."""

        built = builder()._create_http_tool(tool_config)
        target = f"{builder.__module__}.requests.request"
        with patch(target) as request:
            request.return_value = MagicMock(status_code=200, json=lambda: {"ok": True})
            built.func(**kwargs)
        return request.call_args.kwargs

    @pytest.mark.parametrize("meta_key", sorted(MODES_META_KEYS))
    def test_metadata_is_not_sent_as_a_query_param(self, builder, meta_key):
        sent = self._call(
            builder,
            {
                "name": "advice",
                "description": "Gets an advice",
                "method": "GET",
                "endpoint": "https://api.adviceslip.com/advice",
                "parameters": {},
                "values": {"lang": "pt", meta_key: MODES_META},
            },
        )

        assert meta_key not in sent["params"]
        assert sent["params"] == {"lang": "pt"}

    @pytest.mark.parametrize("meta_key", sorted(MODES_META_KEYS))
    def test_metadata_is_not_sent_in_the_body(self, builder, meta_key):
        sent = self._call(
            builder,
            {
                "name": "create_note",
                "description": "Creates a note",
                "method": "POST",
                "endpoint": "https://example.test/notes",
                "parameters": {
                    "body_params": {
                        "title": {
                            "type": "string",
                            "required": True,
                            "description": "Title",
                        }
                    }
                },
                "values": {meta_key: MODES_META},
            },
            title="hello",
        )

        assert meta_key not in (sent["json"] or {})
        assert meta_key not in sent["params"]
        assert sent["json"] == {"title": "hello"}

    def test_metadata_does_not_leak_into_the_tool_docstring(self, builder):
        built = builder()._create_http_tool(
            {
                "name": "advice",
                "description": "Gets an advice",
                "method": "GET",
                "endpoint": "https://api.adviceslip.com/advice",
                "parameters": {},
                "values": {"lang": "pt", "__evo_modes_meta__": MODES_META},
            }
        )

        assert "__evo_modes_meta__" not in built.func.__doc__
        assert "lang: pt" in built.func.__doc__

    def test_real_default_values_still_reach_the_request(self, builder):
        sent = self._call(
            builder,
            {
                "name": "advice",
                "description": "Gets an advice",
                "method": "GET",
                "endpoint": "https://api.adviceslip.com/advice",
                "parameters": {"query_params": {"format": "json"}},
                "values": {"lang": "pt", "__evo_modes_meta__": MODES_META},
            },
        )

        assert sent["params"] == {"format": "json", "lang": "pt"}


@pytest.mark.parametrize("builder", BUILDERS, ids=lambda b: b.__name__)
class TestLegacyStringBodyParamDoesNotCrash:
    """Old tools stored each body param as a plain string ({"queryText": "{query}"})
    instead of the {type, required, description} schema. Building the docstring
    called `.get` on that string and raised AttributeError, breaking tool creation.
    """

    def _config(self):
        return {
            "name": "search",
            "description": "Searches the KB",
            "method": "POST",
            "endpoint": "https://example.test/search",
            "parameters": {"body_params": {"queryText": "{query}"}},
            "values": {},
        }

    def test_building_the_tool_does_not_raise(self, builder):
        built = builder()._create_http_tool(self._config())
        assert built.func.__name__ == "search"

    def test_the_param_is_exposed_in_the_docstring(self, builder):
        built = builder()._create_http_tool(self._config())
        assert "queryText" in built.func.__doc__

    def test_the_llm_value_reaches_the_body(self, builder):
        built = builder()._create_http_tool(self._config())
        target = f"{builder.__module__}.requests.request"
        with patch(target) as request:
            request.return_value = MagicMock(
                status_code=200, json=lambda: {"ok": True}
            )
            built.func(queryText="hello")
        assert request.call_args.kwargs["json"] == {"queryText": "hello"}


@pytest.mark.parametrize("builder", BUILDERS, ids=lambda b: b.__name__)
class TestBodyParamsAreDeclaredToTheLLM:
    """CRM-527: the docstring is not a contract. The ADK builds the declaration
    the model sees from the signature, so `http_tool(**kwargs)` offered a tool
    with no arguments — the model called it with none and the body went out
    empty (the 400 the card reports).
    """

    def _config(self, body_params):
        return {
            "name": "search",
            "description": "Searches the KB",
            "method": "POST",
            "endpoint": "https://example.test/search",
            "parameters": {"body_params": body_params},
            "values": {},
        }

    def _declaration(self, builder, body_params):
        built = builder()._create_http_tool(self._config(body_params))
        return built._get_declaration()

    def test_a_required_param_is_declared_and_required(self, builder):
        declaration = self._declaration(
            builder,
            {"queryText": {"type": "string", "required": True, "description": "q"}},
        )

        assert declaration.parameters.properties["queryText"].type.value == "STRING"
        assert declaration.parameters.required == ["queryText"]

    def test_an_optional_param_is_declared_but_not_required(self, builder):
        declaration = self._declaration(
            builder,
            {
                "queryText": {"type": "string", "required": True, "description": "q"},
                "topK": {"type": "number", "required": False, "description": "n"},
            },
        )

        assert set(declaration.parameters.properties) == {"queryText", "topK"}
        assert declaration.parameters.properties["topK"].type.value == "NUMBER"
        assert declaration.parameters.required == ["queryText"]

    def test_every_schema_type_reaches_the_declaration(self, builder):
        declaration = self._declaration(
            builder,
            {
                name: {"type": name, "required": True, "description": ""}
                for name in ("string", "number", "integer", "boolean", "object", "array")
            },
        )

        assert {
            name: schema.type.value
            for name, schema in declaration.parameters.properties.items()
        } == {
            "string": "STRING",
            "number": "NUMBER",
            "integer": "INTEGER",
            "boolean": "BOOLEAN",
            "object": "OBJECT",
            "array": "ARRAY",
        }

    def test_a_legacy_string_param_is_declared_as_a_required_string(self, builder):
        declaration = self._declaration(builder, {"queryText": "{query}"})

        assert declaration.parameters.properties["queryText"].type.value == "STRING"
        assert declaration.parameters.required == ["queryText"]

    def test_a_name_that_is_not_an_identifier_does_not_break_the_build(self, builder):
        declaration = self._declaration(
            builder,
            {
                "query-text": {"type": "string", "required": True, "description": ""},
                "queryText": {"type": "string", "required": True, "description": ""},
            },
        )

        assert set(declaration.parameters.properties) == {"queryText"}
        assert "query-text" in declaration.description

    def test_a_tool_without_body_params_declares_nothing(self, builder):
        declaration = self._declaration(builder, {})

        assert declaration.parameters is None

    def test_the_declared_argument_reaches_the_request_body(self, builder):
        built = builder()._create_http_tool(
            self._config(
                {"queryText": {"type": "string", "required": True, "description": "q"}}
            )
        )
        target = f"{builder.__module__}.requests.request"
        with patch(target) as request:
            request.return_value = MagicMock(status_code=200, json=lambda: {"ok": True})
            declared = inspect.signature(built.func).parameters
            built.func(**{name: "hello" for name in declared})

        assert request.call_args.kwargs["json"] == {"queryText": "hello"}
