"""The loopback listener.

Two endpoints, and nothing else:

* ``POST /v1/responses`` - forward to the gateway with the developer's token.
* ``GET  /v1/models``    - advertise the approved deployments.

The forwarding path is deliberately dumb. The request body is read as bytes and
written as bytes; the response is streamed back chunk by chunk without being
parsed, buffered, or re-framed. Every guarantee about the request contract is
enforced at the gateway, where it has been tested against a live deployment,
and anything this process rewrote would be enforced somewhere those tests do
not reach.
"""

from __future__ import annotations

import json
import logging
from typing import Any

from aiohttp import ClientSession, ClientTimeout, web

from map_proxy.capture import Capture
from map_proxy.config import BIND_HOST, ProxyConfig
from map_proxy.tokens import (
    TokenAcquisitionError,
    TokenProvider,
    extract_presented_secret,
    secret_matches,
)

logger = logging.getLogger("map_proxy")

# Hop-by-hop headers, plus the ones this proxy owns. Forwarding any of these
# upstream would either confuse the gateway or contradict what aiohttp is
# already doing with the connection.
_HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
    "host",
    "content-length",
    "authorization",
}

_STATE_CONFIG = web.AppKey[ProxyConfig]("config")
_STATE_TOKENS = web.AppKey[TokenProvider]("tokens")
_STATE_SECRET = web.AppKey[str]("secret")
_STATE_CAPTURE = web.AppKey["Capture | None"]("capture")
_STATE_SESSION = web.AppKey[ClientSession]("session")


def _error(status: int, code: str, message: str) -> web.Response:
    """An OpenAI-shaped error, which is what the IDE expects to parse."""
    return web.json_response(
        {"error": {"code": code, "message": message, "type": "invalid_request_error"}},
        status=status,
    )


@web.middleware
async def authorise(request: web.Request, handler: Any) -> web.StreamResponse:
    """Rejects anything that does not present the session secret."""
    expected = request.app[_STATE_SECRET]
    presented = extract_presented_secret(request.headers.get("Authorization"))

    if not secret_matches(presented, expected):
        # Deliberately says nothing about whether the secret was absent,
        # malformed, or simply wrong.
        logger.warning("Rejected a request with a missing or incorrect session key.")
        return _error(
            401,
            "invalid_api_key",
            "Invalid API key for the local Mission APIMpossible proxy. "
            "Copy the key printed when the proxy started.",
        )

    return await handler(request)  # type: ignore[no-any-return]


async def handle_models(request: web.Request) -> web.StreamResponse:
    """Advertises the approved deployments.

    Served from configuration, never from Foundry. The proxy must not be able
    to advertise a model the gateway would reject - a picker entry that always
    fails is worse than no entry at all.
    """
    config = request.app[_STATE_CONFIG]
    return web.json_response(
        {
            "object": "list",
            "data": [
                {
                    "id": m.deployment,
                    "object": "model",
                    "owned_by": "mission-apimpossible",
                }
                for m in config.models
            ],
        }
    )


async def handle_responses(request: web.Request) -> web.StreamResponse:
    """Forwards a Responses request to the gateway as the developer."""
    config = request.app[_STATE_CONFIG]
    tokens = request.app[_STATE_TOKENS]
    capture = request.app[_STATE_CAPTURE]
    session = request.app[_STATE_SESSION]

    body = await request.read()

    if capture is not None:
        try:
            capture.record_request(
                path=str(request.rel_url),
                headers=dict(request.headers),
                body=json.loads(body) if body else {},
            )
        except (ValueError, TypeError):
            capture.record("request", path=str(request.rel_url), note="unparseable JSON body")

    try:
        token = tokens.get()
    except TokenAcquisitionError as exc:
        logger.error("%s", exc)
        return _error(401, "not_signed_in", str(exc))

    # Forward the caller's headers except the ones this proxy owns, so
    # correlation and trace context survive end to end.
    forwarded = {k: v for k, v in request.headers.items() if k.lower() not in _HOP_BY_HOP}
    forwarded["Authorization"] = f"Bearer {token}"

    try:
        upstream = await session.post(
            config.gateway_endpoint,
            data=body,
            headers=forwarded,
            timeout=ClientTimeout(total=config.timeout_seconds),
        )
    except Exception as exc:  # noqa: BLE001 - surfaced as a gateway error
        logger.error("Could not reach the gateway: %s", exc)
        return _error(502, "gateway_unreachable", f"Could not reach the gateway: {exc}")

    async with upstream:
        # A rejected token is dropped so the next request acquires a fresh one
        # rather than replaying a credential the gateway already refused.
        if upstream.status == 401:
            tokens.invalidate()

        response = web.StreamResponse(status=upstream.status)

        for key, value in upstream.headers.items():
            if key.lower() not in _HOP_BY_HOP:
                response.headers[key] = value

        # Streaming must not be buffered here. Buffering would hold the whole
        # answer until completion and turn a streaming UI into a long pause -
        # the exact behaviour the gateway sets buffer-response=false to avoid.
        response.enable_chunked_encoding()
        await response.prepare(request)

        if capture is not None:
            capture.record_response(
                status=upstream.status,
                headers=dict(upstream.headers),
            )

        try:
            async for chunk in upstream.content.iter_any():
                await response.write(chunk)
        except ConnectionResetError:
            # The IDE went away mid-stream. Normal when a user cancels, and
            # explicitly NOT retried: the backend may already have spent tokens.
            logger.info("Client disconnected mid-stream; not retrying.")
            return response

        await response.write_eof()
        return response


def build_app(
    config: ProxyConfig,
    tokens: TokenProvider,
    secret: str,
    capture: Capture | None = None,
) -> web.Application:
    """Assembles the application."""
    app = web.Application(middlewares=[authorise])
    app[_STATE_CONFIG] = config
    app[_STATE_TOKENS] = tokens
    app[_STATE_SECRET] = secret
    app[_STATE_CAPTURE] = capture

    app.router.add_post("/v1/responses", handle_responses)
    app.router.add_get("/v1/models", handle_models)

    async def _open_session(application: web.Application) -> None:
        application[_STATE_SESSION] = ClientSession()

    async def _close_session(application: web.Application) -> None:
        await application[_STATE_SESSION].close()

    app.on_startup.append(_open_session)
    app.on_cleanup.append(_close_session)
    return app


def run(app: web.Application, port: int) -> None:
    """Serves on loopback only."""
    web.run_app(app, host=BIND_HOST, port=port, print=None)
