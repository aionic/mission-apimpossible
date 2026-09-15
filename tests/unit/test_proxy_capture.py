"""Tests for capture redaction and request summarisation.

Capture exists to settle open schema questions with evidence rather than
guesswork, but a capture file contains prompts - which for a coding assistant
means source code - and outlives the session on disk. So the redaction
behaviour is asserted here as carefully as the summarisation.
"""

from __future__ import annotations

import json
from pathlib import Path

from map_proxy.capture import Capture, redact_headers, summarise_request


class TestHeaderRedaction:
    def test_authorization_is_never_captured(self) -> None:
        redacted = redact_headers({"Authorization": "Bearer supersecret"})
        assert redacted["Authorization"] == "<redacted>"
        assert "supersecret" not in json.dumps(redacted)

    def test_redaction_is_case_insensitive(self) -> None:
        # Header casing is arbitrary on the wire; a case-sensitive check would
        # silently fail to redact.
        assert redact_headers({"authorization": "Bearer x"})["authorization"] == "<redacted>"
        assert redact_headers({"AUTHORIZATION": "Bearer x"})["AUTHORIZATION"] == "<redacted>"

    def test_other_credential_carrying_headers_are_redacted(self) -> None:
        headers = {
            "api-key": "k",
            "x-api-key": "k",
            "Ocp-Apim-Subscription-Key": "k",
            "Cookie": "session=1",
        }
        for value in redact_headers(headers).values():
            assert value == "<redacted>"

    def test_ordinary_headers_survive(self) -> None:
        redacted = redact_headers({"Content-Type": "application/json"})
        assert redacted["Content-Type"] == "application/json"


class TestCaptureRedaction:
    def test_prompt_text_is_not_written_by_default(self, tmp_path: Path) -> None:
        capture = Capture(tmp_path / "c.jsonl")
        capture.record_request(
            path="/v1/responses",
            headers={"Authorization": "Bearer tok"},
            body={"model": "m", "input": "SECRET_SOURCE_CODE"},
        )

        written = (tmp_path / "c.jsonl").read_text(encoding="utf-8")
        assert "SECRET_SOURCE_CODE" not in written
        assert "tok" not in written
        # The shape is still recorded, which is the point.
        assert "utf8_bytes" in written

    def test_prompt_text_is_written_when_explicitly_requested(self, tmp_path: Path) -> None:
        capture = Capture(tmp_path / "c.jsonl", include_text=True)
        capture.record_request(
            path="/v1/responses",
            headers={"Authorization": "Bearer tok"},
            body={"model": "m", "input": "VISIBLE"},
        )

        written = (tmp_path / "c.jsonl").read_text(encoding="utf-8")
        assert "VISIBLE" in written
        # The token stays redacted even in opt-in mode.
        assert "tok" not in written

    def test_records_are_valid_json_lines(self, tmp_path: Path) -> None:
        capture = Capture(tmp_path / "c.jsonl")
        capture.record_request(path="/v1/responses", headers={}, body={"model": "m"})
        capture.record_response(status=200, headers={})

        lines = (tmp_path / "c.jsonl").read_text(encoding="utf-8").strip().splitlines()
        assert len(lines) == 2
        for line in lines:
            json.loads(line)


class TestRequestSummary:
    def test_string_input_form_is_identified(self) -> None:
        summary = summarise_request({"model": "m", "input": "hello"})
        assert summary["input_form"] == "string"
        assert summary["input_bytes"] == 5

    def test_array_input_with_string_content(self) -> None:
        # One of the two shapes the open schema question is about.
        summary = summarise_request({"model": "m", "input": [{"role": "user", "content": "hi"}]})
        assert summary["input_form"] == "array"
        assert summary["content_forms"] == ["string"]
        assert summary["input_items"] == 1

    def test_array_input_with_canonical_typed_parts(self) -> None:
        # The other shape. If the IDE sends this, the gateway schema rejects
        # every request until it is widened - which is exactly what capture is
        # meant to reveal.
        summary = summarise_request(
            {
                "model": "m",
                "input": [{"role": "user", "content": [{"type": "input_text", "text": "hi"}]}],
            }
        )
        assert summary["content_forms"] == ["array"]
        assert summary["content_part_types"] == ["input_text"]

    def test_fields_outside_the_allowlist_are_reported(self) -> None:
        # The most useful line in the file: these are what would produce a 400.
        summary = summarise_request({"model": "m", "input": "x", "stream_options": {}, "seed": 1})
        assert summary["fields_outside_allowlist"] == ["seed", "stream_options"]

    def test_a_clean_request_reports_no_unknown_fields(self) -> None:
        summary = summarise_request({"model": "m", "input": "x", "stream": True, "store": False})
        assert summary["fields_outside_allowlist"] == []

    def test_instructions_size_is_measured_in_bytes(self) -> None:
        # The gateway caps instructions at 8 KiB and agent-style clients send
        # large system prompts, so this is a real rejection risk worth seeing.
        summary = summarise_request({"model": "m", "input": "x", "instructions": "é" * 10})
        assert summary["instructions_bytes"] == 20

    def test_absent_store_is_marked_rather_than_assumed(self) -> None:
        # store absent and store=false are different facts; conflating them
        # would hide whether zeroDataRetentionEnabled actually worked.
        assert summarise_request({"model": "m", "input": "x"})["store"] == "<absent>"
        assert summarise_request({"model": "m", "input": "x", "store": False})["store"] is False

    def test_tools_are_summarised_by_type(self) -> None:
        summary = summarise_request(
            {"model": "m", "input": "x", "tools": [{"type": "function", "name": "f"}]}
        )
        assert summary["tool_count"] == 1
        assert summary["tool_types"] == ["function"]

    def test_function_call_item_types_are_reported(self) -> None:
        summary = summarise_request(
            {
                "model": "m",
                "input": [
                    {"type": "function_call", "call_id": "c1", "name": "f", "arguments": "{}"}
                ],
            }
        )
        assert summary["input_item_types"] == ["function_call"]
