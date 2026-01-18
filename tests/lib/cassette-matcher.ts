/**
 * Cassette Matcher
 *
 * Logic for matching pending HTTP outcalls against recorded cassette interactions.
 * Supports exact matching, pattern matching, and configurable field ignoring.
 */

import type {
  Interaction,
  PendingOutcall,
  MatchRules,
  MatchResult,
  HttpHeader,
  BodyEncoding,
} from "./cassette-types";

// =============================================================================
// Main Matching Function
// =============================================================================

/**
 * Find a matching interaction for a pending HTTP outcall.
 *
 * Matching strategy (in order):
 * 1. URL match (exact or pattern)
 * 2. HTTP method match
 * 3. Body match (with optional field ignoring)
 *
 * @param pendingOutcall - The pending HTTP outcall from PocketIC
 * @param interactions - List of cassette interactions to match against
 * @param globalRules - Optional global match rules applied to all interactions
 * @returns MatchResult with matched interaction or failure reason
 */
export function matchRequest(
  pendingOutcall: PendingOutcall,
  interactions: Interaction[],
  globalRules?: MatchRules,
): MatchResult {
  const pendingBody = decodeBody(pendingOutcall.body);

  for (let i = 0; i < interactions.length; i++) {
    const interaction = interactions[i];

    // Skip already-used interactions
    if (interaction._used) {
      continue;
    }

    // Merge global rules with interaction-specific rules
    const rules = mergeMatchRules(globalRules, interaction.matchRules);

    // Check URL match
    if (!matchUrl(pendingOutcall.url, interaction.request.url, rules)) {
      continue;
    }

    // Check method match
    if (pendingOutcall.httpMethod !== interaction.request.method) {
      continue;
    }

    // Check body match
    const recordedBody = decodeStoredBody(
      interaction.request.body,
      interaction.request.bodyEncoding,
    );
    if (!matchBody(pendingBody, recordedBody, rules)) {
      continue;
    }

    // Match found!
    return {
      matched: true,
      interaction,
      index: i,
    };
  }

  // No match found - build helpful reason
  const reason = buildNoMatchReason(pendingOutcall, interactions);

  return {
    matched: false,
    reason,
  };
}

/**
 * Find the first unused interaction for a given URL (simple lookup).
 * Useful for quick checks without full matching logic.
 */
export function findInteractionByUrl(
  url: string,
  interactions: Interaction[],
): Interaction | undefined {
  return interactions.find((i) => !i._used && i.request.url === url);
}

// =============================================================================
// URL Matching
// =============================================================================

/**
 * Match a pending URL against a recorded URL.
 */
function matchUrl(
  pendingUrl: string,
  recordedUrl: string,
  rules?: MatchRules,
): boolean {
  // Check for regex pattern match first
  if (rules?.urlPattern) {
    try {
      const regex = new RegExp(rules.urlPattern);
      return regex.test(pendingUrl);
    } catch {
      // Invalid regex, fall back to exact match
      console.warn(`Invalid URL pattern regex: ${rules.urlPattern}`);
    }
  }

  // Optionally ignore query parameters
  if (rules?.ignoreQueryParams) {
    const pendingPath = stripQueryParams(pendingUrl);
    const recordedPath = stripQueryParams(recordedUrl);
    return pendingPath === recordedPath;
  }

  // Exact match
  return pendingUrl === recordedUrl;
}

/**
 * Strip query parameters from a URL.
 */
function stripQueryParams(url: string): string {
  const questionIndex = url.indexOf("?");
  return questionIndex === -1 ? url : url.substring(0, questionIndex);
}

// =============================================================================
// Body Matching
// =============================================================================

/**
 * Match pending request body against recorded body.
 * Handles JSON normalization to compare semantically equivalent JSON bodies
 * that may have different formatting (compact vs pretty-printed).
 */
function matchBody(
  pendingBody: string,
  recordedBody: string,
  rules?: MatchRules,
): boolean {
  // Empty bodies match
  if (pendingBody === "" && recordedBody === "") {
    return true;
  }

  // Try to parse both as JSON for semantic comparison
  try {
    const pendingJson = JSON.parse(pendingBody);
    const recordedJson = JSON.parse(recordedBody);

    // If fields to ignore, use field-ignoring comparison
    if (rules?.ignoreBodyFields && rules.ignoreBodyFields.length > 0) {
      return matchJsonWithIgnoredFields(
        pendingJson,
        recordedJson,
        rules.ignoreBodyFields,
      );
    }

    // Otherwise, compare normalized JSON (handles pretty-print vs compact)
    return JSON.stringify(pendingJson) === JSON.stringify(recordedJson);
  } catch {
    // Not valid JSON, fall back to exact string match
    return pendingBody === recordedBody;
  }
}

/**
 * Compare two JSON objects, ignoring specified fields.
 */
function matchJsonWithIgnoredFields(
  pending: unknown,
  recorded: unknown,
  ignoreFields: string[],
): boolean {
  // Create copies with ignored fields removed
  const pendingClean = removeFields(structuredClone(pending), ignoreFields);
  const recordedClean = removeFields(structuredClone(recorded), ignoreFields);

  // Deep equality check
  return JSON.stringify(pendingClean) === JSON.stringify(recordedClean);
}

/**
 * Remove fields from an object by JSON path.
 * Supports dot notation: "field", "nested.field", "array.0.field"
 */
function removeFields(obj: unknown, paths: string[]): unknown {
  if (obj === null || typeof obj !== "object") {
    return obj;
  }

  for (const path of paths) {
    deleteByPath(obj as Record<string, unknown>, path.split("."));
  }

  return obj;
}

/**
 * Delete a nested field by path segments.
 */
function deleteByPath(obj: Record<string, unknown>, segments: string[]): void {
  if (segments.length === 0) return;

  const [first, ...rest] = segments;

  // Handle array wildcard: "messages.*.id" matches all array elements
  if (first === "*" && Array.isArray(obj)) {
    for (const item of obj) {
      if (item && typeof item === "object") {
        deleteByPath(item as Record<string, unknown>, rest);
      }
    }
    return;
  }

  // Handle array index
  if (Array.isArray(obj)) {
    const index = parseInt(first, 10);
    if (!isNaN(index) && index < obj.length) {
      if (rest.length === 0) {
        obj.splice(index, 1);
      } else if (obj[index] && typeof obj[index] === "object") {
        deleteByPath(obj[index] as Record<string, unknown>, rest);
      }
    }
    return;
  }

  // Handle object field
  if (first in obj) {
    if (rest.length === 0) {
      delete obj[first];
    } else if (obj[first] && typeof obj[first] === "object") {
      deleteByPath(obj[first] as Record<string, unknown>, rest);
    }
  }
}

// =============================================================================
// Header Matching (for future use)
// =============================================================================

/**
 * Match headers, optionally ignoring specified header names.
 * Currently not used in main matching (URL + method + body is sufficient),
 * but available for stricter matching if needed.
 */
export function matchHeaders(
  pendingHeaders: HttpHeader[],
  recordedHeaders: HttpHeader[],
  ignoreHeaders?: string[],
): boolean {
  const normalize = (headers: HttpHeader[]): Map<string, string> => {
    const map = new Map<string, string>();
    for (const [name, value] of headers) {
      const lowerName = name.toLowerCase();
      if (!ignoreHeaders?.includes(lowerName)) {
        map.set(lowerName, value);
      }
    }
    return map;
  };

  const pendingMap = normalize(pendingHeaders);
  const recordedMap = normalize(recordedHeaders);

  if (pendingMap.size !== recordedMap.size) {
    return false;
  }

  for (const [name, value] of pendingMap) {
    if (recordedMap.get(name) !== value) {
      return false;
    }
  }

  return true;
}

// =============================================================================
// Rule Merging
// =============================================================================

/**
 * Merge global rules with interaction-specific rules.
 * Interaction rules take precedence.
 */
function mergeMatchRules(
  global?: MatchRules,
  interaction?: MatchRules,
): MatchRules | undefined {
  if (!global && !interaction) {
    return undefined;
  }

  if (!global) {
    return interaction;
  }

  if (!interaction) {
    return global;
  }

  return {
    ignoreHeaders: mergeArrays(global.ignoreHeaders, interaction.ignoreHeaders),
    ignoreBodyFields: mergeArrays(
      global.ignoreBodyFields,
      interaction.ignoreBodyFields,
    ),
    ignoreQueryParams:
      interaction.ignoreQueryParams ?? global.ignoreQueryParams,
    urlPattern: interaction.urlPattern ?? global.urlPattern,
  };
}

/**
 * Merge two optional arrays, removing duplicates.
 */
function mergeArrays(a?: string[], b?: string[]): string[] | undefined {
  if (!a && !b) return undefined;
  if (!a) return b;
  if (!b) return a;
  return [...new Set([...a, ...b])];
}

// =============================================================================
// Error Helpers
// =============================================================================

/**
 * Build a helpful error message when no match is found.
 */
function buildNoMatchReason(
  pendingOutcall: PendingOutcall,
  interactions: Interaction[],
): string {
  const unused = interactions.filter((i) => !i._used);

  if (unused.length === 0) {
    return (
      `All ${interactions.length} cassette interactions have been used. ` +
      `The test made more HTTP calls than recorded.`
    );
  }

  // Check for partial matches to give better hints
  const urlMatches = unused.filter((i) => i.request.url === pendingOutcall.url);
  const methodMatches = urlMatches.filter(
    (i) => i.request.method === pendingOutcall.httpMethod,
  );

  if (urlMatches.length === 0) {
    return `No interactions found for URL: ${pendingOutcall.url}`;
  }

  if (methodMatches.length === 0) {
    return (
      `URL matched but method differs. ` +
      `Expected ${urlMatches[0].request.method}, got ${pendingOutcall.httpMethod}`
    );
  }

  // URL and method match, must be body mismatch
  return (
    `URL and method matched, but request body differs. ` +
    `Consider adding ignoreBodyFields to match rules.`
  );
}

// =============================================================================
// Encoding Utilities
// =============================================================================

/**
 * Decode Uint8Array body to string.
 */
function decodeBody(body: Uint8Array): string {
  if (body.length === 0) {
    return "";
  }
  return new TextDecoder().decode(body);
}

/**
 * Decode stored body based on encoding type.
 * Handles backward compatibility - defaults to base64 if encoding not specified.
 */
function decodeStoredBody(
  body: string,
  encoding: BodyEncoding | undefined,
): string {
  if (!body) {
    return "";
  }

  // "text" encoding means body is stored as plain UTF-8 string
  if (encoding === "text") {
    return body;
  }

  // Default to base64 for backward compatibility
  return base64Decode(body);
}

/**
 * Decode base64 string to UTF-8 string.
 */
function base64Decode(base64: string): string {
  if (!base64) {
    return "";
  }
  try {
    const binary = atob(base64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) {
      bytes[i] = binary.charCodeAt(i);
    }
    return new TextDecoder().decode(bytes);
  } catch {
    // If decoding fails, return as-is (might already be decoded)
    return base64;
  }
}

/**
 * Encode string to base64.
 */
export function base64Encode(data: string | Uint8Array): string {
  const bytes =
    typeof data === "string" ? new TextEncoder().encode(data) : data;
  let binary = "";
  for (let i = 0; i < bytes.length; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  return btoa(binary);
}

/**
 * Decode stored body to Uint8Array based on encoding type.
 * Handles backward compatibility - defaults to base64 if encoding not specified.
 */
export function decodeBodyToBytes(
  body: string,
  encoding: BodyEncoding | undefined,
): Uint8Array {
  if (!body) {
    return new Uint8Array(0);
  }

  // "text" encoding means body is stored as plain UTF-8 string
  if (encoding === "text") {
    return new TextEncoder().encode(body);
  }

  // Default to base64 for backward compatibility
  return base64DecodeFromString(body);
}

/**
 * Decode base64 to Uint8Array.
 * @deprecated Use decodeBodyToBytes which handles encoding types
 */
export function base64DecodeToBytes(base64: string): Uint8Array {
  return base64DecodeFromString(base64);
}

/**
 * Internal: Decode base64 string to Uint8Array.
 */
function base64DecodeFromString(base64: string): Uint8Array {
  if (!base64) {
    return new Uint8Array(0);
  }
  try {
    const binary = atob(base64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) {
      bytes[i] = binary.charCodeAt(i);
    }
    return bytes;
  } catch {
    return new Uint8Array(0);
  }
}
