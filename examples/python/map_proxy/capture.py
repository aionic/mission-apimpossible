"""Redacted capture of what the IDE actually sends.

This exists because guessing at wire formats already cost this project one
unnecessary design. The first plan assumed Copilot spoke only Chat Completions
and specified a translation layer; reading the source showed it speaks the
Responses API natively, and the translation layer evaporated.

Three questions remain open about the request shape, and all of them change the
gateway schema:

* is ``input[].content`` a plain string, or the canonical
  ``[{"type": "input_text", "text": ...}]`` array?
* does the system prompt exceed the gateway's 8 KiB ``instructions`` cap?
* does a realistic session exceed the 48 KiB aggregate input bound?

Rather than guess again, capture the traffic and read it.

Redaction is not optional here. A capture file contains prompts - which for a
coding assistant means source code - and sits on disk long after the session.
So: the ``Authorization`` header never appears, and message text is recorded by
SHAPE and SIZE rather than content unless the developer explicitly opts in.
"""

from __future__ import annotations

import json
import logging
import threading
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

logger = logging.getLogger("map_proxy")

# Never written to a capture under any setting.
_NEVER_CAPTURE = {"authorization", "api-key", "x-api-key", "ocp-apim-subscription-key", "cookie"}


def _describe(value: Any, *, include_text: bool) -> Any:
    """Describes a value by shape, or verbatim when explicitly requested."""
    if isinstance(value, str):
        if include_text:
            return value
        return {"__str__": {"len": len(value), "utf8_bytes": len(value.encode("utf-8"))}}
    if isinstance(value, list):
        return [_describe(v, include_text=include_text) for v in value]
    if isinstance(value, dict):
        return {k: _describe(v, include_text=include_text) for k, v in value.items()}
    return value


def redact_headers(headers: dict[str, str]) -> dict[str, str]:
    """Strips anything that could carry a credential."""
    return {k: ("<redacted>" if k.lower() in _NEVER_CAPTURE else v) for k, v in headers.items()}


class Capture:
    """Appends redacted request/response records as JSON Lines.

    Thread-safe: requests are handled concurrently and a torn line would make
    the file unparseable exactly when it is needed.
    """

    def __init__(self, path: str | Path, *, include_text: bool = False) -> None:
        self._path = Path(path)
        self._include_text = include_text
        self._lock = threading.Lock()
        self._path.parent.mkdir(parents=True, exist_ok=True)

        if include_text:
            logger.warning(
                "Capture includes PROMPT TEXT. The file at %s will contain whatever "
                "source code you send. Treat it as sensitive and delete it afterwards.",
                self._path,
            )
        else:
            logger.info(
                "Capturing request SHAPES (no prompt text) to %s. "
                "Pass --capture-text to include content.",
                self._path,
            )

    @property
    def path(self) -> Path:
        return self._path

    def record(self, kind: str, **fields: Any) -> None:
        """Writes one record."""
        record = {
            "at": datetime.now(UTC).isoformat(),
            "kind": kind,
            **fields,
        }
        line = json.dumps(record, separators=(",", ":"), default=str)
        with self._lock, self._path.open("a", encoding="utf-8") as handle:
            handle.write(line + "\n")

    def record_request(self, *, path: str, headers: dict[str, str], body: dict[str, Any]) -> None:
        """Records an inbound request, answering the open schema questions."""
        self.record(
            "request",
            path=path,
            headers=redact_headers(headers),
            body=_describe(body, include_text=self._include_text),
            shape=summarise_request(body),
        )

    def record_response(
        self, *, status: int, headers: dict[str, str], note: str | None = None
    ) -> None:
        self.record(
            "response",
            status=status,
            headers=redact_headers(headers),
            note=note,
        )


def summarise_request(body: dict[str, Any]) -> dict[str, Any]:
    """Extracts exactly the facts that decide the schema changes.

    Readable at a glance without trawling the raw capture, and safe to paste
    into an issue: it contains sizes and type names, never content.
    """
    summary: dict[str, Any] = {
        "top_level_keys": sorted(body.keys()),
        "has_stream": bool(body.get("stream")),
        "store": body.get("store", "<absent>"),
        "model": body.get("model", "<absent>"),
    }

    instructions = body.get("instructions")
    if isinstance(instructions, str):
        summary["instructions_bytes"] = len(instructions.encode("utf-8"))

    payload = body.get("input")
    if isinstance(payload, str):
        summary["input_form"] = "string"
        summary["input_bytes"] = len(payload.encode("utf-8"))
    elif isinstance(payload, list):
        summary["input_form"] = "array"
        summary["input_items"] = len(payload)
        summary["input_bytes"] = len(json.dumps(payload, separators=(",", ":")).encode("utf-8"))

        # THE open question: string content, or canonical typed parts?
        content_forms: set[str] = set()
        part_types: set[str] = set()
        item_types: set[str] = set()
        for item in payload:
            if not isinstance(item, dict):
                content_forms.add(type(item).__name__)
                continue
            if "type" in item:
                item_types.add(str(item["type"]))
            content = item.get("content")
            if isinstance(content, str):
                content_forms.add("string")
            elif isinstance(content, list):
                content_forms.add("array")
                for part in content:
                    if isinstance(part, dict) and "type" in part:
                        part_types.add(str(part["type"]))
            elif content is not None:
                content_forms.add(type(content).__name__)

        summary["content_forms"] = sorted(content_forms)
        summary["content_part_types"] = sorted(part_types)
        summary["input_item_types"] = sorted(item_types)

    tools = body.get("tools")
    if isinstance(tools, list):
        summary["tool_count"] = len(tools)
        summary["tool_types"] = sorted({str(t.get("type")) for t in tools if isinstance(t, dict)})

    # Anything the gateway's allowlist does not know about. These are what
    # would produce a 400, so they are the most useful line in the file.
    known = {
        "model",
        "input",
        "instructions",
        "stream",
        "store",
        "max_output_tokens",
        "temperature",
        "top_p",
        "reasoning",
        "metadata",
    }
    summary["fields_outside_allowlist"] = sorted(set(body.keys()) - known)

    return summary
