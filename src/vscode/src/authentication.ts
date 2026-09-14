/**
 * Microsoft Entra authentication via VS Code's built-in provider.
 *
 * The extension registers no authentication provider of its own and stores no
 * token. It asks VS Code for a session and uses what it gets back. Tokens are
 * never written to settings, workspace state, secret storage, a file, the
 * clipboard, telemetry, or the output channel.
 *
 * Tenant pinning uses the `VSCODE_TENANT:<guid>` pseudo-scope understood by
 * the built-in Microsoft provider. That behavior is observed in the provider's
 * source rather than guaranteed by the public extension API, so the failure
 * path below is explicit: if a tenant-pinned request fails, the extension
 * reports the tenant it asked for and stops. It must never quietly fall back
 * to a different authority or to a non-human credential.
 */

import * as vscode from 'vscode';

const MICROSOFT_PROVIDER_ID = 'microsoft';

export class AuthenticationError extends Error {
  constructor(
    message: string,
    readonly tenantId: string,
  ) {
    super(message);
    this.name = 'AuthenticationError';
  }
}

/**
 * Builds the scope list for a tenant-pinned token request.
 *
 * `VSCODE_TENANT:` is stripped by the provider before the token request is
 * made; it selects the authority rather than requesting a permission.
 */
export function buildScopes(resourceScope: string, tenantId: string): string[] {
  return [resourceScope, `VSCODE_TENANT:${tenantId}`];
}

/**
 * Acquires an access token for the signed-in human.
 *
 * @param createIfNone When true, VS Code may prompt for interactive sign-in.
 *                     Pass false for a silent status check.
 */
export async function acquireToken(
  resourceScope: string,
  tenantId: string,
  createIfNone: boolean,
): Promise<vscode.AuthenticationSession | undefined> {
  const scopes = buildScopes(resourceScope, tenantId);

  try {
    // VS Code caches and refreshes the underlying token, so this is called
    // per invocation rather than held onto. There is deliberately no
    // extension-managed refresh loop and no token cache to leak.
    const session = await vscode.authentication.getSession(MICROSOFT_PROVIDER_ID, scopes, {
      createIfNone,
    });

    return session;
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);

    // Consent refusal and cancellation are normal user choices, not faults.
    if (/cancel/i.test(detail)) {
      return undefined;
    }

    throw new AuthenticationError(
      `Could not acquire a Microsoft Entra token for tenant ${tenantId}: ${detail}. ` +
        `Confirm you are signed in to that tenant and that the scope '${resourceScope}' is correct. ` +
        `This extension will not fall back to another tenant or credential.`,
      tenantId,
    );
  }
}

/**
 * Non-sensitive description of the current session, for the status command.
 *
 * Returns the account label VS Code already displays in its own UI. It does
 * not decode the token or surface claims.
 */
export async function describeSession(
  resourceScope: string,
  tenantId: string,
): Promise<string | undefined> {
  const session = await acquireToken(resourceScope, tenantId, false);
  return session?.account.label;
}
