"""Tests for the persistent local key and IDE configuration writing.

The configuration writer edits a file the developer owns and may have spent
time on. "Preserves what was already there" is therefore a correctness
requirement, not a nicety, and is asserted here rather than assumed.
"""

from __future__ import annotations

import json
from pathlib import Path

from map_proxy.config import ModelEntry, ProxyConfig
from map_proxy.ide_config import PROVIDER_NAME, build_provider_entry, write_vscode_config
from map_proxy.tokens import load_or_create_key


def _config(port: int = 8787) -> ProxyConfig:
    return ProxyConfig(
        gateway_endpoint="https://example.azure-api.net/openai/v1/responses",
        tenant_id="11111111-1111-1111-1111-111111111111",
        scope="https://ai.azure.com/.default",
        models=(
            ModelEntry(deployment="coding-model", display_name="Coding model"),
            ModelEntry(deployment="second-model", display_name="Second model"),
        ),
        port=port,
    )


class TestPersistentKey:
    def test_key_is_created_on_first_use(self, tmp_path: Path) -> None:
        key_file = tmp_path / "proxy.key"
        key = load_or_create_key(key_file)
        assert key
        assert key_file.exists()

    def test_key_is_stable_across_calls(self, tmp_path: Path) -> None:
        # The whole point. A key that changed every start would have to be
        # re-pasted every start, which is the friction this replaces.
        key_file = tmp_path / "proxy.key"
        assert load_or_create_key(key_file) == load_or_create_key(key_file)

    def test_rotation_replaces_the_key(self, tmp_path: Path) -> None:
        key_file = tmp_path / "proxy.key"
        first = load_or_create_key(key_file)
        second = load_or_create_key(key_file, rotate=True)
        assert first != second
        assert key_file.read_text(encoding="utf-8").strip() == second

    def test_an_empty_key_file_is_regenerated(self, tmp_path: Path) -> None:
        # A truncated file should self-heal rather than authenticate everyone
        # with the empty string.
        key_file = tmp_path / "proxy.key"
        key_file.write_text("", encoding="utf-8")
        assert load_or_create_key(key_file)

    def test_parent_directory_is_created(self, tmp_path: Path) -> None:
        key_file = tmp_path / "nested" / "dir" / "proxy.key"
        assert load_or_create_key(key_file)
        assert key_file.exists()


class TestProviderEntry:
    def test_uses_the_responses_api_type(self) -> None:
        # Without this Copilot speaks Chat Completions, which the gateway does
        # not expose - and a translation layer would have to exist somewhere.
        entry = build_provider_entry(_config(), "k")
        assert all(m["apiType"] == "responses" for m in entry["models"])

    def test_requests_zero_data_retention(self) -> None:
        # Makes VS Code send store:false and never chain previous_response_id,
        # matching the gateway contract without the proxy rewriting anything.
        entry = build_provider_entry(_config(), "k")
        assert all(m["zeroDataRetentionEnabled"] is True for m in entry["models"])

    def test_url_carries_the_full_api_path(self) -> None:
        # VS Code otherwise infers a path using a naive substring check.
        entry = build_provider_entry(_config(), "k")
        assert all(m["url"].endswith("/v1/responses") for m in entry["models"])

    def test_url_avoids_the_azure_openai_substring_trap(self) -> None:
        # VS Code switches to api-key authentication on 'openai.azure' alone,
        # and this proxy expects a bearer token.
        entry = build_provider_entry(_config(), "k")
        assert all("openai.azure" not in m["url"] for m in entry["models"])

    def test_key_is_embedded_rather_than_prompted(self) -> None:
        # ${input:...} makes VS Code prompt. A provider that demands a pasted
        # secret every session is one people stop using.
        entry = build_provider_entry(_config(), "local-key")
        assert entry["apiKey"] == "local-key"
        assert "${input:" not in json.dumps(entry)

    def test_every_configured_model_is_advertised(self) -> None:
        entry = build_provider_entry(_config(), "k")
        assert [m["id"] for m in entry["models"]] == ["coding-model", "second-model"]

    def test_tool_calling_is_declared(self) -> None:
        # Copilot HIDES models without toolCalling from agent mode, which is
        # the default mode - so declaring false made the model invisible in
        # normal use. The gateway now accepts client-side function tools, so
        # this is an honest claim rather than a convenient one.
        entry = build_provider_entry(_config(), "k")
        assert all(m["toolCalling"] is True for m in entry["models"])

    def test_port_is_reflected_in_the_url(self) -> None:
        entry = build_provider_entry(_config(port=9999), "k")
        assert all(":9999/" in m["url"] for m in entry["models"])


class TestConfigMerging:
    def test_creates_the_file_when_absent(self, tmp_path: Path) -> None:
        target = tmp_path / "chatLanguageModels.json"
        assert write_vscode_config(_config(), "k", target) == target
        assert json.loads(target.read_text(encoding="utf-8"))[0]["name"] == PROVIDER_NAME

    def test_preserves_existing_providers(self, tmp_path: Path) -> None:
        # Clobbering somebody's Copilot configuration to install a demo would
        # be inexcusable.
        target = tmp_path / "chatLanguageModels.json"
        target.write_text(
            json.dumps([{"name": "Copilot", "vendor": "copilot", "settings": {"a": 1}}]),
            encoding="utf-8",
        )

        write_vscode_config(_config(), "k", target)

        names = [e["name"] for e in json.loads(target.read_text(encoding="utf-8"))]
        assert "Copilot" in names
        assert PROVIDER_NAME in names

    def test_is_idempotent(self, tmp_path: Path) -> None:
        target = tmp_path / "chatLanguageModels.json"
        write_vscode_config(_config(), "k", target)
        write_vscode_config(_config(), "k", target)

        entries = json.loads(target.read_text(encoding="utf-8"))
        assert sum(1 for e in entries if e["name"] == PROVIDER_NAME) == 1

    def test_updates_rather_than_duplicates_on_key_rotation(self, tmp_path: Path) -> None:
        target = tmp_path / "chatLanguageModels.json"
        write_vscode_config(_config(), "old-key", target)
        write_vscode_config(_config(), "new-key", target)

        entries = json.loads(target.read_text(encoding="utf-8"))
        ours = [e for e in entries if e["name"] == PROVIDER_NAME]
        assert len(ours) == 1
        assert ours[0]["apiKey"] == "new-key"

    def test_backs_up_before_the_first_change(self, tmp_path: Path) -> None:
        target = tmp_path / "chatLanguageModels.json"
        target.write_text(json.dumps([{"name": "Copilot", "vendor": "copilot"}]), encoding="utf-8")

        write_vscode_config(_config(), "k", target)

        backup = target.with_suffix(target.suffix + ".map-backup")
        assert backup.exists()
        assert json.loads(backup.read_text(encoding="utf-8"))[0]["name"] == "Copilot"

    def test_backup_is_not_overwritten_by_later_runs(self, tmp_path: Path) -> None:
        # The backup must keep the ORIGINAL, not the state before the most
        # recent run - otherwise it stops being a way back.
        target = tmp_path / "chatLanguageModels.json"
        target.write_text(json.dumps([{"name": "Original", "vendor": "copilot"}]), encoding="utf-8")

        write_vscode_config(_config(), "k", target)
        write_vscode_config(_config(), "k2", target)

        backup = target.with_suffix(target.suffix + ".map-backup")
        assert json.loads(backup.read_text(encoding="utf-8"))[0]["name"] == "Original"

    def test_unparseable_file_is_left_untouched(self, tmp_path: Path) -> None:
        # A hand-edited file with a trailing comma should not cost somebody
        # their configuration.
        target = tmp_path / "chatLanguageModels.json"
        target.write_text("{ not json", encoding="utf-8")

        assert write_vscode_config(_config(), "k", target) is None
        assert target.read_text(encoding="utf-8") == "{ not json"

    def test_output_is_valid_json(self, tmp_path: Path) -> None:
        target = tmp_path / "chatLanguageModels.json"
        write_vscode_config(_config(), "k", target)
        assert isinstance(json.loads(target.read_text(encoding="utf-8")), list)
