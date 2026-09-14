#!/usr/bin/env python
"""Smoke test for the Mission APIMpossible gateway.

Proves the end-to-end property in one command: your own Microsoft Entra
identity reaches a Foundry-hosted model through API Management, and you can
correlate the call afterwards without anyone having logged your prompt.

Usage:
    uv run python examples/python/respond.py "Review this function for races."
    uv run python examples/python/respond.py --stream "Explain this error."
    cat snippet.py | uv run python examples/python/respond.py --stdin

Prints correlation identifiers and token counts. Never prints the bearer
token.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

# Allow running directly from a checkout without installing the package.
sys.path.insert(0, str(Path(__file__).parent))

from map_client import ClientConfig, ConfigError, RequestContext, ResponsesClient  # noqa: E402

DEFAULT_INSTRUCTIONS = (
    "You are a senior software engineer reviewing code. Be specific and concise. "
    "Point out concrete defects rather than general advice."
)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="respond.py",
        description="Call the governed Responses endpoint as yourself.",
        epilog=(
            "Prefer --stdin for proprietary source: command-line arguments are "
            "recorded in shell history."
        ),
    )
    parser.add_argument(
        "prompt",
        nargs="?",
        help="The prompt. Omit when using --stdin.",
    )
    parser.add_argument(
        "--stdin",
        action="store_true",
        help="Read the prompt from standard input, keeping it out of shell history.",
    )
    parser.add_argument(
        "--stream",
        action="store_true",
        help="Stream the response as server-sent events.",
    )
    parser.add_argument(
        "--instructions",
        default=DEFAULT_INSTRUCTIONS,
        help="System-style guidance for this single stateless request.",
    )
    parser.add_argument(
        "--max-output-tokens",
        type=int,
        default=4096,
        help="Upper bound on generated tokens (default: 4096).",
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="Print only the model output, omitting the correlation summary.",
    )
    return parser


def read_prompt(args: argparse.Namespace) -> str:
    if args.stdin:
        data = sys.stdin.read().strip()
        if not data:
            raise SystemExit("error: --stdin was given but standard input was empty.")
        return data

    if not args.prompt:
        raise SystemExit("error: provide a prompt argument or use --stdin.")

    return args.prompt


def main() -> int:
    args = build_parser().parse_args()

    try:
        config = ClientConfig.from_env()
    except ConfigError as exc:
        print(f"Configuration error: {exc}", file=sys.stderr)
        return 2

    prompt = read_prompt(args)
    context = RequestContext()

    if not args.quiet:
        # Printed before the call so a hung or failed request can still be
        # reported by correlation ID.
        print(f"Correlation ID     : {context.correlation_id}", file=sys.stderr)
        print(f"Endpoint           : {config.endpoint}", file=sys.stderr)
        print("", file=sys.stderr)

    try:
        client = ResponsesClient(config)

        if args.stream:
            result = None
            for delta, final in client.stream(
                prompt,
                instructions=args.instructions,
                max_output_tokens=args.max_output_tokens,
                context=context,
            ):
                if final is not None:
                    result = final
                    break
                print(delta, end="", flush=True)
            print()
        else:
            result = client.invoke(
                prompt,
                instructions=args.instructions,
                max_output_tokens=args.max_output_tokens,
                context=context,
            )
            print(result.output_text)

    except KeyboardInterrupt:
        # Deliberately not retried. The backend may already have consumed
        # tokens for this request.
        print("\nCancelled. The request was not resent.", file=sys.stderr)
        return 130

    except ValueError as exc:
        print(f"\nRequest rejected locally: {exc}", file=sys.stderr)
        return 2

    except Exception as exc:  # noqa: BLE001 - surface anything the SDK raises
        print(f"\nRequest failed: {type(exc).__name__}: {exc}", file=sys.stderr)
        print(
            f"Quote correlation ID {context.correlation_id} when reporting this.",
            file=sys.stderr,
        )
        return 1

    if not args.quiet and result is not None:
        print("", file=sys.stderr)
        print("-" * 60, file=sys.stderr)
        print(result.summary(), file=sys.stderr)

        if result.usage_source == "unavailable":
            print("", file=sys.stderr)
            print(
                "Note: token usage was not reported. This is expected for "
                "interrupted streams and is recorded as unavailable rather "
                "than zero.",
                file=sys.stderr,
            )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
