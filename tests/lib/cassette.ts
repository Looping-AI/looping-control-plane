/**
 * HTTP Cassette System - Main Entry Point
 *
 * Re-exports all public APIs for convenient single-import usage.
 *
 * @example
 * ```typescript
 * import {
 *   HttpCassette,
 *   withCassette,
 *   withCassetteMulti,
 *   createCassetteContext,
 * } from "../lib/cassette";
 * ```
 */

// =============================================================================
// Main API
// =============================================================================

export {
  HttpCassette,
  isRecordMode,
  setRecordMode,
  useCassette,
} from "./http-cassette";

// =============================================================================
// Test Helpers
// =============================================================================

export {
  withCassette,
  withCassetteMulti,
  handleWithCassette,
  createCassetteContext,
  generateCassetteName,
  shouldSkipWithoutCassette,
  type CassetteOptions,
  type CassetteResult,
  type CassetteContext,
} from "./test-with-cassette";

// =============================================================================
// Types
// =============================================================================

export type {
  Cassette,
  Interaction,
  CassetteRequest,
  CassetteResponse,
  CassetteMode,
  MatchRules,
  RecordOptions,
  PlaybackOptions,
  PendingOutcall,
  HttpMethod,
  HttpHeader,
  MockResponse,
  MatchResult,
} from "./cassette-types";

// =============================================================================
// Errors
// =============================================================================

export {
  CassetteMatchError,
  CassetteNotFoundError,
  CassetteParseError,
} from "./cassette-types";

export { RecordingError } from "./cassette-recorder";

// =============================================================================
// Low-Level APIs (for advanced use cases)
// =============================================================================

export {
  loadCassette,
  saveCassette,
  cassetteExists,
  createEmptyCassette,
  resolveCassettePath,
  getCassettesDir,
  getCassetteName,
  listCassettes,
} from "./cassette-storage";

export {
  matchRequest,
  findInteractionByUrl,
  matchHeaders,
  base64Encode,
  base64DecodeToBytes,
} from "./cassette-matcher";

export {
  replayHttpOutcalls,
  resetCassetteState,
  getRemainingInteractionCount,
  getUsedInteractionCount,
  allInteractionsUsed,
  formatPendingOutcall,
  formatCassetteSummary,
} from "./cassette-playback";

export {
  recordHttpOutcalls,
  createRecordingSession,
  RecordingSession,
} from "./cassette-recorder";

// =============================================================================
// Constants
// =============================================================================

export {
  CASSETTE_VERSION,
  DEFAULT_REDACT_HEADERS,
  DEFAULT_STALE_WARNING_DAYS,
  RECORD_MODE_ENV_VAR,
} from "./cassette-types";
