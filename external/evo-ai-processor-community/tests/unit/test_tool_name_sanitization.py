"""Unit tests for src.utils.tool_naming.sanitize_tool_name.

Pure function, no ADK/provider deps — runs standalone. Guards CRM-499: a custom
tool named with a space (the client's "testando ferramenta") used to reach the
LLM verbatim and get rejected with
``Invalid 'tools[0].function.name' ... pattern '^[a-zA-Z0-9_-]+$'`` (500).
"""

import re

import pytest

from src.utils.tool_naming import (
    FALLBACK_TOOL_NAME,
    MAX_TOOL_NAME_LENGTH,
    sanitize_tool_name,
    unique_tool_name,
)

OPENAI_PATTERN = re.compile(r"^[a-zA-Z0-9_-]+$")


@pytest.mark.parametrize(
    "raw, expected",
    [
        # The exact case that broke the client's agent.
        ("testando ferramenta", "testando_ferramenta"),
        # Accents / punctuation collapse to a single separator.
        ("buscar café", "buscar_caf"),
        ("preço (BRL)!", "pre_o_BRL"),
        # Runs of whitespace collapse, edges trimmed.
        ("a   b", "a_b"),
        ("  spaced  ", "spaced"),
        # Already-valid names pass through untouched.
        ("get_weather", "get_weather"),
        ("brave-search", "brave-search"),
        ("Tool123", "Tool123"),
    ],
)
def test_sanitizes_to_expected(raw, expected):
    assert sanitize_tool_name(raw) == expected


@pytest.mark.parametrize(
    "raw",
    ["testando ferramenta", "buscar café", "preço (BRL)!", "a   b", "  ", "!!!"],
)
def test_output_always_matches_provider_pattern(raw):
    # The whole point: whatever the user typed, the emitted name is valid — so
    # the provider never 400s on tools[].function.name again.
    assert OPENAI_PATTERN.match(sanitize_tool_name(raw))


def test_empty_and_all_invalid_fall_back():
    assert sanitize_tool_name("") == FALLBACK_TOOL_NAME
    assert sanitize_tool_name("   ") == FALLBACK_TOOL_NAME
    assert sanitize_tool_name("@#$%") == FALLBACK_TOOL_NAME


def test_length_is_capped():
    long_name = "a" * 200
    result = sanitize_tool_name(long_name)
    assert len(result) <= MAX_TOOL_NAME_LENGTH
    assert OPENAI_PATTERN.match(result)


@pytest.mark.parametrize(
    "name", ["get_weather", "brave-search", "Tool123", "my__tool", "_private", "___"]
)
def test_a_name_the_providers_accept_is_returned_untouched(name):
    # Squeezing underscores out of a name that already works would move the
    # function name under a working agent's feet for no gain.
    assert sanitize_tool_name(name) == name


class TestUniqueToolName:
    """Two tools answering to one name is the same 400 by another route, and the
    dispatch would land on whichever the ADK found first."""

    def test_a_free_name_is_just_the_sanitized_one(self):
        assert unique_tool_name("testando ferramenta", set()) == "testando_ferramenta"

    def test_distinct_names_that_collapse_alike_stay_distinct(self):
        assert (
            unique_tool_name("minha ferramenta", {"minha_ferramenta"})
            == "minha_ferramenta_2"
        )

    def test_it_numbers_until_it_finds_a_gap(self):
        taken = {"tool_x", "tool_x_2", "tool_x_3"}
        assert unique_tool_name("tool_x", taken) == "tool_x_4"

    def test_the_numbered_name_still_fits_the_provider_limits(self):
        base = "a" * MAX_TOOL_NAME_LENGTH
        result = unique_tool_name(base, {base})
        assert len(result) <= MAX_TOOL_NAME_LENGTH
        assert OPENAI_PATTERN.match(result)
