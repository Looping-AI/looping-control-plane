/**
 * Test Helpers for HTTP Cassettes
 *
 * High-level utilities for using cassettes in integration tests.
 * Provides ergonomic wrappers around the cassette system for common patterns.
 */

import type { PocketIc } from "@dfinity/pic";
import {
  HttpCassette,
  type RecordOptions,
  type PlaybackOptions,
} from "./http-cassette";

// =============================================================================
// Types
// =============================================================================

/**
 * Combined options for cassette operations.
 */
export interface CassetteOptions extends RecordOptions, PlaybackOptions {
  /**
   * Number of ticks to advance before checking for pending outcalls.
   * Default: 2
   */
  ticks?: number;

  /**
   * Maximum number of rounds to handle outcalls.
   * Useful for tests with multiple sequential HTTP calls.
   * Default: 1
   */
  maxRounds?: number;
}

/**
 * Result of a cassette-wrapped operation.
 */
export interface CassetteResult<T> {
  /** The result of the deferred call */
  result: T;
  /** The cassette used (for inspection or saving) */
  cassette: HttpCassette;
  /** Number of HTTP outcalls handled */
  outcallCount: number;
}

// =============================================================================
// Main Helper Functions
// =============================================================================

/**
 * Execute a deferred actor call with cassette support.
 *
 * This is the main helper for testing canister methods that make HTTP outcalls.
 * It handles the full flow:
 * 1. Execute the deferred call (queues the message)
 * 2. Tick to process the message and queue HTTP outcalls
 * 3. Handle outcalls via cassette (record or playback)
 * 4. Await the result
 * 5. Save cassette if in record mode
 *
 * @param pic - PocketIC instance
 * @param cassetteName - Name/path of the cassette
 * @param deferredCall - Function that returns a deferred actor call
 * @param options - Cassette and execution options
 * @returns The result of the call along with cassette metadata
 *
 * @example
 * ```typescript
 * const { result } = await withCassette(
 *   pic,
 *   "conversations/chat-simple",
 *   () => deferredActor.talkTo(0n, agentId, "Hello!"),
 * );
 * expect(result.ok).toBeDefined();
 * ```
 */
export async function withCassette<T>(
  pic: PocketIc,
  cassetteName: string,
  deferredCall: () => Promise<() => Promise<T>>,
  options?: CassetteOptions,
): Promise<CassetteResult<T>> {
  const ticks = options?.ticks ?? 2;
  const maxRounds = options?.maxRounds ?? 1;

  // Load or create cassette
  const cassette = await HttpCassette.auto(cassetteName, options);

  // Execute the deferred call (this queues the message)
  const executeCall = await deferredCall();

  // Handle multiple rounds of outcalls
  let totalOutcalls = 0;
  for (let round = 0; round < maxRounds; round++) {
    // Tick to process message and queue HTTP outcalls
    await pic.tick(ticks);

    // Handle any pending outcalls
    const count = await cassette.handleOutcalls(pic);
    totalOutcalls += count;

    // If no outcalls in this round, we're done
    if (count === 0 && round > 0) {
      break;
    }
  }

  // Await the result
  const result = await executeCall();

  // Save cassette if recording
  await cassette.save();

  return {
    result,
    cassette,
    outcallCount: totalOutcalls,
  };
}

/**
 * Execute multiple deferred calls with a single cassette.
 *
 * Useful for tests that make multiple HTTP-calling methods in sequence.
 *
 * @param pic - PocketIC instance
 * @param cassetteName - Name/path of the cassette
 * @param calls - Array of deferred call functions
 * @param options - Cassette and execution options
 * @returns Array of results and the cassette
 *
 * @example
 * ```typescript
 * const { results, cassette } = await withCassetteMulti(
 *   pic,
 *   "conversations/multi-turn",
 *   [
 *     () => deferredActor.talkTo(0n, agentId, "Hello!"),
 *     () => deferredActor.talkTo(0n, agentId, "How are you?"),
 *     () => deferredActor.talkTo(0n, agentId, "Goodbye!"),
 *   ],
 * );
 * ```
 */
export async function withCassetteMulti<T>(
  pic: PocketIc,
  cassetteName: string,
  calls: Array<() => Promise<() => Promise<T>>>,
  options?: CassetteOptions,
): Promise<{ results: T[]; cassette: HttpCassette; outcallCount: number }> {
  const ticks = options?.ticks ?? 2;

  // Load or create cassette
  const cassette = await HttpCassette.auto(cassetteName, options);

  const results: T[] = [];
  let totalOutcalls = 0;

  for (const deferredCall of calls) {
    // Execute the deferred call
    const executeCall = await deferredCall();

    // Tick and handle outcalls
    await pic.tick(ticks);
    const count = await cassette.handleOutcalls(pic);
    totalOutcalls += count;

    // Await the result
    const result = await executeCall();
    results.push(result);
  }

  // Save cassette if recording
  await cassette.save();

  return {
    results,
    cassette,
    outcallCount: totalOutcalls,
  };
}

/**
 * Handle HTTP outcalls for an already-executed deferred call.
 *
 * Use this when you need more control over the execution flow.
 *
 * @param pic - PocketIC instance
 * @param cassetteName - Name/path of the cassette
 * @param options - Cassette options
 * @returns The cassette (call .save() when done)
 *
 * @example
 * ```typescript
 * // Execute deferred call manually
 * const executeCall = await deferredActor.talkTo(0n, agentId, "Hello!");
 * await pic.tick(2);
 *
 * // Handle outcalls
 * const cassette = await handleWithCassette(pic, "my-test");
 *
 * // Get result
 * const result = await executeCall();
 *
 * // Save if recording
 * await cassette.save();
 * ```
 */
export async function handleWithCassette(
  pic: PocketIc,
  cassetteName: string,
  options?: CassetteOptions,
): Promise<HttpCassette> {
  const cassette = await HttpCassette.auto(cassetteName, options);
  await cassette.handleOutcalls(pic);
  return cassette;
}

// =============================================================================
// Test Lifecycle Helpers
// =============================================================================

/**
 * Create a cassette context for use within a test suite.
 *
 * This returns functions that share a single cassette instance across
 * multiple operations within a test.
 *
 * @param pic - PocketIC instance
 * @param cassetteName - Name/path of the cassette
 * @param options - Cassette options
 * @returns Object with handle and save functions
 *
 * @example
 * ```typescript
 * let cassetteCtx: CassetteContext;
 *
 * beforeEach(async () => {
 *   cassetteCtx = await createCassetteContext(pic, "my-suite/my-test");
 * });
 *
 * afterEach(async () => {
 *   await cassetteCtx.save();
 * });
 *
 * it("test", async () => {
 *   await doSomething();
 *   await pic.tick(2);
 *   await cassetteCtx.handle();
 * });
 * ```
 */
export async function createCassetteContext(
  pic: PocketIc,
  cassetteName: string,
  options?: CassetteOptions,
): Promise<CassetteContext> {
  const cassette = await HttpCassette.auto(cassetteName, options);
  const ticks = options?.ticks ?? 2;

  return {
    cassette,

    async handle(): Promise<number> {
      return await cassette.handleOutcalls(pic);
    },

    async tickAndHandle(): Promise<number> {
      await pic.tick(ticks);
      return await cassette.handleOutcalls(pic);
    },

    async save(): Promise<void> {
      await cassette.save();
    },

    reset(): void {
      cassette.reset();
    },
  };
}

/**
 * Cassette context for use within a test.
 */
export interface CassetteContext {
  /** The underlying HttpCassette instance */
  cassette: HttpCassette;

  /** Handle pending HTTP outcalls */
  handle(): Promise<number>;

  /** Tick and then handle pending HTTP outcalls */
  tickAndHandle(): Promise<number>;

  /** Save the cassette (if recording) */
  save(): Promise<void>;

  /** Reset cassette state for reuse */
  reset(): void;
}

// =============================================================================
// Utility Functions
// =============================================================================

/**
 * Generate a cassette name from the test file and test name.
 *
 * @param testFile - The test file path (use import.meta.file)
 * @param testName - The test name
 * @returns A sanitized cassette name
 *
 * @example
 * ```typescript
 * const cassetteName = generateCassetteName(import.meta.file, "should chat with agent");
 * // Returns: "conversations/should-chat-with-agent"
 * ```
 */
export function generateCassetteName(
  testFile: string,
  testName: string,
): string {
  // Extract the test file name without extension
  const fileName =
    testFile
      .split("/")
      .pop()
      ?.replace(/\.(spec|test)\.(ts|js)$/, "") ?? "test";

  // Sanitize the test name
  const sanitizedTestName = testName
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "");

  return `${fileName}/${sanitizedTestName}`;
}

/**
 * Skip a test if cassette is missing and not in record mode.
 *
 * Useful for optionally running tests that require recorded cassettes.
 *
 * @param cassetteName - Name/path of the cassette
 * @returns true if test should be skipped
 */
export async function shouldSkipWithoutCassette(
  cassetteName: string,
): Promise<boolean> {
  const { isRecordMode, resolveCassettePath } = await import("./http-cassette");
  const { cassetteExists } = await import("./cassette-storage");

  if (isRecordMode()) {
    return false; // Will record, don't skip
  }

  const fullPath = resolveCassettePath(cassetteName);
  const exists = await cassetteExists(fullPath);

  if (!exists) {
    console.log(
      `⏭️  Skipping test: cassette "${cassetteName}" not found. ` +
        `Run with RECORD_CASSETTES=true to record.`,
    );
    return true;
  }

  return false;
}
