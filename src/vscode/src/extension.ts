/**
 * Mission APIMpossible - VS Code reference integration.
 *
 * Deliberately not a chat product. It exists to demonstrate five things:
 * acquire a user token, create correlation, call the governed endpoint,
 * stream the result, and surface the identifiers needed to trace the call.
 *
 * Consent boundary, stated explicitly: this extension never reads the
 * workspace on its own, never sends a file the user did not select, never
 * applies an edit, and never executes suggested code. The user chooses what
 * leaves the machine, every time.
 */

import * as vscode from 'vscode';
import { DocumentAppender, type EditTarget } from './appender';
import { AuthenticationError, acquireToken, describeSession } from './authentication';
import { createRequestContext } from './correlation';
import {
  GatewayError,
  assertTrustedEndpoint,
  streamResponse,
  type ResponsesConfig,
} from './responsesClient';

const OUTPUT_CHANNEL_NAME = 'Mission APIMpossible';
const DEFAULT_INSTRUCTIONS =
  'You are a senior software engineer reviewing code. Be specific and concise. ' +
  'Point out concrete defects rather than general advice.';

interface ExtensionConfig extends ResponsesConfig {
  readonly tenantId: string;
  readonly scope: string;
}

function readConfig(): ExtensionConfig {
  const cfg = vscode.workspace.getConfiguration('missionApimpossible');

  const endpoint = (cfg.get<string>('endpoint') ?? '').trim();
  const model = (cfg.get<string>('model') ?? '').trim();
  const tenantId = (cfg.get<string>('tenantId') ?? '').trim();
  const scope = (cfg.get<string>('scope') ?? 'https://ai.azure.com/.default').trim();
  const maxOutputTokens = cfg.get<number>('maxOutputTokens') ?? 4096;

  const missing: string[] = [];
  if (!endpoint) missing.push('endpoint');
  if (!model) missing.push('model');
  if (!tenantId) missing.push('tenantId');

  if (missing.length > 0) {
    throw new Error(
      `Mission APIMpossible is not configured. Set: ${missing
        .map((m) => `missionApimpossible.${m}`)
        .join(', ')}. Run scripts/postprovision.ps1 to see the values.`,
    );
  }

  if (!/^[0-9a-fA-F-]{36}$/.test(tenantId)) {
    throw new Error(
      `missionApimpossible.tenantId must be a tenant GUID. ` +
        `'common' and 'organizations' are not valid: this is a single-tenant pattern.`,
    );
  }

  // Validate before any token is attached to this URL.
  assertTrustedEndpoint(endpoint);

  return { endpoint, model, tenantId, scope, maxOutputTokens };
}

/**
 * Presents streamed output in an untitled, in-memory document.
 *
 * Nothing is written to disk by the extension. If the user wants to keep the
 * answer, they save it deliberately.
 */
async function openResultDocument(): Promise<vscode.TextEditor> {
  const document = await vscode.workspace.openTextDocument({
    content: '',
    language: 'markdown',
  });
  return vscode.window.showTextDocument(document, { preview: false });
}

/**
 * Adapts a VS Code editor to the appender's narrow edit interface.
 *
 * `edit()` resolves FALSE when the edit could not be applied - it does not
 * throw. That boolean is the whole signal, and ignoring it is what produced
 * silently truncated output.
 */
function editTargetFor(editor: vscode.TextEditor): EditTarget {
  return {
    applyEdit: async (text: string): Promise<boolean> =>
      editor.edit(
        (builder) => {
          const lastLine = editor.document.lineCount - 1;
          const end = editor.document.lineAt(lastLine).range.end;
          builder.insert(end, text);
        },
        { undoStopBefore: false, undoStopAfter: false },
      ),
  };
}

async function runInvocation(
  output: vscode.OutputChannel,
  prompt: string,
  instructions: string,
): Promise<void> {
  const config = readConfig();
  const context = createRequestContext();

  // Logged before the call so a hung or failed request is still reportable.
  // Only identifiers - never the prompt, never the token.
  output.appendLine(`[${new Date().toISOString()}] correlation=${context.correlationId}`);
  output.appendLine(`  endpoint=${config.endpoint} model=${config.model}`);

  const session = await acquireToken(config.scope, config.tenantId, true);
  if (!session) {
    vscode.window.showWarningMessage('Mission APIMpossible: sign-in was cancelled.');
    return;
  }

  const editor = await openResultDocument();
  const appender = new DocumentAppender(editTargetFor(editor));
  const abort = new AbortController();

  await vscode.window.withProgress(
    {
      location: vscode.ProgressLocation.Notification,
      title: 'Mission APIMpossible',
      cancellable: true,
    },
    async (progress, token) => {
      progress.report({ message: 'Waiting for the model…' });
      token.onCancellationRequested(() => abort.abort());

      try {
        const result = await streamResponse(
          config,
          session.accessToken,
          prompt,
          instructions,
          context,
          (delta) => {
            // Queued, not fired. The appender guarantees one edit in flight.
            appender.append(delta);
          },
          abort.signal,
        );

        const usage =
          result.usageSource === 'reported'
            ? `${result.inputTokens ?? 'n/a'}/${result.outputTokens ?? 'n/a'}/${
                result.totalTokens ?? 'n/a'
              }`
            : 'not reported';

        const footer = [
          '',
          '',
          '---',
          '',
          `- Correlation ID: \`${result.correlationId}\``,
          `- Trace ID: \`${result.traceId}\``,
          `- Foundry Request ID: \`${result.foundryRequestId ?? 'n/a'}\``,
          `- Status: \`${result.status}\``,
          `- Tokens in/out/total: \`${usage}\``,
          '',
        ].join('\n');

        // Drain BEFORE the footer, so the metadata cannot land mid-sentence
        // ahead of streamed text still waiting to be written.
        await appender.drain();
        appender.append(footer);
        await appender.drain();

        if (appender.lostCharacters > 0) {
          vscode.window.showWarningMessage(
            `Mission APIMpossible: ${appender.lostCharacters} characters could not be ` +
              `written to the document. The output above is INCOMPLETE. ` +
              `Quote correlation ID ${result.correlationId} when reporting this.`,
          );
          output.appendLine(`  WARNING lost ${appender.lostCharacters} characters on write`);
        }

        output.appendLine(
          `  status=${result.status} foundryRequestId=${result.foundryRequestId ?? 'n/a'} ` +
            `usageSource=${result.usageSource}`,
        );

        if (result.status === 'client_disconnected') {
          vscode.window.showInformationMessage(
            'Mission APIMpossible: cancelled. The request was not resent.',
          );
        }
      } catch (error) {
        if (error instanceof GatewayError) {
          output.appendLine(`  rejected code=${error.code} status=${error.status}`);
          vscode.window.showErrorMessage(
            `Mission APIMpossible: ${error.message} (correlation ${error.correlationId})`,
          );
          return;
        }

        if (error instanceof AuthenticationError) {
          output.appendLine(`  auth failed tenant=${error.tenantId}`);
          vscode.window.showErrorMessage(`Mission APIMpossible: ${error.message}`);
          return;
        }

        const detail = error instanceof Error ? error.message : String(error);
        output.appendLine(`  failed: ${detail}`);
        vscode.window.showErrorMessage(
          `Mission APIMpossible: ${detail} (correlation ${context.correlationId})`,
        );
      }
    },
  );
}

export function activate(extensionContext: vscode.ExtensionContext): void {
  const output = vscode.window.createOutputChannel(OUTPUT_CHANNEL_NAME);
  extensionContext.subscriptions.push(output);

  extensionContext.subscriptions.push(
    vscode.commands.registerCommand('missionApimpossible.ask', async () => {
      const editor = vscode.window.activeTextEditor;
      if (!editor) {
        vscode.window.showWarningMessage('Mission APIMpossible: open a file and select some code.');
        return;
      }

      const selection = editor.document.getText(editor.selection);
      if (!selection.trim()) {
        vscode.window.showWarningMessage(
          'Mission APIMpossible: select the code to send. Nothing is sent implicitly.',
        );
        return;
      }

      const question = await vscode.window.showInputBox({
        prompt: 'What should the model do with the selection?',
        placeHolder: 'e.g. Review this for concurrency bugs',
        value: 'Review this code for bugs.',
      });

      if (question === undefined) {
        return;
      }

      const language = editor.document.languageId;
      const prompt = `${question}\n\n\`\`\`${language}\n${selection}\n\`\`\``;

      try {
        await runInvocation(output, prompt, DEFAULT_INSTRUCTIONS);
      } catch (error) {
        vscode.window.showErrorMessage(
          `Mission APIMpossible: ${error instanceof Error ? error.message : String(error)}`,
        );
      }
    }),
  );

  extensionContext.subscriptions.push(
    vscode.commands.registerCommand('missionApimpossible.prompt', async () => {
      const prompt = await vscode.window.showInputBox({
        prompt: 'Prompt to send',
        placeHolder: 'Ask the model something',
      });

      if (!prompt) {
        return;
      }

      try {
        await runInvocation(output, prompt, DEFAULT_INSTRUCTIONS);
      } catch (error) {
        vscode.window.showErrorMessage(
          `Mission APIMpossible: ${error instanceof Error ? error.message : String(error)}`,
        );
      }
    }),
  );

  extensionContext.subscriptions.push(
    vscode.commands.registerCommand('missionApimpossible.showSignInStatus', async () => {
      try {
        const config = readConfig();
        const account = await describeSession(config.scope, config.tenantId);

        if (account) {
          vscode.window.showInformationMessage(
            `Mission APIMpossible: signed in as ${account} (tenant ${config.tenantId}). ` +
              `Sign out through the VS Code Accounts menu - this extension stores no token.`,
          );
        } else {
          // Deliberately NOT "you are not signed in". This check is silent
          // (createIfNone: false), so it returns nothing whenever VS Code has
          // no CACHED session for this particular scope set - which is the
          // normal state before the first run, even for someone already
          // signed into VS Code. Saying "not signed in" sends people to the
          // Accounts menu to fix something that is not broken.
          vscode.window.showInformationMessage(
            `Mission APIMpossible: no cached session yet for tenant ${config.tenantId} ` +
              `and scope ${config.scope}. This is normal before the first run - ` +
              `run "Send a prompt" and VS Code will ask you to sign in.`,
          );
        }
      } catch (error) {
        vscode.window.showErrorMessage(
          `Mission APIMpossible: ${error instanceof Error ? error.message : String(error)}`,
        );
      }
    }),
  );
}

export function deactivate(): void {
  // Nothing to clean up: no token cache, no background timer, no temp file.
}
