/**
 * Tests for correlation identifiers and the endpoint/input guards.
 *
 * These cover the properties a reviewer would otherwise have to take on faith:
 * that identifiers are well-formed W3C values, that they are fresh per
 * invocation, and that the client refuses an untrusted endpoint before a token
 * is ever attached to a request.
 */

import { strict as assert } from 'node:assert';
import { describe, it } from 'node:test';

import { correlationHeaders, createRequestContext } from '../correlation';
import { assertInputWithinLimit, assertTrustedEndpoint } from '../responsesClient';

describe('createRequestContext', () => {
  it('produces a v4 UUID correlation ID', () => {
    const { correlationId } = createRequestContext();
    assert.match(correlationId, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  });

  it('produces W3C-shaped trace and span IDs', () => {
    const { traceId, spanId } = createRequestContext();
    assert.match(traceId, /^[0-9a-f]{32}$/);
    assert.match(spanId, /^[0-9a-f]{16}$/);
    // All-zero IDs are invalid per the W3C trace-context specification.
    assert.notEqual(traceId, '0'.repeat(32));
    assert.notEqual(spanId, '0'.repeat(16));
  });

  it('is fresh per invocation', () => {
    // Reusing a correlation ID across calls would silently merge unrelated
    // requests in every query under queries/.
    const a = createRequestContext();
    const b = createRequestContext();
    assert.notEqual(a.correlationId, b.correlationId);
    assert.notEqual(a.traceId, b.traceId);
    assert.notEqual(a.spanId, b.spanId);
  });
});

describe('correlationHeaders', () => {
  it('emits a valid traceparent binding the trace and span', () => {
    const ctx = createRequestContext();
    const headers = correlationHeaders(ctx);
    assert.equal(headers['traceparent'], `00-${ctx.traceId}-${ctx.spanId}-01`);
  });

  it('carries the correlation ID', () => {
    const ctx = createRequestContext();
    assert.equal(correlationHeaders(ctx)['x-correlation-id'], ctx.correlationId);
  });

  it('never emits an Authorization header', () => {
    // Correlation and credentials are assembled in different places on
    // purpose; this pins that separation.
    const headers = correlationHeaders(createRequestContext());
    for (const name of Object.keys(headers)) {
      assert.notEqual(name.toLowerCase(), 'authorization');
    }
  });
});

describe('assertTrustedEndpoint', () => {
  it('accepts an HTTPS gateway URL', () => {
    const url = assertTrustedEndpoint('https://example.azure-api.net/openai/v1/responses');
    assert.equal(url.protocol, 'https:');
  });

  it('rejects plaintext HTTP', () => {
    // A bearer token must never leave the machine unencrypted.
    assert.throws(() => assertTrustedEndpoint('http://example.azure-api.net/openai/v1/responses'));
  });

  it('rejects a malformed URL', () => {
    assert.throws(() => assertTrustedEndpoint('not a url'));
  });
});

describe('assertInputWithinLimit', () => {
  it('accepts an ordinary prompt', () => {
    assert.doesNotThrow(() => assertInputWithinLimit('Review this function for races.'));
  });

  it('rejects input beyond the gateway bound', () => {
    assert.throws(() => assertInputWithinLimit('a'.repeat(49153)));
  });

  it('counts instructions toward the same bound', () => {
    // Checking the prompt alone would let the aggregate sail past the limit
    // and fail at the gateway instead, with a worse error.
    assert.throws(() => assertInputWithinLimit('a'.repeat(30000), 'b'.repeat(30000)));
  });

  it('measures BYTES rather than characters', () => {
    // Multi-byte characters are where a character-based check silently
    // under-counts. A 4-byte emoji is one JavaScript code point pair.
    const emoji = '\u{1F600}'; // 4 bytes in UTF-8
    assert.throws(() => assertInputWithinLimit(emoji.repeat(13000)));
  });
});
