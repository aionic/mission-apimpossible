/**
 * Tests for SSE accumulation.
 *
 * These exist because `npm test` previously ran ZERO tests and exited 0 - a
 * green signal that meant nothing - while this exact code shipped two real
 * bugs that a human found by reading. Both are pinned below.
 */

import { strict as assert } from 'node:assert';
import { describe, it } from 'node:test';

import { SseAccumulator } from '../sse';

function collect(chunks: string[]): {
  text: string;
  deltas: string[];
  status: string;
  usage: unknown;
} {
  const deltas: string[] = [];
  const acc = new SseAccumulator((d) => deltas.push(d));
  for (const c of chunks) {
    acc.push(c);
  }
  acc.end();
  const outcome = acc.outcome;
  return { text: outcome.outputText, deltas, status: outcome.status, usage: outcome.usage };
}

const delta = (t: string): string =>
  `data: ${JSON.stringify({ type: 'response.output_text.delta', delta: t })}`;

const completed = (usage?: unknown): string =>
  `data: ${JSON.stringify({ type: 'response.completed', response: usage ? { usage } : {} })}`;

describe('SseAccumulator', () => {
  it('concatenates deltas across LF-framed events', () => {
    const r = collect([`${delta('Hello')}\n\n${delta(', world')}\n\n`]);
    assert.equal(r.text, 'Hello, world');
    assert.deepEqual(r.deltas, ['Hello', ', world']);
  });

  it('parses CRLF framing', () => {
    // REGRESSION: splitting on '\n\n' alone never matched a CRLF gateway, so
    // the buffer grew without bound and no event ever dispatched. The call
    // returned empty output instead of failing visibly.
    const r = collect([`${delta('a')}\r\n\r\n${delta('b')}\r\n\r\n`]);
    assert.equal(r.text, 'ab');
  });

  it('processes a trailing frame that has no terminating blank line', () => {
    // REGRESSION: the final frame was dropped. For Responses that frame is
    // typically response.completed carrying usage, so a successful call
    // reported 'incomplete' with no usage at all.
    const r = collect([
      `${delta('x')}\n\n${completed({ input_tokens: 5, output_tokens: 7, total_tokens: 12 })}`,
    ]);
    assert.equal(r.text, 'x');
    assert.equal(r.status, 'completed');
    assert.deepEqual(r.usage, { input_tokens: 5, output_tokens: 7, total_tokens: 12 });
  });

  it('reassembles a frame split across chunk boundaries', () => {
    const whole = `${delta('split me')}\n\n`;
    const cut = Math.floor(whole.length / 2);
    const r = collect([whole.slice(0, cut), whole.slice(cut)]);
    assert.equal(r.text, 'split me');
  });

  it('ignores [DONE] and empty data lines', () => {
    const r = collect([`${delta('a')}\n\ndata: [DONE]\n\ndata:\n\n`]);
    assert.equal(r.text, 'a');
  });

  it('ignores a malformed frame without aborting the stream', () => {
    const r = collect([`data: {not json\n\n${delta('survived')}\n\n`]);
    assert.equal(r.text, 'survived');
  });

  it('ignores comment and non-data lines', () => {
    const r = collect([`: keep-alive\n\nevent: ping\n\n${delta('ok')}\n\n`]);
    assert.equal(r.text, 'ok');
  });

  it('records an error event delivered under HTTP 200 as a terminal failure', () => {
    // An SSE error arrives inside a 200 response. Reporting success here would
    // be actively misleading.
    const r = collect([`${delta('partial')}\n\ndata: ${JSON.stringify({ type: 'error' })}\n\n`]);
    assert.equal(r.status, 'failed');
    assert.equal(r.text, 'partial');
  });

  it('leaves usage undefined when none is reported, never zero', () => {
    const r = collect([`${delta('a')}\n\n${completed()}\n\n`]);
    assert.equal(r.status, 'completed');
    assert.equal(r.usage, undefined);
  });

  it('reports response.incomplete', () => {
    const r = collect([`data: ${JSON.stringify({ type: 'response.incomplete' })}\n\n`]);
    assert.equal(r.status, 'incomplete');
  });

  it('defaults to incomplete when the stream ends with no terminal event', () => {
    const r = collect([`${delta('truncated')}\n\n`]);
    assert.equal(r.status, 'incomplete');
    assert.equal(r.text, 'truncated');
  });

  it('marks a cancelled stream as client_disconnected', () => {
    const acc = new SseAccumulator(() => {});
    acc.push(`${delta('a')}\n\n`);
    acc.markDisconnected();
    assert.equal(acc.outcome.status, 'client_disconnected');
  });

  it('is safe to end twice', () => {
    const acc = new SseAccumulator(() => {});
    acc.push(`${delta('a')}`);
    acc.end();
    acc.end();
    assert.equal(acc.outcome.outputText, 'a');
  });
});
