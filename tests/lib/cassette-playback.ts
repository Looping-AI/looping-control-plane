/**
 * Cassette Playback
 *
 * Replays recorded HTTP interactions during test execution.
 * Matches pending PocketIC outcalls against cassette interactions
 * and mocks responses accordingly.
 */

import type { PocketIc } from "@dfinity/pic";
import type {
  Cassette,
  Interaction,
  PlaybackOptions,
  PendingOutcall,
  HttpHeader,
} from "./cassette-types";
import {
  CassetteMatchError,
  DEFAULT_STALE_WARNING_DAYS,
} from "./cassette-types";
import { matchRequest, base64DecodeToBytes } from "./cassette-matcher";

// =============================================================================
// Main Playback Function
// =============================================================================

/**
 * Replay all pending HTTP outcalls using cassette interactions.
 *
 * This function:
 * 1. Gets all pending HTTPS outcalls from PocketIC
 * 2. Matches each against the cassette's recorded interactions
 * 3. Mocks responses in PocketIC
 *
 * @param pic - PocketIC instance
 * @param cassette - Loaded cassette with recorded interactions
 * @param options - Playback options (match rules, strict mode, etc.)
 * @returns Number of outcalls replayed
 * @throws CassetteMatchError if no match found for an outcall
 */
export async function replayHttpOutcalls(
  pic: PocketIc,
  cassette: Cassette,
  options?: PlaybackOptions,
): Promise<number> {
  // Check for stale cassette
  checkStaleCassette(cassette, options?.staleWarningDays);

  // Get all pending outcalls
  const pendingOutcalls = await pic.getPendingHttpsOutcalls();

  if (pendingOutcalls.length === 0) {
    return 0;
  }

  // Process each pending outcall
  for (const pending of pendingOutcalls) {
    await replaySingleOutcall(
      pic,
      pending as PendingOutcall,
      cassette,
      options,
    );
  }

  // Check for unused interactions in strict mode
  if (options?.strictMode) {
    checkUnusedInteractions(cassette);
  }

  return pendingOutcalls.length;
}

/**
 * Replay a single HTTP outcall.
 */
async function replaySingleOutcall(
  pic: PocketIc,
  pending: PendingOutcall,
  cassette: Cassette,
  options?: PlaybackOptions,
): Promise<void> {
  // Find matching interaction
  const result = matchRequest(
    pending,
    cassette.interactions,
    options?.globalMatchRules,
  );

  if (!result.matched || !result.interaction) {
    throw new CassetteMatchError(pending, cassette.interactions);
  }

  // Mark interaction as used
  result.interaction._used = true;

  // Mock the response in PocketIC
  await mockOutcallResponse(pic, pending, result.interaction);
}

/**
 * Mock a single outcall response in PocketIC.
 */
async function mockOutcallResponse(
  pic: PocketIc,
  pending: PendingOutcall,
  interaction: Interaction,
): Promise<void> {
  const response = interaction.response;
  const bodyBytes = base64DecodeToBytes(response.body);

  await pic.mockPendingHttpsOutcall({
    requestId: pending.requestId,
    subnetId: pending.subnetId as Parameters<
      typeof pic.mockPendingHttpsOutcall
    >[0]["subnetId"],
    response: {
      type: "success",
      statusCode: response.statusCode,
      headers: response.headers as HttpHeader[],
      body: bodyBytes,
    },
  });
}

// =============================================================================
// Validation & Warnings
// =============================================================================

/**
 * Check if cassette is stale and emit warning.
 */
function checkStaleCassette(cassette: Cassette, warningDays?: number): void {
  const maxAgeDays = warningDays ?? DEFAULT_STALE_WARNING_DAYS;

  if (!cassette.recordedAt) {
    return;
  }

  const recordedDate = new Date(cassette.recordedAt);
  const now = new Date();
  const ageMs = now.getTime() - recordedDate.getTime();
  const ageDays = Math.floor(ageMs / (1000 * 60 * 60 * 24));

  if (ageDays > maxAgeDays) {
    console.warn(
      `⚠️  Cassette "${cassette.name}" is ${ageDays} days old (recorded: ${cassette.recordedAt}). ` +
        `Consider re-recording with RECORD_CASSETTES=true`,
    );
  }
}

/**
 * Check for unused interactions in strict mode.
 */
function checkUnusedInteractions(cassette: Cassette): void {
  const unused = cassette.interactions.filter((i) => !i._used);

  if (unused.length > 0) {
    const unusedList = unused
      .map((i) => `  - ${i.request.method} ${i.request.url}`)
      .join("\n");

    console.warn(
      `⚠️  Cassette "${cassette.name}" has ${unused.length} unused interactions:\n${unusedList}\n` +
        `This may indicate the cassette is out of sync with the test.`,
    );
  }
}

// =============================================================================
// Utility Functions
// =============================================================================

/**
 * Get the count of remaining (unused) interactions in a cassette.
 */
export function getRemainingInteractionCount(cassette: Cassette): number {
  return cassette.interactions.filter((i) => !i._used).length;
}

/**
 * Get the count of used interactions in a cassette.
 */
export function getUsedInteractionCount(cassette: Cassette): number {
  return cassette.interactions.filter((i) => i._used).length;
}

/**
 * Reset all interactions to unused state.
 * Useful for running multiple tests with the same cassette.
 */
export function resetCassetteState(cassette: Cassette): void {
  for (const interaction of cassette.interactions) {
    interaction._used = false;
  }
}

/**
 * Check if all interactions have been used.
 */
export function allInteractionsUsed(cassette: Cassette): boolean {
  return cassette.interactions.every((i) => i._used);
}

// =============================================================================
// Debug Helpers
// =============================================================================

/**
 * Format a pending outcall for debug output.
 */
export function formatPendingOutcall(pending: PendingOutcall): string {
  const bodyPreview =
    pending.body.length > 100
      ? `${new TextDecoder().decode(pending.body.slice(0, 100))}...`
      : new TextDecoder().decode(pending.body);

  return [
    `${pending.httpMethod} ${pending.url}`,
    `Headers: ${JSON.stringify(pending.headers)}`,
    `Body: ${bodyPreview}`,
  ].join("\n");
}

/**
 * Format cassette summary for debug output.
 */
export function formatCassetteSummary(cassette: Cassette): string {
  const total = cassette.interactions.length;
  const used = getUsedInteractionCount(cassette);
  const remaining = total - used;

  const interactions = cassette.interactions
    .map((i, idx) => {
      const status = i._used ? "✓" : "○";
      return `  ${status} [${idx}] ${i.request.method} ${i.request.url}`;
    })
    .join("\n");

  return [
    `Cassette: ${cassette.name}`,
    `Recorded: ${cassette.recordedAt}`,
    `Interactions: ${used}/${total} used, ${remaining} remaining`,
    ``,
    interactions,
  ].join("\n");
}
