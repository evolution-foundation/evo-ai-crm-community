"""The agent's pipeline rules must reach the model with their STAGES.

The prompt builder used to read ``stageName``/``instructions`` off the RULE,
where the frontend never writes them (they live in ``rule["stages"]``), so a
configured funnel rendered as a single line with the funnel name and the model
had no stage to move to. These tests pin the shape the UI actually writes.
"""

from src.services.adk.agents.llm_agent_builder import _format_pipeline_rules_for_prompt


def _real_ui_rules():
    """Exactly what PipelineRulesModal persists for a two-stage funnel."""
    return [
        {
            "id": "rule-1",
            "pipelineId": "pipe-1",
            "pipelineName": "Vendas",
            "allowTasks": True,
            "allowServices": False,
            "generalInstructions": "Funil principal de vendas",
            "stages": [
                {
                    "id": "s1",
                    "stageId": "stg-qualificado",
                    "stageName": "Qualificado",
                    "instructions": "quando o lead confirma interesse no produto",
                },
                {
                    "id": "s2",
                    "stageId": "stg-fechado",
                    "stageName": "Fechado",
                    "instructions": "quando o lead confirma a compra",
                },
            ],
        }
    ]


class TestPipelineRulesReachTheModel:
    def test_every_configured_stage_appears(self):
        text = "\n".join(_format_pipeline_rules_for_prompt(_real_ui_rules()))

        assert "Qualificado" in text
        assert "Fechado" in text

    def test_stage_ids_are_exposed_so_the_tool_can_be_called(self):
        # Without the id the model can only guess a name, and
        # pipeline_manipulation answers "stage_id or stage_name is required".
        text = "\n".join(_format_pipeline_rules_for_prompt(_real_ui_rules()))

        assert "stg-qualificado" in text
        assert "stg-fechado" in text
        assert "pipe-1" in text

    def test_per_stage_instructions_are_the_when_to_move(self):
        text = "\n".join(_format_pipeline_rules_for_prompt(_real_ui_rules()))

        assert "quando o lead confirma interesse no produto" in text
        assert "quando o lead confirma a compra" in text

    def test_general_instructions_are_kept(self):
        text = "\n".join(_format_pipeline_rules_for_prompt(_real_ui_rules()))

        assert "Funil principal de vendas" in text

    def test_a_configured_funnel_never_renders_as_a_bare_name(self):
        """The regression itself: one line, funnel name only."""
        lines = _format_pipeline_rules_for_prompt(_real_ui_rules())

        assert len(lines) > 1, f"stages were dropped from the prompt: {lines!r}"


class TestEdgeShapes:
    def test_legacy_flat_rule_still_renders_with_its_id(self):
        # A config written by an older UI kept the stage on the rule itself.
        legacy = [
            {
                "pipelineId": "pipe-9",
                "pipelineName": "Antigo",
                "stageId": "stg-ganho",
                "stageName": "Ganho",
                "instructions": "quando fechar",
            }
        ]

        text = "\n".join(_format_pipeline_rules_for_prompt(legacy))

        assert "Ganho" in text
        assert "stg-ganho" in text
        assert "quando fechar" in text

    def test_stage_without_an_id_is_dropped(self):
        # The operator wrote the criteria but never picked the stage, so the UI
        # saved stageId="". Listing it makes the model invent a stage name --
        # the very failure this module guards against.
        half_configured = [
            {
                "pipelineId": "pipe-1",
                "pipelineName": "Vendas",
                "stages": [
                    {"stageId": "", "stageName": "", "instructions": "quando fechar"},
                    {"stageId": "stg-ok", "stageName": "Ok", "instructions": "quando abrir"},
                ],
            }
        ]

        lines = _format_pipeline_rules_for_prompt(half_configured)

        assert not any("quando fechar" in line for line in lines)
        assert any("stg-ok" in line for line in lines)

    def test_legacy_rule_without_an_id_is_dropped(self):
        # Same reasoning, flat shape: the tool resolves a stage name through
        # rule["stages"], which a flat rule does not have.
        lines = _format_pipeline_rules_for_prompt(
            [{"pipelineId": "p", "pipelineName": "Antigo", "stageName": "Ganho"}]
        )

        assert not any("Ganho" in line for line in lines)

    def test_rule_without_stages_still_names_the_pipeline(self):
        text = "\n".join(_format_pipeline_rules_for_prompt([{"pipelineId": "p", "pipelineName": "Só o funil"}]))

        assert "Só o funil" in text

    def test_garbage_entries_do_not_raise(self):
        assert _format_pipeline_rules_for_prompt([]) == []
        assert _format_pipeline_rules_for_prompt(None) == []
        assert _format_pipeline_rules_for_prompt(["not a dict", 42]) == []

        out = _format_pipeline_rules_for_prompt([{"pipelineName": "X", "stages": ["bad", None]}])
        assert any("X" in line for line in out)
