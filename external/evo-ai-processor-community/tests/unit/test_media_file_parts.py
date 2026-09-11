"""EVO-2181: every incoming file the model can read must reach the model.

process_files used to append the file part to `file_parts` only `if is_audio`, so
images were blobbed + saved to artifacts but never sent to the LLM, and
create_content("", file_parts) returned None -> "No content to process".

The other half of the contract: what the model layer *cannot* carry must stay out
of the content parts. google-adk's LiteLlm raises ValueError on a mime type it
does not know, the runner turns that into a 500, and the user loses the whole
turn -- their text included. A plain WhatsApp document (docx/zip) takes exactly
that path, and a caller that omits `mimeType` gets application/octet-stream from
a2a_routes.extract_files_from_message.
"""

from __future__ import annotations

import asyncio
import base64
from unittest.mock import AsyncMock, MagicMock

import pytest
from google.adk.models.lite_llm import _get_content
from google.genai.types import Blob, Part

from src.schemas.chat import FileData
from src.services.adk.runners.runner_utils import RunnerUtils

DOCX = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"


def _utils():
    # Bypass __init__ (which builds AgentBuilder(db)); the methods under test use
    # neither self.db nor self.agent_builder.
    return RunnerUtils.__new__(RunnerUtils)


def _artifacts():
    a = MagicMock()
    a.save_artifact = AsyncMock()
    return a


def _file(name, ctype):
    return FileData(
        filename=name, content_type=ctype, data=base64.b64encode(b"bytes-" + name.encode()).decode()
    )


def _run(coro):
    return asyncio.run(coro)


def test_image_is_appended_to_file_parts():
    parts, transcribed = _run(
        _utils().process_files([_file("photo.png", "image/png")], _artifacts(), "agent", "ext", "sess")
    )
    assert len(parts) == 1
    assert parts[0].inline_data.mime_type == "image/png"
    assert transcribed == []


def test_audio_still_appended():
    parts, _ = _run(
        _utils().process_files([_file("voice.ogg", "audio/ogg")], _artifacts(), "a", "e", "s")
    )
    assert len(parts) == 1
    assert parts[0].inline_data.mime_type == "audio/ogg"


def test_image_and_audio_both_appended():
    parts, _ = _run(
        _utils().process_files(
            [_file("p.png", "image/png"), _file("v.ogg", "audio/ogg")], _artifacts(), "a", "e", "s"
        )
    )
    assert len(parts) == 2


def test_create_content_with_image_only_is_not_none():
    utils = _utils()
    parts, _ = _run(utils.process_files([_file("photo.png", "image/png")], _artifacts(), "a", "e", "s"))
    content = utils.create_content("", parts)
    assert content is not None  # regression guard for "No content to process"
    assert content.role == "user"
    assert len(content.parts) == 2  # empty text part + the image file part


def test_create_content_empty_is_none():
    assert _utils().create_content("", []) is None


@pytest.mark.parametrize("content_type", [DOCX, "application/zip", "application/octet-stream", ""])
def test_unreadable_file_stays_out_of_the_content_parts(content_type):
    artifacts = _artifacts()
    parts, _ = _run(
        _utils().process_files([_file("file.bin", content_type)], artifacts, "a", "e", "s")
    )
    assert parts == []
    artifacts.save_artifact.assert_awaited_once()  # still kept for reference


def test_unreadable_file_never_costs_the_text_reply():
    # The regression this guards: forwarding the docx raises ValueError inside
    # LiteLlm, the runner answers 500 and the caption goes unanswered.
    utils = _utils()
    parts, _ = _run(utils.process_files([_file("planilha.docx", DOCX)], _artifacts(), "a", "e", "s"))
    content = utils.create_content("segue o documento", parts)
    assert content is not None
    assert content.parts[0].text == "segue o documento"
    assert all(p.inline_data is None for p in content.parts)


def test_unreadable_file_does_not_drop_the_image_next_to_it():
    parts, _ = _run(
        _utils().process_files(
            [_file("a.zip", "application/zip"), _file("p.png", "image/png")], _artifacts(), "a", "e", "s"
        )
    )
    assert [p.inline_data.mime_type for p in parts] == ["image/png"]


def test_pdf_and_text_still_reach_the_model():
    parts, _ = _run(
        _utils().process_files(
            [_file("r.pdf", "application/pdf"), _file("n.txt", "text/plain")], _artifacts(), "a", "e", "s"
        )
    )
    assert [p.inline_data.mime_type for p in parts] == ["application/pdf", "text/plain"]


def test_mime_parameters_do_not_break_the_check():
    parts, _ = _run(
        _utils().process_files([_file("v.webm", "audio/webm;codecs=opus")], _artifacts(), "a", "e", "s")
    )
    # The prefix still matches with the parameter attached, and ADK reads the
    # verbatim value off the Blob, so the two agree.
    assert [p.inline_data.mime_type for p in parts] == ["audio/webm;codecs=opus"]


# The guard must judge the mime exactly as ADK will, because ADK is what raises.
# A check that normalized first would pass these through and turn them into a 500
# in _get_content -- losing the caption along with the file.
@pytest.mark.parametrize(
    "content_type",
    [
        "IMAGE/PNG",  # case-sensitive startswith in _get_content
        "Image/png",
        "application/pdf; charset=binary",  # exact-match set in _get_content
        "application/json;charset=utf-8",
    ],
)
def test_mime_adk_would_reject_is_skipped_not_forwarded(content_type):
    artifacts = _artifacts()
    parts, _ = _run(_utils().process_files([_file("f.bin", content_type)], artifacts, "a", "e", "s"))
    assert parts == []
    artifacts.save_artifact.assert_awaited_once()  # still kept for reference


def test_every_skipped_mime_would_really_have_broken_adk():
    """The mirror is only worth having if it matches ADK's real behaviour.

    Feeds ADK exactly what the guard rejects and asserts it raises, so a future
    ADK bump that starts accepting these shows up as a failure here instead of as
    a guard that silently drops media the model could have read.
    """
    utils = _utils()
    for content_type in ["IMAGE/PNG", "application/pdf; charset=binary", DOCX]:
        part = Part(inline_data=Blob(mime_type=content_type, data=b"bytes"))
        with pytest.raises(ValueError):
            _get_content([part])


def test_image_survives_an_artifact_store_failure():
    artifacts = MagicMock()
    artifacts.save_artifact = AsyncMock(side_effect=RuntimeError("artifact store down"))
    parts, _ = _run(_utils().process_files([_file("p.png", "image/png")], artifacts, "a", "e", "s"))
    assert [p.inline_data.mime_type for p in parts] == ["image/png"]


def test_oversized_file_is_not_inlined(monkeypatch):
    monkeypatch.setattr(RunnerUtils, "MAX_INLINE_FILE_BYTES", 4)
    artifacts = _artifacts()
    parts, _ = _run(_utils().process_files([_file("big.png", "image/png")], artifacts, "a", "e", "s"))
    assert parts == []
    artifacts.save_artifact.assert_awaited_once()


def test_inline_budget_is_per_request(monkeypatch):
    # first.png decodes to 15 bytes, second.png to 16 -> only the first fits.
    monkeypatch.setattr(RunnerUtils, "MAX_INLINE_REQUEST_BYTES", 20)
    parts, _ = _run(
        _utils().process_files(
            [_file("first.png", "image/png"), _file("second.png", "image/png")], _artifacts(), "a", "e", "s"
        )
    )
    assert len(parts) == 1


def test_every_forwarded_part_is_accepted_by_the_installed_adk():
    """Pins the allowlist to what google-adk actually converts.

    `_get_content` is what raises the ValueError the runner turns into a 500. If
    an ADK bump narrows the accepted set, this fails here instead of in front of
    a customer.
    """
    utils = _utils()
    samples = [
        "image/png",
        "image/jpeg",
        "image/webp",
        "audio/ogg",
        "audio/mpeg",
        "video/mp4",
        "text/plain",
        "application/pdf",
        "application/json",
    ]
    parts, _ = _run(
        utils.process_files(
            [_file(f"f{i}.bin", ctype) for i, ctype in enumerate(samples)], _artifacts(), "a", "e", "s"
        )
    )
    assert len(parts) == len(samples)
    _get_content(utils.create_content("", parts).parts)  # must not raise
