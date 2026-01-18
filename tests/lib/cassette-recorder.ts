/**
 * Cassette Recorder
 *
 * Records real HTTP interactions during test execution.
 * Makes actual HTTP requests, saves request/response pairs to cassette,
 * and mocks PocketIC with the real responses.
 */

import type { PocketIc } from "@dfinity/pic";
import type {
  Cassette,
  Interaction,
  CassetteRequest,
  CassetteResponse,
  RecordOptions,
  PendingOutcall,
  HttpMethod,
  HttpHeader,
  BodyEncoding,
} from "./cassette-types";
import { DEFAULT_REDACT_HEADERS } from "./cassette-types";
import { base64Encode } from "./cassette-matcher";
import { createEmptyCassette, saveCassette } from "./cassette-storage";

// =============================================================================
// Main Recording Function
// =============================================================================

/**
 * Record all pending HTTP outcalls by making real requests.
 *
 * This function:
 * 1. Gets all pending HTTPS outcalls from PocketIC
 * 2. Makes real HTTP requests to the target URLs
 * 3. Records request/response pairs to the cassette
 * 4. Mocks responses in PocketIC with the real responses
 *
 * @param pic - PocketIC instance
 * @param cassette - Cassette to record interactions into
 * @param options - Recording options (redaction, transforms, etc.)
 * @returns Number of outcalls recorded
 */
export async function recordHttpOutcalls(
  pic: PocketIc,
  cassette: Cassette,
  options?: RecordOptions,
): Promise<number> {
  // Get all pending outcalls
  const pendingOutcalls = await pic.getPendingHttpsOutcalls();

  if (pendingOutcalls.length === 0) {
    return 0;
  }

  // Process each pending outcall
  for (const pending of pendingOutcalls) {
    await recordSingleOutcall(
      pic,
      pending as PendingOutcall,
      cassette,
      options,
    );
  }

  return pendingOutcalls.length;
}

/**
 * Record a single HTTP outcall.
 */
async function recordSingleOutcall(
  pic: PocketIc,
  pending: PendingOutcall,
  cassette: Cassette,
  options?: RecordOptions,
): Promise<void> {
  // Make real HTTP request
  const realResponse = await makeRealRequest(pending);

  // Buffer the response body immediately - Response body can only be read once!
  const responseBodyBuffer = await realResponse.arrayBuffer();
  const responseBodyBytes = new Uint8Array(responseBodyBuffer);

  // Extract headers from response
  const responseHeaders: HttpHeader[] = [];
  realResponse.headers.forEach((value, name) => {
    responseHeaders.push([name, value]);
  });

  // Build interaction record (using buffered body)
  const interaction = await buildInteraction(
    pending,
    realResponse,
    responseBodyBytes,
    options,
  );

  // Add to cassette
  cassette.interactions.push(interaction);

  // Mock PocketIC with the real response (using buffered body)
  await mockWithBufferedResponse(
    pic,
    pending,
    realResponse.status,
    responseHeaders,
    responseBodyBytes,
  );
}

// =============================================================================
// Real HTTP Request
// =============================================================================

/**
 * Make a real HTTP request based on pending outcall.
 */
async function makeRealRequest(pending: PendingOutcall): Promise<Response> {
  const headers: Record<string, string> = {};
  for (const [name, value] of pending.headers) {
    headers[name] = value;
  }

  const requestInit: RequestInit = {
    method: pending.httpMethod,
    headers,
  };

  // Add body for POST requests
  if (pending.httpMethod === "POST" && pending.body.length > 0) {
    requestInit.body = pending.body;
  }

  try {
    const response = await fetch(pending.url, requestInit);
    return response;
  } catch (error) {
    throw new RecordingError(
      `Failed to make HTTP request to ${pending.url}: ${(error as Error).message}`,
      pending,
    );
  }
}

// =============================================================================
// Interaction Building
// =============================================================================

/**
 * Build a cassette interaction from pending outcall and real response.
 */
async function buildInteraction(
  pending: PendingOutcall,
  response: Response,
  responseBodyBytes: Uint8Array,
  options?: RecordOptions,
): Promise<Interaction> {
  // Build request record
  const request = buildRequestRecord(pending, options);

  // Build response record (using pre-buffered body)
  const cassetteResponse = buildResponseRecord(
    response,
    responseBodyBytes,
    options,
  );

  return {
    request,
    response: cassetteResponse,
  };
}

/**
 * Build cassette request from pending outcall.
 */
function buildRequestRecord(
  pending: PendingOutcall,
  options?: RecordOptions,
): CassetteRequest {
  // Redact sensitive headers
  const headers = redactHeaders(pending.headers, options?.redactHeaders);

  // Process body
  let bodyString = new TextDecoder().decode(pending.body);

  // Apply body redaction for JSON content
  if (bodyString && options?.redactBodyFields?.length) {
    bodyString = redactJsonFields(bodyString, options.redactBodyFields);
  }

  // Apply custom transform
  if (bodyString && options?.transformRequest) {
    const contentType =
      findHeader(pending.headers, "content-type") ?? "application/json";
    bodyString = options.transformRequest(bodyString, contentType);
  }

  // Determine encoding - use text for readable content, base64 for binary
  const contentType = findHeader(pending.headers, "content-type") ?? "";
  const { body, encoding } = encodeBodyForStorage(bodyString, contentType);

  return {
    url: pending.url,
    method: pending.httpMethod as HttpMethod,
    headers,
    body,
    bodyEncoding: encoding,
  };
}

/**
 * Build cassette response from real HTTP response.
 * Uses pre-buffered body bytes since Response body can only be read once.
 */
function buildResponseRecord(
  response: Response,
  responseBodyBytes: Uint8Array,
  options?: RecordOptions,
): CassetteResponse {
  // Decode body from pre-buffered bytes
  let bodyString = new TextDecoder().decode(responseBodyBytes);

  // Apply custom transform
  if (bodyString && options?.transformResponse) {
    const contentType =
      response.headers.get("content-type") ?? "application/json";
    bodyString = options.transformResponse(bodyString, contentType);
  }

  // Extract headers
  const headers: HttpHeader[] = [];
  response.headers.forEach((value, name) => {
    // Skip headers that might cause issues in playback
    const skipHeaders = ["content-encoding", "transfer-encoding", "connection"];
    if (!skipHeaders.includes(name.toLowerCase())) {
      headers.push([name, value]);
    }
  });

  // Determine encoding - use text for readable content, base64 for binary
  const contentType = response.headers.get("content-type") ?? "";
  const { body, encoding } = encodeBodyForStorage(bodyString, contentType);

  return {
    statusCode: response.status,
    headers,
    body,
    bodyEncoding: encoding,
  };
}

// =============================================================================
// Mock Response
// =============================================================================

/**
 * Mock PocketIC with pre-buffered response data.
 * This avoids issues with Response body being consumed.
 */
async function mockWithBufferedResponse(
  pic: PocketIc,
  pending: PendingOutcall,
  statusCode: number,
  headers: HttpHeader[],
  bodyBytes: Uint8Array,
): Promise<void> {
  await pic.mockPendingHttpsOutcall({
    requestId: pending.requestId,
    subnetId: pending.subnetId as Parameters<
      typeof pic.mockPendingHttpsOutcall
    >[0]["subnetId"],
    response: {
      type: "success",
      statusCode,
      headers,
      body: bodyBytes,
    },
  });
}

// =============================================================================
// Body Encoding Utilities
// =============================================================================

/**
 * Content types that should be stored as plain text (human-readable).
 */
const TEXT_CONTENT_TYPES = [
  "application/json",
  "text/plain",
  "text/html",
  "text/xml",
  "application/xml",
  "text/css",
  "text/javascript",
  "application/javascript",
];

/**
 * Determine how to encode a body for cassette storage.
 * Uses plain text for JSON/text content, base64 for binary.
 */
function encodeBodyForStorage(
  body: string,
  contentType: string,
): { body: string; encoding: BodyEncoding } {
  if (!body) {
    return { body: "", encoding: "text" };
  }

  // Check if content type indicates text content
  const isTextContent = TEXT_CONTENT_TYPES.some((type) =>
    contentType.toLowerCase().includes(type),
  );

  if (isTextContent) {
    // Store text content as plain text (compact, not pretty-printed)
    return { body, encoding: "text" };
  }

  // Binary content - use base64
  return {
    body: base64Encode(body),
    encoding: "base64",
  };
}

// =============================================================================
// Redaction Utilities
// =============================================================================

/**
 * Redact sensitive headers.
 */
function redactHeaders(
  headers: HttpHeader[],
  additionalRedact?: string[],
): HttpHeader[] {
  const redactSet = new Set([
    ...DEFAULT_REDACT_HEADERS,
    ...(additionalRedact ?? []).map((h) => h.toLowerCase()),
  ]);

  return headers.map(([name, value]) => {
    if (redactSet.has(name.toLowerCase())) {
      return [name, "[REDACTED]"];
    }
    return [name, value];
  });
}

/**
 * Redact fields in JSON body.
 */
function redactJsonFields(body: string, fields: string[]): string {
  if (!body || fields.length === 0) {
    return body;
  }

  try {
    const json = JSON.parse(body);
    for (const field of fields) {
      redactField(json, field.split("."));
    }
    return JSON.stringify(json);
  } catch {
    // Not valid JSON, return as-is
    return body;
  }
}

/**
 * Redact a nested field by path.
 */
function redactField(obj: Record<string, unknown>, path: string[]): void {
  if (path.length === 0 || !obj || typeof obj !== "object") {
    return;
  }

  const [first, ...rest] = path;

  if (rest.length === 0) {
    if (first in obj) {
      obj[first] = "[REDACTED]";
    }
  } else if (
    first in obj &&
    typeof obj[first] === "object" &&
    obj[first] !== null
  ) {
    redactField(obj[first] as Record<string, unknown>, rest);
  }
}

/**
 * Find a header value by name (case-insensitive).
 */
function findHeader(headers: HttpHeader[], name: string): string | undefined {
  const lowerName = name.toLowerCase();
  const found = headers.find(([n]) => n.toLowerCase() === lowerName);
  return found?.[1];
}

// =============================================================================
// High-Level Recording API
// =============================================================================

/**
 * Create a new recording session.
 *
 * @param name - Name for the cassette
 * @param options - Recording options
 * @returns A RecordingSession that tracks recorded interactions
 */
export function createRecordingSession(
  name: string,
  options?: RecordOptions,
): RecordingSession {
  return new RecordingSession(name, options);
}

/**
 * Recording session that manages cassette creation and saving.
 */
export class RecordingSession {
  private cassette: Cassette;
  private options?: RecordOptions;
  private saved = false;

  constructor(name: string, options?: RecordOptions) {
    this.cassette = createEmptyCassette(name);
    this.options = options;
  }

  /**
   * Record pending HTTP outcalls.
   */
  async record(pic: PocketIc): Promise<number> {
    if (this.saved) {
      throw new Error("Cannot record after saving cassette");
    }
    return await recordHttpOutcalls(pic, this.cassette, this.options);
  }

  /**
   * Save the cassette to disk.
   */
  async save(path: string): Promise<void> {
    await saveCassette(path, this.cassette);
    this.saved = true;
  }

  /**
   * Get the current cassette (for inspection).
   */
  getCassette(): Cassette {
    return this.cassette;
  }

  /**
   * Get count of recorded interactions.
   */
  getInteractionCount(): number {
    return this.cassette.interactions.length;
  }
}

// =============================================================================
// Error Types
// =============================================================================

/**
 * Error thrown when recording fails.
 */
export class RecordingError extends Error {
  constructor(
    message: string,
    public readonly pendingOutcall: PendingOutcall,
  ) {
    super(message);
    this.name = "RecordingError";
  }
}
