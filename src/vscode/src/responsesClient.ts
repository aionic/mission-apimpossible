/**
 * Transport for the governed Responses endpoint.
 *
 * Uses `fetch` directly rather than the OpenAI SDK. The reason is narrow and
 * deliberate: this client needs raw response headers (to recover the Foundry
 * request ID), strict abort semantics, and a guarantee of zero automatic
 * retries. Those are easier to prove in forty lines than to configure.
 *
 * `POST /responses` is not idempotent. A retry after the backend accepted a
 * request can duplicate inference, token consumption, and cost, so there is
 * no retry logic here at all.
 */

import { correlationHeaders, type RequestContext } from './correlation';

export interface ResponsesConfig {
  readonly endpoint: string;
  readonly model: string;
  readonly maxOutputTokens: number;
}

export interface InvocationResult {
  readonly correlationId: string;
  readonly traceId: string;
  readonly foundryRequestId: string | undefined;
  readonly status: string;
  readonly outputText: string;
  readonly inputTokens: number | undefined;
  readonly outputTokens: number | undefined;
  readonly totalTokens: number | undefined;
  /** 'reported' or 'unavailable'. Absent usage is never reported as zero. */
  readonly usageSource: string;
}

export class GatewayError extends Error {
  constructor(
    message: string,
    readonly status: number,
    readonly correlationId: string,
    readonly code: string,
  ) {
    super(message);
    this.name = 'GatewayError';
  }
}

/** 48 KiB, matching the gateway bound. Checked locally for a clearer error. */
const MAX_INPUT_BYTES = 49152;

export function assertInputWithinLimit(prompt: string, instructions?: string): void {
  const size =
    Buffer.byteLength(prompt, 'utf8') +
    (instructions ? Buffer.byteLength(instructions, 'utf8') : 0);

  if (size > MAX_INPUT_BYTES) {
    throw new Error(
      `Input is ${size} bytes, over the ${MAX_INPUT_BYTES} byte gateway limit. ` +
        `Select a narrower excerpt rather than the whole file.`,
    );
  }
}

/**
 * Validates the configured endpoint before a token is ever attached to it.
 *
 * The endpoint is user-configurable, so this is the boundary that stops a
 * bearer token being sent somewhere unintended.
 */
export function assertTrustedEndpoint(endpoint: string): URL {
  let url: URL;
  try {
    url = new URL(endpoint);
  } catch {
    throw new Error(`Configured endpoint is not a valid URL: ${endpoint}`);
  }

  if (url.protocol !== 'https:') {
    throw new Error(
      `Endpoint must use https, got '${url.protocol}'. ` +
        `Refusing to send a bearer token over an untrusted transport.`,
    );
  }

  return url;
}

function buildBody(
  config: ResponsesConfig,
  prompt: string,
  instructions: string | undefined,
  stream: boolean,
): Record<string, unknown> {
  const body: Record<string, unknown> = {
    model: config.model,
    input: prompt,
    // Sent explicitly. The gateway injects it anyway, but stating it keeps the
    // stateless intent visible at the call site rather than implicit in
    // someone else's policy.
    store: false,
    max_output_tokens: config.maxOutputTokens,
  };

  if (instructions) {
    body['instructions'] = instructions;
  }
  if (stream) {
    body['stream'] = true;
  }

  return body;
}

async function readErrorBody(response: Response, fallbackCorrelation: string): Promise<GatewayError> {
  let code = 'unknown';
  let message = 'The gateway rejected the request.';
  let correlationId = response.headers.get('x-correlation-id') ?? fallbackCorrelation;

  try {
    const parsed = (await response.json()) as {
      error?: { code?: string; message?: string; correlation_id?: string };
    };
    code = parsed.error?.code ?? code;
    message = parsed.error?.message ?? message;
    correlationId = parsed.error?.correlation_id ?? correlationId;
  } catch {
    // The gateway returns a generic body by design; an unparseable one is
    // not worth surfacing further.
  }

  return new GatewayError(message, response.status, correlationId, code);
}

/**
 * Streams a response, invoking `onDelta` as text arrives.
 *
 * Two streaming realities this handles rather than hides:
 *  - a mid-stream failure can arrive as an SSE error event under HTTP 200, so
 *    a 200 does not by itself mean generation succeeded;
 *  - usage may never arrive for an interrupted stream, and is then reported
 *    as 'unavailable' rather than zero.
 */
export async function streamResponse(
  config: ResponsesConfig,
  accessToken: string,
  prompt: string,
  instructions: string | undefined,
  context: RequestContext,
  onDelta: (text: string) => void,
  signal: AbortSignal,
): Promise<InvocationResult> {
  assertInputWithinLimit(prompt, instructions);
  const url = assertTrustedEndpoint(config.endpoint);

  const response = await fetch(url, {
    method: 'POST',
    signal,
    headers: {
      // The developer's own token, forwarded unchanged by the gateway.
      Authorization: `Bearer ${accessToken}`,
      'Content-Type': 'application/json',
      Accept: 'text/event-stream',
      ...correlationHeaders(context),
    },
    body: JSON.stringify(buildBody(config, prompt, instructions, true)),
    // No retry wrapper anywhere in this call path.
  });

  const correlationId = response.headers.get('x-correlation-id') ?? context.correlationId;
  const foundryRequestId = response.headers.get('x-foundry-request-id') ?? undefined;

  if (!response.ok) {
    throw await readErrorBody(response, context.correlationId);
  }

  if (!response.body) {
    throw new GatewayError('The gateway returned no response body.', 502, correlationId, 'empty_body');
  }

  const reader = response.body.getReader();
  const decoder = new TextDecoder();

  let buffer = '';
  let status = 'incomplete';
  const collected: string[] = [];
  let usage: { input_tokens?: number; output_tokens?: number; total_tokens?: number } | undefined;

  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) {
        break;
      }

      buffer += decoder.decode(value, { stream: true });

      // SSE frames are separated by a blank line.
      const frames = buffer.split('\n\n');
      buffer = frames.pop() ?? '';

      for (const frame of frames) {
        const dataLine = frame.split('\n').find((line) => line.startsWith('data:'));
        if (!dataLine) {
          continue;
        }

        const payload = dataLine.slice('data:'.length).trim();
        if (!payload || payload === '[DONE]') {
          continue;
        }

        try {
          const event = JSON.parse(payload) as {
            type?: string;
            delta?: string;
            response?: { usage?: typeof usage };
          };

          switch (event.type) {
            case 'response.output_text.delta':
              if (event.delta) {
                collected.push(event.delta);
                onDelta(event.delta);
              }
              break;
            case 'response.completed':
              status = 'completed';
              usage = event.response?.usage;
              break;
            case 'response.incomplete':
              status = 'incomplete';
              break;
            case 'error':
              // An error event under HTTP 200. Record a terminal failure
              // rather than reporting apparent success.
              status = 'failed';
              break;
            default:
              break;
          }
        } catch {
          // A malformed frame is not worth aborting an otherwise good stream.
        }
      }
    }
  } catch (error) {
    if (signal.aborted) {
      // Cancellation is a normal outcome. Do NOT resend: the backend may
      // already have consumed tokens for this request.
      status = 'client_disconnected';
    } else {
      throw error;
    }
  } finally {
    reader.releaseLock();
  }

  return {
    correlationId,
    traceId: context.traceId,
    foundryRequestId,
    status,
    outputText: collected.join(''),
    inputTokens: usage?.input_tokens,
    outputTokens: usage?.output_tokens,
    totalTokens: usage?.total_tokens,
    usageSource: usage ? 'reported' : 'unavailable',
  };
}
