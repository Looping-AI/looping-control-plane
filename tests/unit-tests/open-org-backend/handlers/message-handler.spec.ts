import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import { createTestCanister, type TestCanisterService } from "../../../setup";
import messageStandardStub from "../../../stubs/slack-payloads/message-standard.json";
import messageThreadStub from "../../../stubs/slack-payloads/message-thread-broadcast.json";

// ============================================
// MessageHandler is a full controller that:
//   1. Derives an encryption key for the workspace
//   2. Looks up the Slack bot token from secrets
//   3. Calls the LLM orchestrator
//   4. Posts the reply back to Slack
//
// The test-canister provides an empty EventProcessingContext (no secrets,
// no conversations), so these unit tests verify the graceful-degradation
// path: missing bot token → early-exit with a descriptive error step.
// End-to-end happy-path (LLM reply + Slack post) is covered in the
// integration tests (workspace-admin-talk.spec.ts + slack-webhook.spec.ts).
// ============================================

describe("MessageHandler Unit Tests", () => {
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
  // Graceful degradation — no secrets configured
  // ============================================

  it("should return a post_to_slack error step when no bot token is configured", async () => {
    const event = messageStandardStub.event;
    const workspaceId = 1n;

    const messageInput = {
      user: event.user,
      text: event.text,
      channel: event.channel,
      ts: event.ts,
      threadTs: event.thread_ts ? ([event.thread_ts] as [string]) : ([] as []),
    };

    const result = await testCanister.testMessageHandler(
      workspaceId,
      messageInput,
    );

    // Handler exits early with an error step — does NOT throw
    expect("ok" in result).toBe(true);
    if ("ok" in result) {
      expect(result.ok.length).toBe(1);
      expect(result.ok[0].action).toBe("post_to_slack");
      expect("err" in result.ok[0].result).toBe(true);
      if ("err" in result.ok[0].result) {
        expect(result.ok[0].result.err).toContain("No Slack bot token");
      }
    }
  });

  it("should return a post_to_slack error step when message has no thread context", async () => {
    const event = messageStandardStub.event;
    const workspaceId = 1n;

    const messageInput = {
      user: event.user,
      text: event.text,
      channel: event.channel,
      ts: event.ts,
      threadTs: [] as [], // top-level message
    };

    const result = await testCanister.testMessageHandler(
      workspaceId,
      messageInput,
    );

    expect("ok" in result).toBe(true);
    if ("ok" in result) {
      expect(result.ok[0].action).toBe("post_to_slack");
      expect("err" in result.ok[0].result).toBe(true);
    }
  });

  it("should return a post_to_slack error step for thread reply messages", async () => {
    // Thread replies (threadTs set) should follow the same path
    const workspaceId = 1n;
    const messageInput = {
      user: "U_THREAD",
      text: "This is a thread reply",
      channel: "C_THREAD_CHAN",
      ts: "1700000010.000001",
      threadTs: ["1700000005.000000"] as [string],
    };

    const result = await testCanister.testMessageHandler(
      workspaceId,
      messageInput,
    );

    expect("ok" in result).toBe(true);
    if ("ok" in result) {
      expect(result.ok[0].action).toBe("post_to_slack");
      expect("err" in result.ok[0].result).toBe(true);
    }
  });

  it("should handle messages consistently across different workspace IDs", async () => {
    const event = messageStandardStub.event;

    for (const workspaceId of [0n, 1n, 42n]) {
      const result = await testCanister.testMessageHandler(workspaceId, {
        user: event.user,
        text: event.text,
        channel: event.channel,
        ts: event.ts,
        threadTs: [] as [],
      });
      expect("ok" in result).toBe(true);
      if ("ok" in result) {
        // Each workspace independently returns the same error-step shape
        expect(result.ok[0].action).toBe("post_to_slack");
        expect(result.ok[0].timestamp).toBeGreaterThan(0n);
      }
    }
  });

  it("should include a timestamp in every returned step", async () => {
    const event = messageStandardStub.event;
    const workspaceId = 0n;

    const result = await testCanister.testMessageHandler(workspaceId, {
      user: event.user,
      text: event.text,
      channel: event.channel,
      ts: event.ts,
      threadTs: [] as [],
    });

    expect("ok" in result).toBe(true);
    if ("ok" in result) {
      for (const step of result.ok) {
        // Timestamp must be a positive nanosecond bigint
        expect(typeof step.timestamp).toBe("bigint");
        expect(step.timestamp).toBeGreaterThan(0n);
      }
    }
  });

  it("should produce thread-broadcast stubs without errors", async () => {
    // Verify the thread-broadcast stub parses and triggers the same path
    const event = messageThreadStub.event;
    const workspaceId = 1n;

    const result = await testCanister.testMessageHandler(workspaceId, {
      user: (event as { user?: string }).user ?? "U_UNKNOWN",
      text: event.text,
      channel: event.channel,
      ts: event.ts,
      threadTs: [] as [],
    });

    expect("ok" in result).toBe(true);
  });
});
