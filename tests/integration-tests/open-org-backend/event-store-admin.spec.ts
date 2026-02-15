import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { Principal } from "@dfinity/principal";
import type { PocketIc, Actor } from "@dfinity/pic";
import { generateRandomIdentity } from "@dfinity/pic";
import { createHmac } from "node:crypto";
import type { _SERVICE } from "../../setup.ts";
import {
  createTestEnvironment,
  setupAdminUser,
  setupRegularUser,
} from "../../setup.ts";
import { expectOk, expectErr } from "../../helpers.ts";

// ============================================
// NOTE: Event store behavior (queueing, processing, failure handling) is
// tested in depth in the EventStoreModel unit tests. This integration test
// file focuses on controller-level responsibilities, primarily access gating.
// ============================================

// ============================================
// Test Helpers
// ============================================

const encoder = new TextEncoder();
const TEST_SIGNING_SECRET = "test-signing-secret-admin";
const TEST_TIMESTAMP = "1700000000";

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

async function sendSignedEvent(actor: Actor<_SERVICE>, eventId: string) {
  const body = JSON.stringify({
    type: "event_callback",
    token: "tok",
    team_id: "T123",
    api_app_id: "A123",
    event: {
      type: "message",
      user: "U_ADMIN_TEST",
      text: "Admin test message",
      ts: "1700000001.000001",
      channel: "C_ADMIN",
    },
    event_id: eventId,
    event_time: 1700000001,
  });

  const sig = computeSlackSignature(TEST_SIGNING_SECRET, TEST_TIMESTAMP, body);
  return actor.http_request_update({
    method: "POST",
    url: "/webhook/slack",
    headers: [
      ["content-type", "application/json"],
      ["x-slack-signature", sig],
      ["x-slack-request-timestamp", TEST_TIMESTAMP],
    ],
    body: encoder.encode(body),
  });
}

// ============================================
// Tests
// ============================================

describe("Event Store Admin", () => {
  let pic: PocketIc;
  let actor: Actor<_SERVICE>;
  let ownerIdentity: ReturnType<typeof generateRandomIdentity>;
  let orgAdminIdentity: ReturnType<typeof generateRandomIdentity>;
  let userIdentity: ReturnType<typeof generateRandomIdentity>;

  beforeEach(async () => {
    const testEnv = await createTestEnvironment();
    pic = testEnv.pic;
    actor = testEnv.actor;
    ownerIdentity = testEnv.ownerIdentity;

    // Set up org admin (owner promotes workspace admin to org admin)
    const { adminIdentity, adminPrincipal } = await setupAdminUser(actor);
    const addOrgResult = await actor.addOrgAdmin(adminPrincipal);
    expectOk(addOrgResult);
    orgAdminIdentity = adminIdentity;

    // Set up regular user
    ({ userIdentity } = await setupRegularUser(actor));

    // Store signing secret for webhook tests (owner identity is active)
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
  // Access Control Tests
  // ============================================

  describe("Anonymous user", () => {
    it("should reject all event store admin methods", async () => {
      actor.setPrincipal(Principal.anonymous());

      const statsResult = await actor.getEventStoreStats();
      expectErr(statsResult);

      const failedResult = await actor.getFailedEvents();
      expectErr(failedResult);

      const deleteResult = await actor.deleteFailedEvents([]);
      expectErr(deleteResult);
    });
  });

  describe("Regular user", () => {
    it("should reject all event store admin methods", async () => {
      actor.setIdentity(userIdentity);

      const statsResult = await actor.getEventStoreStats();
      expectErr(statsResult);

      const failedResult = await actor.getFailedEvents();
      expectErr(failedResult);

      const deleteResult = await actor.deleteFailedEvents([]);
      expectErr(deleteResult);
    });
  });

  describe("Org admin", () => {
    it("should allow all event store admin methods", async () => {
      actor.setIdentity(orgAdminIdentity);

      const statsResult = await actor.getEventStoreStats();
      expectOk(statsResult);

      const failedResult = await actor.getFailedEvents();
      expectOk(failedResult);

      const deleteResult = await actor.deleteFailedEvents([]);
      expectOk(deleteResult);
    });
  });

  describe("Org owner", () => {
    it("should allow all event store admin methods", async () => {
      actor.setIdentity(ownerIdentity);

      const statsResult = await actor.getEventStoreStats();
      expectOk(statsResult);

      const failedResult = await actor.getFailedEvents();
      expectOk(failedResult);

      const deleteResult = await actor.deleteFailedEvents([]);
      expectOk(deleteResult);
    });
  });

  // ============================================
  // Specific Behavior Tests
  // ============================================

  describe("getEventStoreStats behavior", () => {
    it("should return zero stats on fresh canister", async () => {
      const stats = await actor.getEventStoreStats();
      const result = expectOk(stats);
      expect(result.unprocessedEvents).toBe(0n);
      expect(result.processedEvents).toBe(0n);
      expect(result.failedEvents).toBe(0n);
    });

    it("should reflect enqueued events after webhook", async () => {
      await sendSignedEvent(actor, "EvStats1");

      const stats = await actor.getEventStoreStats();
      const result = expectOk(stats);
      expect(result.unprocessedEvents).toBe(1n);
    });
  });

  describe("getFailedEvents behavior", () => {
    it("should return empty array when no failed events", async () => {
      const result = await actor.getFailedEvents();
      const events = expectOk(result);
      expect(events).toEqual([]);
    });
  });

  describe("deleteFailedEvents behavior", () => {
    it("should return deleted count 0 when no failed events", async () => {
      const result = await actor.deleteFailedEvents([]);
      const deleted = expectOk(result);
      expect(deleted.deleted).toBe(0n);
    });

    it("should return deleted count 0 for non-existent event ID", async () => {
      const result = await actor.deleteFailedEvents(["slack_nonexistent"]);
      const deleted = expectOk(result);
      expect(deleted.deleted).toBe(0n);
    });
  });
});
