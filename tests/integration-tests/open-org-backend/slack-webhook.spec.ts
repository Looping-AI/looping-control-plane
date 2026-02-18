import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import { createHmac } from "node:crypto";
import type { _SERVICE } from "../../setup.ts";
import { createTestEnvironment } from "../../setup.ts";
import { expectOk } from "../../helpers.ts";

// ============================================
// Test Helpers
// ============================================

const encoder = new TextEncoder();
const decoder = new TextDecoder();

const TEST_SIGNING_SECRET = "test-slack-signing-secret-12345";
const TEST_TIMESTAMP = "1700000000";

/**
 * Compute a valid Slack signature for a given body using HMAC-SHA256.
 * Format: v0=HMAC-SHA256(secret, "v0:{timestamp}:{body}")
 */
function computeSlackSignature(
  secret: string,
  timestamp: string,
  body: string,
): string {
  const baseString = `v0:${timestamp}:${body}`;
  const hmac = createHmac("sha256", secret);
  hmac.update(baseString);
  return `v0=${hmac.digest("hex")}`;
}

/**
 * Send a signed Slack webhook request to the canister.
 */
async function sendSignedWebhook(
  actor: Actor<_SERVICE>,
  body: string,
  timestamp: string = TEST_TIMESTAMP,
  signature?: string,
) {
  const sig =
    signature ?? computeSlackSignature(TEST_SIGNING_SECRET, timestamp, body);
  return actor.http_request_update({
    method: "POST",
    url: "/webhook/slack/",
    headers: [
      ["content-type", "application/json"],
      ["x-slack-signature", sig],
      ["x-slack-request-timestamp", timestamp],
    ],
    body: encoder.encode(body),
  });
}

/**
 * Decode HTTP response body to text.
 */
function decodeBody(response: { body: Uint8Array | number[] }): string {
  return decoder.decode(new Uint8Array(response.body));
}

// ============================================
// Tests
// ============================================

describe("Slack Webhook", () => {
  let pic: PocketIc;
  let actor: Actor<_SERVICE>;

  beforeEach(async () => {
    const testEnv = await createTestEnvironment();
    pic = testEnv.pic;
    actor = testEnv.actor;

    // Store signing secret (owner identity is set by createTestEnvironment)
    const storeResult = await actor.storeSecret(
      0n,
      { slackSigningSecret: null },
      TEST_SIGNING_SECRET,
    );
    expectOk(storeResult);
  });

  afterEach(async () => {
    await pic.tearDown();
  });

  // ============================================
  // URL Verification (Challenge Handshake)
  // ============================================

  describe("url_verification", () => {
    it("should return the challenge value", async () => {
      const body = JSON.stringify({
        type: "url_verification",
        challenge: "my-test-challenge-xyz",
        token: "some-token",
      });

      const response = await actor.http_request_update({
        method: "POST",
        url: "/webhook/slack/",
        headers: [["content-type", "application/json"]],
        body: encoder.encode(body),
      });

      expect(response.status_code).toBe(200);
      expect(decodeBody(response)).toBe("my-test-challenge-xyz");
    });

    it("should not require signature for url_verification", async () => {
      // No signature headers — should still work for url_verification
      const body = JSON.stringify({
        type: "url_verification",
        challenge: "no-sig-challenge",
      });

      const response = await actor.http_request_update({
        method: "POST",
        url: "/webhook/slack/",
        headers: [],
        body: encoder.encode(body),
      });

      expect(response.status_code).toBe(200);
      expect(decodeBody(response)).toBe("no-sig-challenge");
    });
  });

  // ============================================
  // Signature Verification
  // ============================================

  describe("signature verification", () => {
    it("should reject requests with missing signature", async () => {
      const body = JSON.stringify({
        type: "event_callback",
        token: "tok",
        team_id: "T123",
        api_app_id: "A123",
        event: {
          type: "message",
          user: "U1",
          text: "hi",
          ts: "1.1",
          channel: "C1",
        },
        event_id: "Ev001",
        event_time: 1700000000,
      });

      const response = await actor.http_request_update({
        method: "POST",
        url: "/webhook/slack/",
        headers: [["content-type", "application/json"]],
        body: encoder.encode(body),
      });

      expect(response.status_code).toBe(401);
      expect(decodeBody(response)).toBe("Missing signature");
    });

    it("should reject requests with missing timestamp", async () => {
      const body = JSON.stringify({
        type: "event_callback",
        token: "tok",
        team_id: "T123",
        api_app_id: "A123",
        event: {
          type: "message",
          user: "U1",
          text: "hi",
          ts: "1.1",
          channel: "C1",
        },
        event_id: "Ev002",
        event_time: 1700000000,
      });

      const response = await actor.http_request_update({
        method: "POST",
        url: "/webhook/slack/",
        headers: [
          ["content-type", "application/json"],
          ["x-slack-signature", "v0=invalid"],
        ],
        body: encoder.encode(body),
      });

      expect(response.status_code).toBe(401);
      expect(decodeBody(response)).toBe("Missing timestamp");
    });

    it("should reject requests with invalid signature", async () => {
      const body = JSON.stringify({
        type: "event_callback",
        token: "tok",
        team_id: "T123",
        api_app_id: "A123",
        event: {
          type: "message",
          user: "U1",
          text: "hi",
          ts: "1.1",
          channel: "C1",
        },
        event_id: "Ev003",
        event_time: 1700000000,
      });

      const response = await actor.http_request_update({
        method: "POST",
        url: "/webhook/slack/",
        headers: [
          ["content-type", "application/json"],
          ["x-slack-signature", "v0=deadbeefdeadbeef"],
          ["x-slack-request-timestamp", TEST_TIMESTAMP],
        ],
        body: encoder.encode(body),
      });

      expect(response.status_code).toBe(401);
      expect(decodeBody(response)).toBe("Invalid signature");
    });

    it("should accept requests with valid signature", async () => {
      const body = JSON.stringify({
        type: "event_callback",
        token: "tok",
        team_id: "T123",
        api_app_id: "A123",
        event: {
          type: "message",
          user: "U1",
          text: "signed message",
          ts: "1.1",
          channel: "C1",
        },
        event_id: "Ev004",
        event_time: 1700000000,
      });

      const response = await sendSignedWebhook(actor, body);

      expect(response.status_code).toBe(200);
      expect(decodeBody(response)).toBe("ok");
    });

    it("should reject when no signing secret is configured", async () => {
      // Delete the signing secret
      await actor.deleteSecret(0n, { slackSigningSecret: null });

      const body = JSON.stringify({
        type: "event_callback",
        token: "tok",
        team_id: "T123",
        api_app_id: "A123",
        event: {
          type: "message",
          user: "U1",
          text: "hi",
          ts: "1.1",
          channel: "C1",
        },
        event_id: "Ev005",
        event_time: 1700000000,
      });

      const response = await sendSignedWebhook(actor, body);

      expect(response.status_code).toBe(401);
      expect(decodeBody(response)).toBe("Slack signing secret not configured");
    });
  });

  // ============================================
  // Event Callback Processing
  // ============================================

  describe("event_callback", () => {
    it("should enqueue a standard message event", async () => {
      const body = JSON.stringify({
        type: "event_callback",
        token: "tok",
        team_id: "T123",
        api_app_id: "A123",
        event: {
          type: "message",
          user: "U_USER1",
          text: "Hello from test",
          ts: "1700000001.000001",
          channel: "C_CHAN1",
        },
        event_id: "Ev100",
        event_time: 1700000001,
      });

      const response = await sendSignedWebhook(actor, body);
      expect(response.status_code).toBe(200);
      expect(decodeBody(response)).toBe("ok");

      // Verify the event was enqueued
      const stats = await actor.getEventStoreStats();
      const queueStats = expectOk(stats);
      expect(queueStats.unprocessedEvents).toBe(1n);
    });

    it("should deduplicate events with the same event_id", async () => {
      const body = JSON.stringify({
        type: "event_callback",
        token: "tok",
        team_id: "T123",
        api_app_id: "A123",
        event: {
          type: "message",
          user: "U_USER2",
          text: "Dedup test",
          ts: "1700000002.000001",
          channel: "C_CHAN2",
        },
        event_id: "Ev200",
        event_time: 1700000002,
      });

      // Send the same event twice
      const response1 = await sendSignedWebhook(actor, body);
      expect(response1.status_code).toBe(200);

      const response2 = await sendSignedWebhook(actor, body);
      expect(response2.status_code).toBe(200);

      // Verify deduplication: only 1 event total across all queues
      const stats = await actor.getEventStoreStats();
      const queueStats = expectOk(stats);
      const totalEvents =
        queueStats.unprocessedEvents +
        queueStats.processedEvents +
        queueStats.failedEvents;
      expect(totalEvents).toBe(1n);
    });

    it("should enqueue an event with different type", async () => {
      const body = JSON.stringify({
        type: "event_callback",
        token: "tok",
        team_id: "T123",
        api_app_id: "A123",
        event: {
          type: "app_mention",
          user: "U_MENTION",
          text: "<@U_BOT> hello!",
          ts: "1700000003.000001",
          channel: "C_CHAN3",
          event_ts: "1700000003.000001",
        },
        event_id: "Ev300",
        event_time: 1700000003,
      });

      const response = await sendSignedWebhook(actor, body);
      expect(response.status_code).toBe(200);
      expect(decodeBody(response)).toBe("ok");

      // Verify the event was enqueued
      const stats = await actor.getEventStoreStats();
      const queueStats = expectOk(stats);
      expect(queueStats.unprocessedEvents).toBe(1n);
    });

    it("should skip unhandled message subtypes gracefully", async () => {
      const body = JSON.stringify({
        type: "event_callback",
        token: "tok",
        team_id: "T123",
        api_app_id: "A123",
        event: {
          type: "message",
          subtype: "channel_join",
          user: "U_JOIN",
          text: "User joined",
          ts: "1700000004.000001",
          channel: "C_CHAN4",
        },
        event_id: "Ev400",
        event_time: 1700000004,
      });

      const response = await sendSignedWebhook(actor, body);
      // Should return 200 even for skipped events (don't trigger Slack retries)
      expect(response.status_code).toBe(200);
      expect(decodeBody(response)).toBe("ok");

      // Verify the event was NOT enqueued
      const stats = await actor.getEventStoreStats();
      const queueStats = expectOk(stats);
      expect(queueStats.unprocessedEvents).toBe(0n);
    });
  });

  // ============================================
  // app_rate_limited
  // ============================================

  describe("app_rate_limited", () => {
    it("should handle app_rate_limited and return 200", async () => {
      const body = JSON.stringify({
        type: "app_rate_limited",
        team_id: "T123",
        minute_rate_limited: 1700000010,
      });

      const response = await sendSignedWebhook(actor, body);
      expect(response.status_code).toBe(200);
      expect(decodeBody(response)).toBe("ok");
    });
  });

  // ============================================
  // Unknown envelope types
  // ============================================

  describe("unknown envelope", () => {
    it("should handle unknown envelope type and return 200", async () => {
      const body = JSON.stringify({
        type: "some_future_type",
      });

      const response = await sendSignedWebhook(actor, body);
      expect(response.status_code).toBe(200);
      expect(decodeBody(response)).toBe("ok");
    });
  });

  // ============================================
  // Malformed payloads
  // ============================================

  describe("malformed payloads", () => {
    it("should reject non-JSON body", async () => {
      const response = await actor.http_request_update({
        method: "POST",
        url: "/webhook/slack/",
        headers: [["content-type", "application/json"]],
        body: encoder.encode("not valid json {{{"),
      });

      expect(response.status_code).toBe(400);
      expect(decodeBody(response)).toContain("Invalid payload");
    });

    it("should reject JSON without type field", async () => {
      const response = await actor.http_request_update({
        method: "POST",
        url: "/webhook/slack/",
        headers: [["content-type", "application/json"]],
        body: encoder.encode(JSON.stringify({ foo: "bar" })),
      });

      expect(response.status_code).toBe(400);
      expect(decodeBody(response)).toContain("Invalid payload");
    });

    it("should reject request to wrong path", async () => {
      const response = await actor.http_request_update({
        method: "POST",
        url: "/webhook/other",
        headers: [],
        body: encoder.encode("{}"),
      });

      expect(response.status_code).toBe(400);
      expect(decodeBody(response)).toBe("Unrecognized path");
    });

    it("should reject event_callback with missing required fields", async () => {
      const body = JSON.stringify({
        type: "event_callback",
        // Missing team_id, api_app_id, event, event_id, event_time
      });

      const response = await sendSignedWebhook(actor, body);
      // Should fail parsing — but still return 400 since it can't parse the event
      expect(response.status_code).toBe(400);
      expect(decodeBody(response)).toBe(
        "Invalid payload. Error: Missing 'team_id' in event_callback",
      );
    });
  });
});
