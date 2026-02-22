/**
 * HTTP Cassette Types
 *
 * Core type definitions for the PocketIC HTTP cassette record/playback system.
 * Cassettes capture HTTP outcall request/response pairs for deterministic testing.
 */

// =============================================================================
// Cassette File Format
// =============================================================================

/**
 * Root structure of a cassette file.
 * Each cassette contains a list of HTTP interactions recorded from a test.
 */
export interface Cassette {
  /** Schema version for forward compatibility */
  version: 1;

  /** Human-readable name for this cassette */
  name: string;

  /** ISO 8601 timestamp when this cassette was recorded */
  recordedAt: string;

  /** List of HTTP request/response pairs in order of execution */
  interactions: Interaction[];
}

/**
 * A single HTTP request/response pair.
 */
export interface Interaction {
  /** The outgoing HTTP request captured from the canister */
  request: CassetteRequest;

  /** The HTTP response (either recorded from real API or mocked) */
  response: CassetteResponse;

  /** Optional rules for flexible matching during playback */
  matchRules?: MatchRules;

  /** Internal tracking - marks if this interaction was used during playback */
  _used?: boolean;
}

// =============================================================================
// Request Types
// =============================================================================

/**
 * HTTP methods supported by ICP HTTP outcalls.
 */
export type HttpMethod = "GET" | "POST" | "HEAD";

/**
 * HTTP header as a tuple [name, value].
 */
export type HttpHeader = [string, string];

/**
 * Body encoding type for cassette storage.
 * - "text": Plain UTF-8 text (human-readable, editable)
 * - "base64": Base64-encoded binary data
 */
export type BodyEncoding = "text" | "base64";

/**
 * Captured HTTP request from a canister outcall.
 */
export interface CassetteRequest {
  /** Full URL of the request */
  url: string;

  /** HTTP method */
  method: HttpMethod;

  /** Request headers */
  headers: HttpHeader[];

  /**
   * Request body.
   * Encoding depends on the `bodyEncoding` field.
   * Empty string if no body.
   */
  body: string;

  /**
   * How the body is encoded in this cassette.
   * - "text": Plain UTF-8 text (default for JSON/text content)
   * - "base64": Base64-encoded (for binary content)
   * Defaults to "base64" if not specified (backward compatibility).
   */
  bodyEncoding?: BodyEncoding;
}

// =============================================================================
// Response Types
// =============================================================================

/**
 * HTTP response to mock for a matched request.
 */
export interface CassetteResponse {
  /** HTTP status code (e.g., 200, 404, 500) */
  statusCode: number;

  /** Response headers */
  headers: HttpHeader[];

  /**
   * Response body.
   * Encoding depends on the `bodyEncoding` field.
   */
  body: string;

  /**
   * How the body is encoded in this cassette.
   * - "text": Plain UTF-8 text (default for JSON/text content)
   * - "base64": Base64-encoded (for binary content)
   * Defaults to "base64" if not specified (backward compatibility).
   */
  bodyEncoding?: BodyEncoding;
}

// =============================================================================
// Matching Configuration
// =============================================================================

/**
 * Rules for flexible request matching during playback.
 * Allows ignoring dynamic fields that change between test runs.
 */
export interface MatchRules {
  /**
   * Header names to ignore when matching (case-insensitive).
   * Useful for headers like "X-Request-Id" or "Date".
   */
  ignoreHeaders?: string[];

  /**
   * JSON paths to ignore in the request body.
   * Uses dot notation: "timestamp", "messages.0.id", "metadata.requestId"
   * Useful for dynamic fields like timestamps or UUIDs.
   */
  ignoreBodyFields?: string[];

  /**
   * If true, only match the URL path, ignoring query parameters.
   */
  ignoreQueryParams?: boolean;

  /**
   * Custom URL pattern (regex) for matching instead of exact URL.
   * Useful for URLs with dynamic segments like IDs.
   */
  urlPattern?: string;
}

// =============================================================================
// PocketIC Integration Types
// =============================================================================

/**
 * Pending HTTP outcall from PocketIC.
 * This mirrors the structure returned by `pic.getPendingHttpsOutcalls()`.
 */
export interface PendingOutcall {
  /** Subnet ID that the outcall originated from */
  subnetId: unknown; // Principal type from @dfinity/principal

  /** Unique request ID for mocking the response */
  requestId: number;

  /** HTTP method */
  httpMethod: HttpMethod;

  /** Target URL */
  url: string;

  /** Request headers */
  headers: HttpHeader[];

  /** Request body as Uint8Array */
  body: Uint8Array;

  /** Maximum response bytes (optional) */
  maxResponseBytes?: number;
}

/**
 * Response format for mocking PocketIC HTTP outcalls.
 */
export interface MockResponse {
  type: "success" | "reject";
  statusCode: number;
  headers: HttpHeader[];
  body: Uint8Array;
  message?: string; // Only for reject type
}

// =============================================================================
// Operation Modes
// =============================================================================

/**
 * Cassette operation mode.
 */
export type CassetteMode = "record" | "playback";

// =============================================================================
// Options & Configuration
// =============================================================================

/**
 * Options for recording cassettes.
 */
export interface RecordOptions {
  /**
   * Header names to redact in the saved cassette.
   * Values will be replaced with "[REDACTED]".
   * Default: ["authorization", "x-api-key"]
   */
  redactHeaders?: string[];

  /**
   * JSON paths in request body to redact.
   * Values will be replaced with "[REDACTED]".
   */
  redactBodyFields?: string[];

  /**
   * Transform response body before saving.
   * Useful for normalizing timestamps or removing sensitive data.
   */
  transformResponse?: (body: string, contentType: string) => string;

  /**
   * Transform request body before saving.
   * Useful for normalizing dynamic fields.
   */
  transformRequest?: (body: string, contentType: string) => string;
}

/**
 * Options for playback matching.
 */
export interface PlaybackOptions {
  /**
   * Global match rules applied to all interactions.
   * Individual interaction rules take precedence.
   */
  globalMatchRules?: MatchRules;

  /**
   * If true, throw an error if there are unused interactions after playback.
   * Helps detect stale cassettes.
   * Default: false
   */
  strictMode?: boolean;

  /**
   * Maximum age in days before warning about stale cassettes.
   * Default: 30
   */
  staleWarningDays?: number;
}

// =============================================================================
// Error Types
// =============================================================================

/**
 * Error thrown when no cassette interaction matches a pending outcall.
 */
export class CassetteMatchError extends Error {
  constructor(
    public readonly pendingOutcall: PendingOutcall,
    public readonly availableInteractions: Interaction[],
  ) {
    const availableUrls = availableInteractions
      .filter((i) => !i._used)
      .map((i) => `  - ${i.request.method} ${i.request.url}`)
      .join("\n");

    super(
      `No cassette match found for HTTP outcall:\n` +
        `  ${pendingOutcall.httpMethod} ${pendingOutcall.url}\n\n` +
        `Available unused interactions:\n${availableUrls || "  (none)"}\n\n` +
        `To update the cassette, run with RECORD_CASSETTES=true`,
    );
    this.name = "CassetteMatchError";
  }
}

/**
 * Error thrown when a cassette file is not found.
 */
export class CassetteNotFoundError extends Error {
  constructor(public readonly cassettePath: string) {
    super(
      `Cassette not found: ${cassettePath}\n\n` +
        `To record a new cassette, run with RECORD_CASSETTES=true`,
    );
    this.name = "CassetteNotFoundError";
  }
}

/**
 * Error thrown when cassette file format is invalid.
 */
export class CassetteParseError extends Error {
  constructor(
    public readonly cassettePath: string,
    public readonly parseError: Error,
  ) {
    super(
      `Failed to parse cassette: ${cassettePath}\n` +
        `Error: ${parseError.message}\n\n` +
        `The cassette file may be corrupted. Try re-recording with RECORD_CASSETTES=true`,
    );
    this.name = "CassetteParseError";
  }
}

// =============================================================================
// Utility Types
// =============================================================================

/**
 * Result of matching a pending outcall against cassette interactions.
 */
export interface MatchResult {
  /** Whether a match was found */
  matched: boolean;

  /** The matched interaction, if found */
  interaction?: Interaction;

  /** Index of the matched interaction in the cassette */
  index?: number;

  /** Reason for match failure, if not matched */
  reason?: string;
}

/**
 * Factory function type for creating cassettes.
 */
export type CassetteFactory = (name: string) => Promise<Cassette>;

// =============================================================================
// Constants
// =============================================================================

/** Current cassette schema version */
export const CASSETTE_VERSION = 1 as const;

/** Default headers to redact when recording */
export const DEFAULT_REDACT_HEADERS = [
  "authorization",
  "x-api-key",
  "api-key",
  "bearer",
  "cookie",
  "set-cookie",
  "token",
  "secret",
] as const;

/** Default stale warning threshold in days */
export const DEFAULT_STALE_WARNING_DAYS = 30;

/** Environment variable to enable record mode */
export const RECORD_MODE_ENV_VAR = "RECORD_CASSETTES";
