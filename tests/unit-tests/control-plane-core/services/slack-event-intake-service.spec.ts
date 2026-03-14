import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import { createTestCanister, type TestCanisterService } from "../../../setup";
import standardMessagePayload from "../../../stubs/slack-payloads/message-standard.json";
import appMentionPayload from "../../../stubs/slack-payloads/app-mention.json";
import botOwnAppPayload from "../../../stubs/slack-payloads/message-bot-own-app.json";
import botOwnAppWithSubtypePayload from "../../../stubs/slack-payloads/message-bot-own-app-with-subtype.json";
import thirdPartyBotPayload from "../../../stubs/slack-payloads/message-bot-third-party.json";

// ============================================
// SlackEventIntakeService Unit Tests
//
// Exercises the normalize → enqueue pipeline in isolation via the test canister.
// HTTP concerns (routing, signature verification, key derivation) are intentionally
// absent — those belong to the integration tests for http_request_update.
//
// Each test uses a fresh canister so testEventStore starts empty.
// State is verified via testGetEventStoreStatsHandler.
// ============================================

const PRIMARY_OWNER = { isPrimaryOwner: true, isOrgAdmin: false };

interface StatsResponse {
  success: boolean;
  unprocessedEvents?: number;
  processedEvents?: number;
  failedEvents?: number;
  error?: string;
}

function parseStats(json: string): StatsResponse {
  return JSON.parse(json);
}

describe("SlackEventIntakeService", () => {
  let pic: PocketIc;
  let testCanister: Actor<TestCanisterService>;

  beforeEach(async () => {
    const testEnv = await createTestCanister();
    pic = testEnv.pic;
    testCanister = testEnv.actor;
  });

  afterEach(async () => {
    await pic.tearDown();
  });

  // ============================================
  // Enqueue behaviour
  // ============================================

  describe("enqueue", () => {
    it("should enqueue a standard message event", async () => {
      const result = await testCanister.testSlackEventIntakeService(
        JSON.stringify(standardMessagePayload),
      );
      expect(result).toStartWith("enqueued:");

      const stats = parseStats(
        await testCanister.testGetEventStoreStatsHandler("{}", PRIMARY_OWNER),
      );
      expect(stats.unprocessedEvents).toBe(1);
    });

    it("should enqueue an app_mention event", async () => {
      const result = await testCanister.testSlackEventIntakeService(
        JSON.stringify(appMentionPayload),
      );
      expect(result).toStartWith("enqueued:");

      const stats = parseStats(
        await testCanister.testGetEventStoreStatsHandler("{}", PRIMARY_OWNER),
      );
      expect(stats.unprocessedEvents).toBe(1);
    });

    it("should enqueue own-bot message with agent metadata", async () => {
      // Own-bot messages that carry agent metadata (assistant DM thread pattern)
      // must be enqueued so the handler can inspect the agent lineage.
      const result = await testCanister.testSlackEventIntakeService(
        JSON.stringify(botOwnAppPayload),
      );
      expect(result).toStartWith("enqueued:");

      const stats = parseStats(
        await testCanister.testGetEventStoreStatsHandler("{}", PRIMARY_OWNER),
      );
      expect(stats.unprocessedEvents).toBe(1);
    });
  });

  // ============================================
  // Deduplication
  // ============================================

  describe("deduplication", () => {
    it("should deduplicate events with the same event_id", async () => {
      const body = JSON.stringify(standardMessagePayload);

      const first = await testCanister.testSlackEventIntakeService(body);
      expect(first).toStartWith("enqueued:");

      const second = await testCanister.testSlackEventIntakeService(body);
      expect(second).toBe("duplicate");

      // Only one event in the store
      const stats = parseStats(
        await testCanister.testGetEventStoreStatsHandler("{}", PRIMARY_OWNER),
      );
      expect(stats.unprocessedEvents).toBe(1);
    });
  });

  // ============================================
  // Skip / filter behaviour
  // ============================================

  describe("skipped events", () => {
    it("should skip own-bot message with bot_message subtype", async () => {
      const result = await testCanister.testSlackEventIntakeService(
        JSON.stringify(botOwnAppWithSubtypePayload),
      );
      expect(result).toStartWith("skipped:");

      const stats = parseStats(
        await testCanister.testGetEventStoreStatsHandler("{}", PRIMARY_OWNER),
      );
      expect(stats.unprocessedEvents).toBe(0);
    });

    it("should skip bot_message from a third-party bot", async () => {
      const result = await testCanister.testSlackEventIntakeService(
        JSON.stringify(thirdPartyBotPayload),
      );
      expect(result).toStartWith("skipped:");

      const stats = parseStats(
        await testCanister.testGetEventStoreStatsHandler("{}", PRIMARY_OWNER),
      );
      expect(stats.unprocessedEvents).toBe(0);
    });

    it("should skip channel_join subtype", async () => {
      const payload = JSON.stringify({
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
        event_id: "Ev_CHAN_JOIN",
        event_time: 1700000004,
      });

      const result = await testCanister.testSlackEventIntakeService(payload);
      expect(result).toStartWith("skipped:");

      const stats = parseStats(
        await testCanister.testGetEventStoreStatsHandler("{}", PRIMARY_OWNER),
      );
      expect(stats.unprocessedEvents).toBe(0);
    });
  });

  // ============================================
  // Non-event_callback envelopes
  // ============================================

  describe("non-event_callback envelopes", () => {
    it("should return notEventCallback for url_verification body", async () => {
      const payload = JSON.stringify({
        type: "url_verification",
        challenge: "some-challenge",
        token: "tok",
      });

      const result = await testCanister.testSlackEventIntakeService(payload);
      expect(result).toBe("notEventCallback");

      const stats = parseStats(
        await testCanister.testGetEventStoreStatsHandler("{}", PRIMARY_OWNER),
      );
      expect(stats.unprocessedEvents).toBe(0);
    });
  });
});
