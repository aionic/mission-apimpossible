/**
 * Serialized appending into a document.
 *
 * Streaming deltas arrive far faster than VS Code can apply edits, and
 * `TextEditor.edit()` REJECTS an edit that overlaps one already in flight - it
 * resolves `false` rather than throwing. The original code called
 * `void appendTo(editor, delta)` per delta: nothing awaited the previous edit,
 * and nothing inspected the boolean.
 *
 * The result was not a crash or an error. It was plausible-looking output with
 * words missing:
 *
 *     "This a only as executable Concrete single row render as intended to be2."
 *
 * Silent, partial, and easy to mistake for the model behaving badly - which
 * makes it considerably worse than a visible failure.
 *
 * This class coalesces pending text and applies it through a single chain, so
 * exactly one edit is ever in flight. Rejected text is put back rather than
 * dropped. It is deliberately written against a narrow `EditTarget` interface
 * rather than `vscode.TextEditor`, so the ordering and loss behaviour can be
 * tested without a VS Code host.
 */

export interface EditTarget {
  /** Appends text. Resolves false when the edit could not be applied. */
  applyEdit(text: string): Promise<boolean>;
}

/** Bounded so a persistently failing editor cannot spin forever. */
const MAX_CONSECUTIVE_FAILURES = 5;

export class DocumentAppender {
  private pending = '';
  private chain: Promise<void> = Promise.resolve();
  private consecutiveFailures = 0;
  private droppedCharacters = 0;

  constructor(private readonly target: EditTarget) {}

  /** Queues text. Never awaited by the caller; ordering is preserved here. */
  append(text: string): void {
    if (!text) {
      return;
    }
    this.pending += text;
    this.chain = this.chain.then(() => this.flush());
  }

  /** Waits for everything queued so far to be written. */
  async drain(): Promise<void> {
    this.chain = this.chain.then(() => this.flush());
    await this.chain;
  }

  /**
   * Characters that could not be written.
   *
   * Surfaced rather than swallowed: truncated output that looks complete is
   * the failure mode this class exists to prevent, so if it happens anyway the
   * user is told.
   */
  get lostCharacters(): number {
    return this.droppedCharacters;
  }

  /**
   * Drains `pending` in a loop rather than rescheduling onto the chain.
   *
   * An earlier version retried by doing `this.chain = this.chain.then(...)`
   * from inside a chain callback. `drain()` awaits the chain as it stands at
   * the moment it is called, so work appended later was not covered and
   * `drain()` returned before the retries had run. The "survives an editor
   * that throws" test caught it. Keeping the retry inside a single awaited
   * call means drain covers everything.
   */
  private async flush(): Promise<void> {
    while (this.pending) {
      // Coalesce: many deltas become one edit, which is why this stays fast
      // despite being fully serialized.
      const chunk = this.pending;
      this.pending = '';

      let applied = false;
      try {
        applied = await this.target.applyEdit(chunk);
      } catch {
        applied = false;
      }

      if (applied) {
        this.consecutiveFailures = 0;
        continue;
      }

      this.consecutiveFailures += 1;

      if (this.consecutiveFailures >= MAX_CONSECUTIVE_FAILURES) {
        // Give up on this chunk, but COUNT it. Silently discarding is what
        // produced the garbled output in the first place.
        this.droppedCharacters += chunk.length;
        this.consecutiveFailures = 0;
        continue;
      }

      // Put it back at the FRONT so ordering survives the retry.
      this.pending = chunk + this.pending;
    }
  }
}
