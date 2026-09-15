"""A local Entra-to-"API key" adapter for the Mission APIMpossible gateway.

The gateway authenticates developers with their own Microsoft Entra identity.
Most IDEs cannot do that: they offer a bring-your-own-key box - a base URL and
a static secret - with no notion of interactive sign-in, tenants, or a token
that expires in an hour.

This package bridges the two on the developer's own machine::

    IDE  --127.0.0.1, local secret-->  proxy  --Bearer <Entra>-->  APIM  -->  Foundry

The IDE believes it is talking to an ordinary key-authenticated provider. The
request that actually leaves the machine carries the developer's real identity,
and telemetry still attributes it to them.

It forwards the request body **unchanged**. It does not translate protocols,
rewrite fields, or interpret content. The gateway is where the request contract
is enforced and proven, and a local process that quietly disagreed with it
would be a source of bugs nobody would think to look for.

The one thing it changes is the credential.

See ``docs/local-proxy.md`` for the full design, the security model, and why a
local identity *courier* is not the server-side authentication *shim* this
project forbids.
"""

from __future__ import annotations

__all__ = ["__version__"]

__version__ = "1.0.0"
