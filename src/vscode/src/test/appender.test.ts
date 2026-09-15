/**
 * Tests for serialized document appending.
 *
 * These pin the bug that produced visibly garbled output in the editor: deltas
 * were written with `void appendTo(...)`, so edits overlapped, VS Code
 * rejected them by resolving `false`, and the rejected text was silently
 * discarded. The user saw plausible sentences with words missing.
 */

import { strict as assert } from 'node:assert';
import { describe, it } from 'node:test';

import { DocumentAppender, type EditTarget } from '../appender';

/** An editor that records writes and can be told to reject some of them. */
class FakeEditor implements EditTarget {
  written = '';
  inFlight = 0;
  maxObservedInFlight = 0;
  private call = 0;

  constructor(private readonly rejectWhen: (call: number) => boolean = () => false) {}

  async applyEdit(text: string): Promise<boolean> {
    this.call += 1;
    const thisCall = this.call;

    this.inFlight += 1;
    this.maxObservedInFlight = Math.max(this.maxObservedInFlight, this.inFlight);

    // Force a real await boundary, which is what made the race possible.
    await new Promise((resolve) => setTimeout(resolve, 1));

    this.inFlight -= 1;

    if (this.rejectWhen(thisCall)) {
      return false;
    }
    this.written += text;
    return true;
  }
}

describe('DocumentAppender', () => {
  it('writes every delta when edits succeed', async () => {
    const editor = new FakeEditor();
    const appender = new DocumentAppender(editor);

    for (const word of ['This ', 'is ', 'a ', 'complete ', 'sentence.']) {
      appender.append(word);
    }
    await appender.drain();

    assert.equal(editor.written, 'This is a complete sentence.');
    assert.equal(appender.lostCharacters, 0);
  });

  it('never allows two edits in flight at once', async () => {
    // THE bug: overlapping edits are rejected by VS Code and the text is lost.
    const editor = new FakeEditor();
    const appender = new DocumentAppender(editor);

    for (let i = 0; i < 50; i++) {
      appender.append(`${i},`);
    }
    await appender.drain();

    assert.equal(editor.maxObservedInFlight, 1);
  });

  it('preserves order under rapid appends', async () => {
    const editor = new FakeEditor();
    const appender = new DocumentAppender(editor);

    const expected = Array.from({ length: 100 }, (_, i) => `${i}|`);
    for (const chunk of expected) {
      appender.append(chunk);
    }
    await appender.drain();

    assert.equal(editor.written, expected.join(''));
  });

  it('retries rejected text instead of dropping it', async () => {
    // Reject the first two edits outright.
    const editor = new FakeEditor((call) => call <= 2);
    const appender = new DocumentAppender(editor);

    appender.append('kept');
    await appender.drain();

    assert.equal(editor.written, 'kept');
    assert.equal(appender.lostCharacters, 0);
  });

  it('keeps ordering when a retry happens mid-stream', async () => {
    const editor = new FakeEditor((call) => call === 2);
    const appender = new DocumentAppender(editor);

    appender.append('alpha-');
    appender.append('beta-');
    appender.append('gamma');
    await appender.drain();

    assert.equal(editor.written.includes('alpha-'), true);
    assert.match(editor.written, /alpha-.*beta-.*gamma|alpha-beta-gamma/);
    assert.equal(appender.lostCharacters, 0);
  });

  it('reports loss rather than hiding it when the editor never accepts', async () => {
    // Silent truncation that looks like complete output is the failure this
    // class exists to prevent. If it cannot write, it must say so.
    const editor = new FakeEditor(() => true);
    const appender = new DocumentAppender(editor);

    appender.append('0123456789');
    await appender.drain();

    assert.equal(editor.written, '');
    assert.equal(appender.lostCharacters, 10);
  });

  it('survives an editor that throws', async () => {
    const throwing: EditTarget = {
      applyEdit: async () => {
        throw new Error('document closed');
      },
    };
    const appender = new DocumentAppender(throwing);

    appender.append('abc');
    await appender.drain();

    assert.equal(appender.lostCharacters, 3);
  });

  it('ignores empty appends', async () => {
    const editor = new FakeEditor();
    const appender = new DocumentAppender(editor);

    appender.append('');
    await appender.drain();

    assert.equal(editor.written, '');
    assert.equal(appender.lostCharacters, 0);
  });

  it('is safe to drain repeatedly', async () => {
    const editor = new FakeEditor();
    const appender = new DocumentAppender(editor);

    appender.append('x');
    await appender.drain();
    await appender.drain();

    assert.equal(editor.written, 'x');
  });
});
