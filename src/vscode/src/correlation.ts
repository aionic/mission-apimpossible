/**
 * Per-request correlation and W3C trace context.
 *
 * One GUID and one trace per invocation. The correlation ID is telemetry
 * only: it is never used for authentication, authorization, or routing, so a
 * caller gaining control of it gains nothing.
 */

import { randomUUID, randomBytes } from 'node:crypto';

const TRACE_VERSION = '00';
const TRACE_FLAGS_SAMPLED = '01';

export interface RequestContext {
  readonly correlationId: string;
  readonly traceId: string;
  readonly spanId: string;
  readonly traceparent: string;
}

export function createRequestContext(): RequestContext {
  const correlationId = randomUUID();
  // 32 lowercase hex chars, per W3C Trace Context.
  const traceId = randomBytes(16).toString('hex');
  // 16 lowercase hex chars.
  const spanId = randomBytes(8).toString('hex');

  return {
    correlationId,
    traceId,
    spanId,
    traceparent: `${TRACE_VERSION}-${traceId}-${spanId}-${TRACE_FLAGS_SAMPLED}`,
  };
}

/**
 * Correlation headers for a request.
 *
 * Note what is absent: no identity headers. The gateway derives identity
 * solely from the validated token and strips caller-supplied `x-user-id`,
 * `x-tenant-id`, and similar. Sending them would achieve nothing.
 */
export function correlationHeaders(context: RequestContext): Record<string, string> {
  return {
    'x-correlation-id': context.correlationId,
    traceparent: context.traceparent,
  };
}
