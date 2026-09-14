#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Minimal curl examples for the Mission APIMpossible gateway.
#
# SAFETY NOTES - these are not decoration:
#
#   * The token is held in a shell variable and passed via a config file read
#     from stdin, NOT on the command line. Command-line arguments are visible
#     in the process table to other users on the same machine.
#
#   * Do not add -v. Verbose curl prints request headers, including your
#     bearer token, and those lines end up in terminal scrollback and CI logs.
#
#   * Prompts are read from files or stdin rather than typed as arguments,
#     because shell history would otherwise capture proprietary source code.
#
# Prerequisites:
#   az login --tenant <tenant-id>
#   export MAP_ENDPOINT=...   MAP_MODEL=...
# ---------------------------------------------------------------------------
set -euo pipefail

: "${MAP_ENDPOINT:?Set MAP_ENDPOINT to the gateway Responses endpoint}"
: "${MAP_MODEL:?Set MAP_MODEL to the approved deployment name}"

SCOPE="${MAP_SCOPE:-https://ai.azure.com/.default}"

# Acquire a token for YOUR identity. Never a service principal here: using one
# would not demonstrate the human-identity path this sample exists to show.
TOKEN="$(az account get-access-token --scope "$SCOPE" --query accessToken -o tsv)"

# One correlation GUID per invocation.
CORRELATION_ID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)"

echo "Correlation ID: ${CORRELATION_ID}" >&2
echo >&2

# Headers go through a config file on stdin so the token never appears in
# argv. `-K -` / `--config -` tells curl to read configuration from standard
# input.
#
# NOTE: curl config files are strictly LINE-ORIENTED. A quoted value cannot
# span multiple lines, so the request body must be collapsed to a single line
# before it is interpolated. A multi-line heredoc here produces
# "config file option '' is unknown" and the request is never sent - which
# tends to push people back to `-H "Authorization: ..."` on the command line,
# exactly what this mechanism exists to avoid.
curl_with_auth() {
    local body
    body="$(tr -d '\n' <<<"$1" | sed 's/  */ /g')"

    curl --silent --show-error --fail-with-body \
         --config - \
         "${MAP_ENDPOINT}" <<EOF
header = "Authorization: Bearer ${TOKEN}"
header = "Content-Type: application/json"
header = "x-correlation-id: ${CORRELATION_ID}"
--include
--data-raw "${body}"
EOF
}

# ---------------------------------------------------------------------------
# 1. Basic request
#
# store:false is sent explicitly. The gateway would inject it anyway, but
# stating it keeps the stateless intent visible at the call site.
# ---------------------------------------------------------------------------
echo "=== Basic request ===" >&2
curl_with_auth "$(cat <<JSON
{
  "model": "${MAP_MODEL}",
  "input": "Explain what a race condition is, in two sentences.",
  "store": false,
  "max_output_tokens": 256
}
JSON
)"

echo >&2
echo >&2

# ---------------------------------------------------------------------------
# 2. Streaming
#
# --no-buffer is required or curl will hold the SSE stream in its own buffer,
# which makes a correctly-streaming gateway look like it is not streaming.
# ---------------------------------------------------------------------------
echo "=== Streaming ===" >&2
curl --silent --show-error --no-buffer \
     --config - \
     "${MAP_ENDPOINT}" <<EOF
header = "Authorization: Bearer ${TOKEN}"
header = "Content-Type: application/json"
header = "x-correlation-id: ${CORRELATION_ID}"
--data-raw "{\"model\":\"${MAP_MODEL}\",\"input\":\"Count to five.\",\"store\":false,\"stream\":true,\"max_output_tokens\":128}"
EOF

echo >&2
echo "Done. Quote ${CORRELATION_ID} if you need to report a problem." >&2
