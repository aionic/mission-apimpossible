"""Command-line entry point.

    uv run python -m map_proxy

Writes the IDE configuration, then serves until interrupted. There is nothing
to copy, nothing to paste, and no prompt: the goal is that Foundry behaves like
any other provider, and a provider that demands a hand-pasted secret every
morning is not that.
"""

from __future__ import annotations

import argparse
import contextlib
import json
import logging
import sys
from pathlib import Path

from map_proxy.capture import Capture
from map_proxy.config import ModelEntry, ProxyConfig, ProxyConfigError
from map_proxy.ide_config import build_provider_entry, write_vscode_config
from map_proxy.tokens import (
    TokenProvider,
    build_credential,
    default_key_path,
    load_or_create_key,
)


def _parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="map_proxy",
        description=(
            "Presents the Mission APIMpossible gateway as a key-authenticated "
            "provider on loopback, while forwarding your real Entra identity."
        ),
    )
    parser.add_argument("--endpoint", help="Gateway Responses endpoint. Defaults to MAP_ENDPOINT.")
    parser.add_argument("--tenant", help="Tenant GUID. Defaults to MAP_TENANT_ID.")
    parser.add_argument("--scope", help="OAuth scope. Defaults to MAP_SCOPE.")
    parser.add_argument(
        "--model",
        action="append",
        dest="models",
        metavar="DEPLOYMENT",
        help="Deployment to advertise. Repeat for several. Defaults to MAP_MODEL(S).",
    )
    parser.add_argument("--port", type=int, help="Loopback port. Defaults to 8787.")
    parser.add_argument(
        "--capture",
        metavar="PATH",
        help="Record redacted request shapes to PATH, to settle schema questions with evidence.",
    )
    parser.add_argument(
        "--capture-text",
        action="store_true",
        help="Include PROMPT TEXT in the capture. The file will contain your source code.",
    )
    parser.add_argument(
        "--rotate-key",
        action="store_true",
        help="Generate a new local key and rewrite the IDE configuration.",
    )
    parser.add_argument(
        "--no-ide-config",
        action="store_true",
        help="Do not touch the IDE configuration; print it instead.",
    )
    parser.add_argument("--verbose", action="store_true", help="Debug logging.")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv)

    # Python block-buffers stdout when it is not a terminal, so under any
    # wrapper that pipes output this banner would not appear until the process
    # exited.
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(line_buffering=True)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s  %(levelname)-7s %(message)s",
        datefmt="%H:%M:%S",
    )

    try:
        config = ProxyConfig.from_env(
            gateway_endpoint=args.endpoint,
            tenant_id=args.tenant,
            scope=args.scope,
            models=(
                tuple(ModelEntry(deployment=n, display_name=n) for n in args.models)
                if args.models
                else None
            ),
            port=args.port,
            capture_path=args.capture,
        )
    except ProxyConfigError as exc:
        print(f"Configuration error: {exc}", file=sys.stderr)
        return 2

    key = load_or_create_key(rotate=args.rotate_key)

    capture = (
        Capture(config.capture_path, include_text=args.capture_text)
        if config.capture_path
        else None
    )

    tokens = TokenProvider(build_credential(config.tenant_id), config.scope)

    written: Path | None = None
    if not args.no_ide_config:
        written = write_vscode_config(config, key)

    from map_proxy.server import build_app, run

    print()
    print("  Mission APIMpossible - local Entra proxy")
    print("  " + "=" * 62)
    print(f"  Gateway    {config.gateway_endpoint}")
    print(f"  Tenant     {config.tenant_id}")
    print(f"  Models     {', '.join(m.deployment for m in config.models)}")
    print(f"  Listening  http://127.0.0.1:{config.port}/v1  (loopback only)")
    if capture is not None:
        print(f"  Capturing  {capture.path}")
    print()

    if written is not None:
        print(f"  VS Code configured: {written}")
        print("  Reload the window, then pick the model in Chat. Nothing to paste.")
    elif args.no_ide_config:
        print("  Add this to your IDE's chatLanguageModels.json:")
        print()
        for line in json.dumps([build_provider_entry(config, key)], indent=2).splitlines():
            print(f"    {line}")
    else:
        print("  No VS Code installation found; skipped IDE configuration.")
        print("  Re-run with --no-ide-config to print the block instead.")

    print()
    print(f"  Local key  {default_key_path()}")
    print("  It is not an Azure credential and grants nothing off this machine.")
    print("  It exists because loopback is not private: on Windows any local")
    print("  user account can reach 127.0.0.1. Rotate it with --rotate-key.")
    print()
    print("  Your Entra sign-in is what actually reaches the model.")
    print()
    print("  Ctrl+C to stop.")
    print()

    with contextlib.suppress(KeyboardInterrupt):
        run(build_app(config, tokens, key, capture), config.port)

    print("\n  Stopped.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
