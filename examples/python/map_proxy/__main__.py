"""Command-line entry point.

    uv run python -m map_proxy

Prints the loopback URL, the session key, and a ready-to-paste
``chatLanguageModels.json`` block, then serves until interrupted.
"""

from __future__ import annotations

import argparse
import contextlib
import json
import logging
import sys

from map_proxy.capture import Capture
from map_proxy.config import ModelEntry, ProxyConfig, ProxyConfigError
from map_proxy.tokens import TokenProvider, build_credential, generate_session_secret


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
    parser.add_argument("--verbose", action="store_true", help="Debug logging.")
    return parser.parse_args(argv)


def _config_snippet(config: ProxyConfig) -> str:
    """The VS Code Custom Endpoint block, ready to paste.

    Three details matter and are easy to get wrong:

    * ``apiType: "responses"`` - so Copilot speaks the API the gateway exposes
      and no translation is needed anywhere.
    * ``zeroDataRetentionEnabled: true`` - makes VS Code send ``store: false``
      and never chain ``previous_response_id``, matching the gateway contract.
    * the full URL including ``/v1/responses`` - VS Code otherwise infers a
      path, and the inference is a naive substring check.

    The URL must also never contain ``openai.azure``: VS Code switches to
    ``api-key`` authentication on that substring alone, and the proxy expects a
    bearer token.
    """
    models = [
        {
            "id": m.deployment,
            "name": m.display_name,
            "url": f"http://127.0.0.1:{config.port}/v1/responses",
            "apiType": "responses",
            "zeroDataRetentionEnabled": True,
            "toolCalling": False,
            "vision": False,
            "streaming": True,
            "maxInputTokens": m.max_input_tokens,
            "maxOutputTokens": m.max_output_tokens,
            "requestHeaders": {"Authorization": "Bearer ${apiKey}"},
        }
        for m in config.models
    ]

    return json.dumps(
        [
            {
                "name": "Mission APIMpossible",
                "vendor": "customendpoint",
                "apiKey": "${input:missionApimpossibleKey}",
                "models": models,
            }
        ],
        indent=2,
    )


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv)

    # Python block-buffers stdout when it is not a terminal. The session key is
    # printed to stdout, so under any wrapper that pipes output - a task
    # runner, a terminal multiplexer, CI - the banner would not appear until
    # the process exited, and the key it contains is needed while it runs.
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

    secret = generate_session_secret()
    capture = (
        Capture(config.capture_path, include_text=args.capture_text)
        if config.capture_path
        else None
    )

    tokens = TokenProvider(build_credential(config.tenant_id), config.scope)

    # Deferred so the banner is not printed before a configuration error.
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
    print("  Session key - paste this when the IDE asks for an API key:")
    print()
    print(f"      {secret}")
    print()
    print("  It is not an Azure credential. It authorises this local listener")
    print("  and nothing else, it never leaves this machine, and it dies when")
    print("  this process does.")
    print()
    print("  VS Code: run 'Chat: Manage Language Models' and paste:")
    print()
    for line in _config_snippet(config).splitlines():
        print(f"    {line}")
    print()
    print("  Ctrl+C to stop.")
    print()

    with contextlib.suppress(KeyboardInterrupt):
        run(build_app(config, tokens, secret, capture), config.port)

    print("\n  Stopped. The session key is now invalid.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
