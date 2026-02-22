import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, DeferredActor } from "@dfinity/pic";
import {
  createDeferredTestCanister,
  type TestCanisterService,
} from "../../../setup";
import { withCassette } from "../../../lib/cassette";
import { resolveSpecsChannel } from "../../../helpers";
import messageStandardStub from "../../../stubs/slack-payloads/message-standard.json";

// ============================================
// MessageHandler is a full controller that:
//   1. Derives an encryption key for the workspace
//   2. Looks up the Slack bot token from secrets
//   3. Calls the LLM orchestrator
//   4. Posts the reply back to Slack
//
// All tests use a deferred actor + cassette so that the Groq LLM call and
// the Slack HTTP POST are recorded on first run and replayed on CI.
//
// Tokens are loaded from .env.test (SLACK_APP_BOT_TOKEN, GROQ_TEST_KEY).
// All messages are directed to a "specs-only" Slack channel
// which is dedicated to automated test traffic.
// ============================================

const BOT_TOKEN =
  process.env["SLACK_APP_BOT_TOKEN"] ?? "not-needed-due-to-cassette";
const GROQ_API_KEY =
  process.env["GROQ_TEST_KEY"] ?? "not-needed-due-to-cassette";

describe("MessageHandler Unit Tests", () => {
  let pic: PocketIc;
  let testCanister: DeferredActor<TestCanisterService>;

  beforeEach(async () => {
    const testEnv = await createDeferredTestCanister();
    pic = testEnv.pic;
    testCanister = testEnv.actor;
  });

  afterEach(async () => {
    await pic.tearDown();
  });

  // ============================================
  // Happy-path — bot token + Groq key configured
  // The cassette records the Groq LLM call and the Slack POST on first run
  // and replays them on subsequent runs (CI, offline, etc.).
  // ============================================

  it("should post a reply for a standard channel message", async () => {
    const event = messageStandardStub.event;
    const cassetteName =
      "unit-tests/open-org-backend/handlers/message-handler/standard-message-reply";
    const channel = await resolveSpecsChannel(cassetteName);

    const { result } = await withCassette(
      pic,
      cassetteName,
      () =>
        testCanister.testMessageHandlerWithSecrets(
          1n,
          {
            user: event.user,
            text: event.text,
            channel,
            ts: event.ts,
            threadTs: event.thread_ts
              ? ([event.thread_ts] as [string])
              : ([] as []),
          },
          BOT_TOKEN,
          GROQ_API_KEY,
        ),
      { ticks: 5, maxRounds: 5 },
    );

    const response = await result;
    expect("ok" in response).toBe(true);
    if ("ok" in response) {
      // The final step must be a successful Slack post
      const lastStep = response.ok[response.ok.length - 1];
      expect(lastStep.action).toBe("post_to_slack");
      expect("ok" in lastStep.result).toBe(true);
      // Every step must carry a nanosecond timestamp
      for (const step of response.ok) {
        expect(typeof step.timestamp).toBe("bigint");
        expect(step.timestamp).toBeGreaterThan(0n);
      }
    }
  });

  it("should reply within an existing thread when threadTs is set", async () => {
    const cassetteName =
      "unit-tests/open-org-backend/handlers/message-handler/thread-reply";
    const channel = await resolveSpecsChannel(cassetteName);
    const { result } = await withCassette(
      pic,
      cassetteName,
      () =>
        testCanister.testMessageHandlerWithSecrets(
          1n,
          {
            user: "U_THREAD",
            text: "This is a thread reply",
            channel,
            ts: "1700000010.000001",
            threadTs: ["1700000005.000000"] as [string],
          },
          BOT_TOKEN,
          GROQ_API_KEY,
        ),
      { ticks: 5, maxRounds: 5 },
    );

    const response = await result;
    expect("ok" in response).toBe(true);
    if ("ok" in response) {
      const lastStep = response.ok[response.ok.length - 1];
      expect(lastStep.action).toBe("post_to_slack");
      expect("ok" in lastStep.result).toBe(true);
    }
  });

  it("should post a top-level channel message when threadTs is absent", async () => {
    const cassetteName =
      "unit-tests/open-org-backend/handlers/message-handler/top-level-channel-post";
    const channel = await resolveSpecsChannel(cassetteName);
    const { result } = await withCassette(
      pic,
      cassetteName,
      () =>
        testCanister.testMessageHandlerWithSecrets(
          1n,
          {
            user: "U_CHANNEL",
            text: "Hello channel",
            channel,
            ts: "1700000010.000001",
            threadTs: [] as [],
          },
          BOT_TOKEN,
          GROQ_API_KEY,
        ),
      { ticks: 5, maxRounds: 5 },
    );

    const response = await result;
    expect("ok" in response).toBe(true);
    if ("ok" in response) {
      const lastStep = response.ok[response.ok.length - 1];
      expect(lastStep.action).toBe("post_to_slack");
      expect("ok" in lastStep.result).toBe(true);
    }
  });

  it("should handle messages consistently across multiple workspace IDs", async () => {
    for (const [wsId, label] of [
      [0n, "ws0"],
      [1n, "ws1"],
      [42n, "ws42"],
    ] as [bigint, string][]) {
      const cassetteName = `unit-tests/open-org-backend/handlers/message-handler/multi-workspace-${label}`;
      const channel = await resolveSpecsChannel(cassetteName);
      const { result } = await withCassette(
        pic,
        cassetteName,
        () =>
          testCanister.testMessageHandlerWithSecrets(
            wsId,
            {
              user: "U_TEST",
              text: `Hello from workspace ${label}`,
              channel,
              ts: "1700000010.000001",
              threadTs: [] as [],
            },
            BOT_TOKEN,
            GROQ_API_KEY,
          ),
        { ticks: 5, maxRounds: 5 },
      );

      const response = await result;
      expect("ok" in response).toBe(true);
      if ("ok" in response) {
        const lastStep = response.ok[response.ok.length - 1];
        expect(lastStep.action).toBe("post_to_slack");
        expect(lastStep.timestamp).toBeGreaterThan(0n);
      }
    }
  }, 20000);

  it("should include a positive nanosecond timestamp in every returned step", async () => {
    const event = messageStandardStub.event;
    const cassetteName =
      "unit-tests/open-org-backend/handlers/message-handler/step-timestamps";
    const channel = await resolveSpecsChannel(cassetteName);

    const { result } = await withCassette(
      pic,
      cassetteName,
      () =>
        testCanister.testMessageHandlerWithSecrets(
          0n,
          {
            user: event.user,
            text: event.text,
            channel,
            ts: event.ts,
            threadTs: [] as [],
          },
          BOT_TOKEN,
          GROQ_API_KEY,
        ),
      { ticks: 5, maxRounds: 5 },
    );

    const response = await result;
    expect("ok" in response).toBe(true);
    if ("ok" in response) {
      for (const step of response.ok) {
        expect(typeof step.timestamp).toBe("bigint");
        expect(step.timestamp).toBeGreaterThan(0n);
      }
    }
  });
});
