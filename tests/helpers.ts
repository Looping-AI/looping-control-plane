import {
  cassetteExists,
  loadCassette,
  resolveCassettePath,
} from "./lib/cassette-storage";

// =============================================================================
// Slack channel resolution
// =============================================================================

/**
 * Resolves the Slack channel ID to use in a test:
 *
 * - **Playback mode** (cassette already exists): extracts the channel from the
 *   recorded `chat.postMessage` request body so the canister call uses exactly
 *   the same channel that was captured, keeping the cassette matcher happy.
 *
 * - **Recording mode** (no cassette yet): reads `SLACK_SPECS_CHANNEL_ID` from
 *   the environment (`.env.test`). Throws if the variable is absent, so a
 *   missing configuration is surfaced immediately instead of silently producing
 *   a broken cassette.
 *
 * Pass the same cassette name you hand to `withCassette`.
 */
export async function resolveSpecsChannel(
  cassetteName: string,
): Promise<string> {
  const fullPath = resolveCassettePath(cassetteName);

  if (await cassetteExists(fullPath)) {
    const cassette = await loadCassette(fullPath);
    for (const interaction of cassette.interactions) {
      if (interaction.request.url.includes("slack.com/api/chat.postMessage")) {
        try {
          const body = JSON.parse(interaction.request.body) as {
            channel?: string;
          };
          if (body.channel) return body.channel;
        } catch {
          // body is not JSON — skip
        }
      }
    }
  }

  // Recording mode: env var must be configured
  const envChannel = process.env["SLACK_SPECS_CHANNEL_ID"];
  if (!envChannel) {
    throw new Error(
      "SLACK_SPECS_CHANNEL_ID is not set in .env.test. " +
        "This is required when recording cassettes for the first time.",
    );
  }
  return envChannel;
}

/**
 * Resolves the Slack org-admin channel ID to use in a test:
 *
 * - **Playback mode** (cassette already exists): extracts the channel from the
 *   recorded `conversations.info` request URL (`?channel=...`) so the canister
 *   call uses exactly the same channel that was captured, keeping the cassette
 *   matcher happy.
 *
 * - **Recording mode** (no cassette yet): reads `SLACK_ORG_ADMIN_CHANNEL_ID`
 *   from the environment (`.env.test`). Throws if the variable is absent.
 *
 * Pass the same cassette name you hand to `withCassette`.
 */
export async function resolveOrgAdminChannel(
  cassetteName: string,
): Promise<string> {
  const fullPath = resolveCassettePath(cassetteName);

  if (await cassetteExists(fullPath)) {
    const cassette = await loadCassette(fullPath);
    for (const interaction of cassette.interactions) {
      if (
        interaction.request.url.includes("slack.com/api/conversations.info")
      ) {
        const url = new URL(interaction.request.url);
        const channel = url.searchParams.get("channel");
        if (channel) return channel;
      }
    }
  }

  // Recording mode: env var must be configured
  const envChannel = process.env["SLACK_ORG_ADMIN_CHANNEL_ID"];
  if (!envChannel) {
    throw new Error(
      "SLACK_ORG_ADMIN_CHANNEL_ID is not set in .env.test. " +
        "This is required when recording cassettes for the first time.",
    );
  }
  return envChannel;
}

/**
 * Resolves the Slack specs channel ID from a `conversations.info` cassette.
 *
 * Use this for tests that verify a real channel that is NOT the org-admin channel
 * (e.g. workspace 1 admin channel, wrong-name tests for workspace 0).
 *
 * - **Playback mode** (cassette already exists): extracts the channel from the
 *   recorded `conversations.info` request URL so the canister call uses exactly
 *   the same channel that was captured, keeping the cassette matcher happy.
 *
 * - **Recording mode** (no cassette yet): reads `SLACK_SPECS_CHANNEL_ID` from
 *   the environment (`.env.test`). Throws if the variable is absent.
 *
 * Pass the same cassette name you hand to `withCassette`.
 */
export async function resolveSpecsChannelForInfo(
  cassetteName: string,
): Promise<string> {
  const fullPath = resolveCassettePath(cassetteName);

  if (await cassetteExists(fullPath)) {
    const cassette = await loadCassette(fullPath);
    // Collect all conversations.info channels and return the last one.
    // When multiple calls appear (e.g. set-admin then set-member in one cassette)
    // the specs channel is always the final conversations.info interaction.
    let lastChannel: string | undefined;
    for (const interaction of cassette.interactions) {
      if (
        interaction.request.url.includes("slack.com/api/conversations.info")
      ) {
        const url = new URL(interaction.request.url);
        const channel = url.searchParams.get("channel");
        if (channel) lastChannel = channel;
      }
    }
    if (lastChannel) return lastChannel;
  }

  // Recording mode: env var must be configured
  const envChannel = process.env["SLACK_SPECS_CHANNEL_ID"];
  if (!envChannel) {
    throw new Error(
      "SLACK_SPECS_CHANNEL_ID is not set in .env.test. " +
        "This is required when recording cassettes for the first time.",
    );
  }
  return envChannel;
}

// =============================================================================
// Result / Optional unwrap helpers
// =============================================================================

/**
 * Unwraps a Result<T, E> assuming it's an Ok variant
 * @param result - The result to unwrap
 * @returns The ok value
 * @throws Error if result is an Err variant
 */
export function expectOk<T>(result: { ok: T } | { err: string }): T {
  if ("err" in result) {
    throw new Error(`Expected Ok but got Err: ${result.err}`);
  }
  return result.ok;
}

/**
 * Unwraps a Result<T, E> assuming it's an Err variant
 * @param result - The result to unwrap
 * @returns The error value
 * @throws Error if result is an Ok variant
 */
export function expectErr(result: { ok: unknown } | { err: string }): string {
  if ("ok" in result) {
    throw new Error(`Expected Err but got Ok: ${JSON.stringify(result.ok)}`);
  }
  return result.err;
}

/**
 * Unwraps an optional array [T] assuming it contains a value
 * Motoko optionals are represented as arrays with 0 or 1 elements
 * @param optional - The optional array to unwrap
 * @returns The unwrapped value
 * @throws Error if optional is empty
 */
export function expectSome<T>(optional: T[]): T {
  if (optional.length === 0) {
    throw new Error("Expected Some but got None (empty array)");
  }
  return optional[0];
}

/**
 * Asserts that an optional array [] is empty (None in Motoko)
 * @param optional - The optional array to check
 * @throws Error if optional contains a value
 */
export function expectNone<T>(optional: T[]): void {
  if (optional.length > 0) {
    throw new Error(
      `Expected None but got Some: ${JSON.stringify(optional[0])}`,
    );
  }
}
