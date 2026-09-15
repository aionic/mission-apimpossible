/**
 * Server-sent event accumulation for the Responses API.
 *
 * Extracted from `streamResponse` for one reason: it was previously a closure
 * over local variables inside that function, which made it impossible to test
 * without a live `fetch` Response. Two real bugs lived here undetected until a
 * code review found them by reading:
 *
 *   * the trailing frame was dropped, and for Responses that frame is
 *     typically `response.completed` carrying usage - so a successful call
 *     reported 'incomplete' with no usage;
 *
 *   * frames were split on '\n\n' only, so a gateway or proxy using CRLF
 *     framing would never match. The buffer would grow without bound, NO event
 *     would ever dispatch, and the call would return empty output rather than
 *     failing visibly.
 *
 * Both are now covered by tests, which is the point of the extraction. This
 * module deliberately takes decoded strings rather than bytes, so it can be
 * driven from a plain test without a stream.
 */

export interface TokenUsage {
  readonly input_tokens?: number;
  readonly output_tokens?: number;
  readonly total_tokens?: number;
}

export interface SseOutcome {
  readonly outputText: string;
  readonly status: string;
  readonly usage: TokenUsage | undefined;
}

/**
 * SSE frames are separated by a blank line, which the specification permits to
 * be either LF LF or CRLF CRLF.
 */
const FRAME_SEPARATOR = /\r?\n\r?\n/;

export class SseAccumulator {
  private buffer = '';
  private status = 'incomplete';
  private usage: TokenUsage | undefined;
  private readonly collected: string[] = [];

  constructor(private readonly onDelta: (delta: string) => void) {}

  /** Feeds a decoded chunk. Partial trailing frames are retained. */
  push(chunk: string): void {
    this.buffer += chunk;

    const frames = this.buffer.split(FRAME_SEPARATOR);
    // The last element is an incomplete frame; keep it for the next read.
    this.buffer = frames.pop() ?? '';

    for (const frame of frames) {
      this.handleFrame(frame);
    }
  }

  /**
   * Processes whatever remains once the stream ends.
   *
   * A stream that ends without a trailing blank line still has a final,
   * meaningful frame in the buffer.
   */
  end(): void {
    const remaining = this.buffer.trim();
    this.buffer = '';
    if (!remaining) {
      return;
    }
    for (const frame of remaining.split(FRAME_SEPARATOR)) {
      this.handleFrame(frame);
    }
  }

  /** Records a cancelled stream. Never retried: tokens may already be spent. */
  markDisconnected(): void {
    this.status = 'client_disconnected';
  }

  get outcome(): SseOutcome {
    return {
      outputText: this.collected.join(''),
      status: this.status,
      usage: this.usage,
    };
  }

  private handleFrame(frame: string): void {
    const dataLine = frame.split(/\r?\n/).find((line) => line.startsWith('data:'));
    if (!dataLine) {
      return;
    }

    const payload = dataLine.slice('data:'.length).trim();
    if (!payload || payload === '[DONE]') {
      return;
    }

    let event: { type?: string; delta?: string; response?: { usage?: TokenUsage } };
    try {
      event = JSON.parse(payload) as typeof event;
    } catch {
      // A malformed frame is not worth aborting an otherwise good stream.
      return;
    }

    switch (event.type) {
      case 'response.output_text.delta':
        if (event.delta) {
          this.collected.push(event.delta);
          this.onDelta(event.delta);
        }
        break;
      case 'response.completed':
        this.status = 'completed';
        this.usage = event.response?.usage;
        break;
      case 'response.incomplete':
        this.status = 'incomplete';
        break;
      case 'error':
        // An error event under HTTP 200. Record a terminal failure rather than
        // reporting apparent success.
        this.status = 'failed';
        break;
      default:
        break;
    }
  }
}
