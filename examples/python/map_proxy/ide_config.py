"""Writing the IDE's model configuration directly.

The alternative - printing a JSON blob for the developer to paste - guarantees
a transcription error eventually, and asks them to handle a secret by hand for
no reason. The proxy already knows the endpoint, the models, and the key, so it
can just write the file.

Three details matter and are easy to get wrong:

* ``apiType: "responses"`` makes Copilot speak the API the gateway actually
  exposes, so nothing needs to translate anything.
* ``zeroDataRetentionEnabled: true`` makes VS Code send ``store: false`` and
  never chain ``previous_response_id`` - matching the gateway contract for
  free.
* the URL must carry the full ``/v1/responses`` path, because VS Code otherwise
  infers one using a naive substring check.

And one trap: the URL must never contain the substring ``openai.azure``.
VS Code switches to ``api-key`` authentication on that alone, and this proxy
expects a bearer token.
"""

from __future__ import annotations

import json
import logging
import os
from pathlib import Path
from typing import Any

from map_proxy.config import ProxyConfig
from map_proxy.tokens import write_private_file

logger = logging.getLogger("map_proxy")

PROVIDER_NAME = "Mission APIMpossible"


def vscode_config_paths() -> list[Path]:
    """Candidate ``chatLanguageModels.json`` locations, newest first.

    Stable and Insiders keep entirely separate configuration. Writing to the
    wrong one produces a provider that never appears, with no error anywhere -
    a failure mode worth eliminating by writing to whichever exists.
    """
    if os.name == "nt":
        roaming = Path(os.environ.get("APPDATA", Path.home() / "AppData" / "Roaming"))
        candidates = [
            roaming / "Code - Insiders" / "User" / "chatLanguageModels.json",
            roaming / "Code" / "User" / "chatLanguageModels.json",
        ]
    elif os.uname().sysname == "Darwin":  # type: ignore[attr-defined]
        support = Path.home() / "Library" / "Application Support"
        candidates = [
            support / "Code - Insiders" / "User" / "chatLanguageModels.json",
            support / "Code" / "User" / "chatLanguageModels.json",
        ]
    else:
        base = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
        candidates = [
            base / "Code - Insiders" / "User" / "chatLanguageModels.json",
            base / "Code" / "User" / "chatLanguageModels.json",
        ]

    return [c for c in candidates if c.parent.exists()]


def build_provider_entry(config: ProxyConfig, key: str) -> dict[str, Any]:
    """The provider block for this deployment.

    The key is embedded literally rather than referenced as ``${input:...}``.
    An input reference makes VS Code prompt, and a tool that demands a pasted
    secret is one people stop using. The key is local-only, grants nothing off
    the machine, and already sits in a user-restricted file beside this one.
    """
    return {
        "name": PROVIDER_NAME,
        "vendor": "customendpoint",
        "apiKey": key,
        "models": [
            {
                "id": m.deployment,
                "name": m.display_name,
                "url": f"http://127.0.0.1:{config.port}/v1/responses",
                "apiType": "responses",
                "zeroDataRetentionEnabled": True,
                "toolCalling": True,
                "vision": False,
                "streaming": True,
                "maxInputTokens": m.max_input_tokens,
                "maxOutputTokens": m.max_output_tokens,
                "requestHeaders": {"Authorization": f"Bearer {key}"},
            }
            for m in config.models
        ],
    }


def _is_usable(model: Any) -> bool:
    """Whether a model entry can actually serve a request.

    VS Code's "Add Models" UI appends a blank template when a provider already
    exists::

        {"id": "", "name": "", "url": "", "toolCalling": true, "vision": true}

    It shows as an unnamed row in the model picker, and selecting it fails with
    ``Failed to parse URL from /v1/chat/completions: Invalid URL`` - with no
    URL, VS Code falls back to a bare default path and has no origin to resolve
    it against. The error names neither the provider nor the empty field, so it
    reads like a proxy fault rather than a stray config stub.
    """
    return bool(
        isinstance(model, dict)
        and str(model.get("id", "")).strip()
        and str(model.get("url", "")).strip()
    )


def write_vscode_config(config: ProxyConfig, key: str, path: Path | None = None) -> Path | None:
    """Merges this provider into the IDE configuration.

    Existing providers are preserved - clobbering somebody's Copilot settings
    to install a demo would be inexcusable - and the previous file is backed up
    before the first change.

    Returns the path written, or None when no IDE configuration was found.
    """
    targets = [path] if path else vscode_config_paths()
    if not targets:
        return None

    target = targets[0]
    existing: list[Any] = []

    if target.exists():
        try:
            loaded = json.loads(target.read_text(encoding="utf-8"))
            if isinstance(loaded, list):
                existing = loaded
        except (ValueError, OSError):
            # A hand-edited file with a trailing comma should not cost somebody
            # their configuration.
            logger.warning("Could not parse %s; leaving it untouched.", target)
            return None

        backup = target.with_suffix(target.suffix + ".map-backup")
        if not backup.exists():
            # The backup inherits this file's contents, which after the first
            # write include the session key - so it gets the same restrictive
            # permissions rather than whatever copy2 would propagate.
            write_private_file(backup, target.read_text(encoding="utf-8"))

    # Idempotent: replace our own entry rather than accumulating duplicates.
    merged = [
        entry
        for entry in existing
        if not (isinstance(entry, dict) and entry.get("name") == PROVIDER_NAME)
    ]
    merged.append(build_provider_entry(config, key))

    # Other providers keep their settings untouched - except for blank stubs,
    # which are broken for them too and which the UI creates without asking.
    for entry in merged:
        if not isinstance(entry, dict) or entry.get("name") == PROVIDER_NAME:
            continue
        models = entry.get("models")
        if isinstance(models, list):
            usable = [m for m in models if _is_usable(m)]
            if len(usable) != len(models):
                logger.info(
                    "Removed %d unusable model stub(s) from provider %r.",
                    len(models) - len(usable),
                    entry.get("name"),
                )
                entry["models"] = usable

    # This file contains the session key verbatim, in apiKey and in
    # requestHeaders.Authorization. A plain write_text would create it under
    # the process umask - 0644 on most POSIX systems - leaving it readable by
    # every local account, which is precisely the attacker the key exists to
    # stop. Same protection as the key file itself.
    write_private_file(target, json.dumps(merged, indent=2) + "\n")
    return target
