/**
 * HTTP Cassette - Unified API
 *
 * Main entry point for the cassette system.
 * Provides a unified interface for both recording and playback modes.
 */

import type { PocketIc } from "@dfinity/pic";
import type {
  Cassette,
  CassetteMode,
  RecordOptions,
  PlaybackOptions,
} from "./cassette-types";
import { RECORD_MODE_ENV_VAR, CassetteNotFoundError } from "./cassette-types";
import {
  loadCassette,
  saveCassette,
  cassetteExists,
  createEmptyCassette,
  resolveCassettePath,
  getCassetteName,
} from "./cassette-storage";
import { replayHttpOutcalls, resetCassetteState } from "./cassette-playback";
import { recordHttpOutcalls } from "./cassette-recorder";

// =============================================================================
// Main HttpCassette Class
// =============================================================================

/**
 * Unified cassette handler for HTTP outcall mocking.
 *
 * Supports two modes:
 * - **Playback**: Load recorded cassette and mock responses
 * - **Record**: Make real HTTP requests and save to cassette
 *
 * @example Playback mode (default)
 * ```typescript
 * const cassette = await HttpCassette.load("conversations/chat");
 * await pic.tick(2);
 * await cassette.handleOutcalls(pic);
 * ```
 *
 * @example Record mode
 * ```typescript
 * const cassette = await HttpCassette.record("conversations/chat");
 * await pic.tick(2);
 * await cassette.handleOutcalls(pic);
 * await cassette.save();
 * ```
 *
 * @example Auto mode (recommended)
 * ```typescript
 * // Uses RECORD_CASSETTES env var to determine mode
 * const cassette = await HttpCassette.auto("conversations/chat");
 * await pic.tick(2);
 * await cassette.handleOutcalls(pic);
 * await cassette.save(); // Only writes in record mode
 * ```
 */
export class HttpCassette {
  private cassette: Cassette;
  private cassettePath: string;
  private dirty = false;

  private constructor(
    private readonly mode: CassetteMode,
    cassettePath: string,
    cassette: Cassette,
    private readonly recordOptions?: RecordOptions,
    private readonly playbackOptions?: PlaybackOptions,
  ) {
    this.cassettePath = cassettePath;
    this.cassette = cassette;
  }

  // ===========================================================================
  // Static Factory Methods
  // ===========================================================================

  /**
   * Load an existing cassette for playback.
   *
   * @param path - Cassette path (relative to tests/cassettes or absolute)
   * @param options - Playback options
   * @returns HttpCassette in playback mode
   * @throws CassetteNotFoundError if cassette doesn't exist
   */
  static async load(
    path: string,
    options?: PlaybackOptions,
  ): Promise<HttpCassette> {
    const fullPath = resolveCassettePath(path);
    const cassette = await loadCassette(fullPath);

    return new HttpCassette("playback", fullPath, cassette, undefined, options);
  }

  /**
   * Create a new cassette for recording.
   * Will overwrite existing cassette if it exists.
   *
   * @param path - Cassette path (relative to tests/cassettes or absolute)
   * @param options - Recording options
   * @returns HttpCassette in record mode
   */
  static async record(
    path: string,
    options?: RecordOptions,
  ): Promise<HttpCassette> {
    const fullPath = resolveCassettePath(path);
    const name = getCassetteName(fullPath);
    const cassette = createEmptyCassette(name);

    console.log(`🔴 Recording cassette: ${path}`);

    return new HttpCassette("record", fullPath, cassette, options);
  }

  /**
   * Automatically select mode based on environment and cassette existence.
   *
   * Mode selection:
   * 1. If `RECORD_CASSETTES=true` → record mode
   * 2. If cassette exists → playback mode
   * 3. If cassette missing → throw helpful error
   *
   * @param path - Cassette path (relative to tests/cassettes or absolute)
   * @param options - Options (can include both record and playback options)
   * @returns HttpCassette in appropriate mode
   */
  static async auto(
    path: string,
    options?: RecordOptions & PlaybackOptions,
  ): Promise<HttpCassette> {
    const shouldRecord = isRecordMode();

    if (shouldRecord) {
      return HttpCassette.record(path, options);
    }

    const fullPath = resolveCassettePath(path);
    const exists = await cassetteExists(fullPath);

    if (!exists) {
      throw new CassetteNotFoundError(fullPath);
    }

    return HttpCassette.load(path, options);
  }

  // ===========================================================================
  // Instance Methods
  // ===========================================================================

  /**
   * Handle all pending HTTP outcalls.
   *
   * In playback mode: Matches and mocks responses from cassette.
   * In record mode: Makes real requests, records, and mocks responses.
   *
   * @param pic - PocketIC instance
   * @returns Number of outcalls handled
   */
  async handleOutcalls(pic: PocketIc): Promise<number> {
    if (this.mode === "record") {
      const count = await recordHttpOutcalls(
        pic,
        this.cassette,
        this.recordOptions,
      );
      if (count > 0) {
        this.dirty = true;
      }
      return count;
    } else {
      return await replayHttpOutcalls(pic, this.cassette, this.playbackOptions);
    }
  }

  /**
   * Save the cassette to disk.
   *
   * In record mode: Saves all recorded interactions.
   * In playback mode: No-op (nothing to save).
   *
   * @param forceSave - If true, save even in playback mode (for cassette editing)
   */
  async save(forceSave = false): Promise<void> {
    if (this.mode === "playback" && !forceSave) {
      // Nothing to save in playback mode
      return;
    }

    if (!this.dirty && !forceSave) {
      // No changes to save
      return;
    }

    await saveCassette(this.cassettePath, this.cassette);
    this.dirty = false;

    console.log(
      `💾 Saved cassette: ${this.cassettePath} (${this.cassette.interactions.length} interactions)`,
    );
  }

  /**
   * Reset the cassette state for reuse.
   * Marks all interactions as unused.
   */
  reset(): void {
    resetCassetteState(this.cassette);
  }

  // ===========================================================================
  // Getters
  // ===========================================================================

  /**
   * Get the current mode (record or playback).
   */
  getMode(): CassetteMode {
    return this.mode;
  }

  /**
   * Check if in record mode.
   */
  isRecording(): boolean {
    return this.mode === "record";
  }

  /**
   * Check if in playback mode.
   */
  isPlaying(): boolean {
    return this.mode === "playback";
  }

  /**
   * Get the cassette path.
   */
  getPath(): string {
    return this.cassettePath;
  }

  /**
   * Get the cassette name.
   */
  getName(): string {
    return this.cassette.name;
  }

  /**
   * Get the number of interactions in the cassette.
   */
  getInteractionCount(): number {
    return this.cassette.interactions.length;
  }

  /**
   * Check if the cassette has unsaved changes.
   */
  isDirty(): boolean {
    return this.dirty;
  }

  /**
   * Get the underlying cassette (for advanced use cases).
   */
  getCassette(): Cassette {
    return this.cassette;
  }
}

// =============================================================================
// Helper Functions
// =============================================================================

/**
 * Check if record mode is enabled via environment variable.
 */
export function isRecordMode(): boolean {
  const value = process.env[RECORD_MODE_ENV_VAR];
  return value === "true" || value === "1";
}

/**
 * Set record mode programmatically (for testing the cassette system itself).
 */
export function setRecordMode(enabled: boolean): void {
  if (enabled) {
    process.env[RECORD_MODE_ENV_VAR] = "true";
  } else {
    delete process.env[RECORD_MODE_ENV_VAR];
  }
}

// =============================================================================
// Convenience Functions
// =============================================================================

/**
 * Create and handle a cassette in one call.
 * Useful for simple cases with a single round of HTTP outcalls.
 *
 * @param pic - PocketIC instance
 * @param cassettePath - Path to the cassette
 * @param options - Combined record/playback options
 * @returns The HttpCassette instance (call .save() when done)
 *
 * @example
 * ```typescript
 * const cassette = await useCassette(pic, "my-test");
 * // HTTP outcalls have been handled
 * await cassette.save(); // Save if recording
 * ```
 */
export async function useCassette(
  pic: PocketIc,
  cassettePath: string,
  options?: RecordOptions & PlaybackOptions,
): Promise<HttpCassette> {
  const cassette = await HttpCassette.auto(cassettePath, options);
  await cassette.handleOutcalls(pic);
  return cassette;
}

// =============================================================================
// Re-exports for convenience
// =============================================================================

export type {
  Cassette,
  CassetteMode,
  RecordOptions,
  PlaybackOptions,
  Interaction,
  MatchRules,
} from "./cassette-types";

export {
  CassetteMatchError,
  CassetteNotFoundError,
  CassetteParseError,
} from "./cassette-types";

export { resolveCassettePath, getCassettesDir } from "./cassette-storage";

export {
  formatPendingOutcall,
  formatCassetteSummary,
} from "./cassette-playback";

export { RecordingError } from "./cassette-recorder";
