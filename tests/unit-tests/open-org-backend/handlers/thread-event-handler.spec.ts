import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import { createTestCanister, type TestCanisterService } from "../../../setup";
import threadBroadcastStub from "../../../stubs/slack-payloads/message-thread-broadcast.json";

describe("ThreadEventHandler Unit Tests", () => {
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

  it("should successfully handle thread broadcast event", async () => {
    // Arrange: Extract event data from stub
    const event = threadBroadcastStub.event;
    const workspaceId = 1n;

    const threadInput = {
      user: event.user,
      text: event.text,
      channel: event.channel,
      ts: event.ts,
      threadTs: event.thread_ts,
    };

    // Act: Call the handler via test canister
    const result = await testCanister.testThreadEventHandler(
      workspaceId,
      threadInput,
    );

    // Assert: Handler should succeed
    expect("ok" in result).toBe(true);
    if ("ok" in result) {
      expect(result.ok.length).toBeGreaterThan(0);
      expect(result.ok[0].action).toBe("log_event");
      expect("ok" in result.ok[0].result).toBe(true);
    }
  });

  it("should handle thread event in different channel context", async () => {
    // Arrange: Use stub but change channel for edge case
    const event = threadBroadcastStub.event;
    const workspaceId = 1n;

    const threadInput = {
      user: event.user,
      text: event.text,
      channel: "D0TESTDM456", // DM instead of public channel
      ts: event.ts,
      threadTs: event.thread_ts,
    };

    // Act
    const result = await testCanister.testThreadEventHandler(
      workspaceId,
      threadInput,
    );

    // Assert: Handler should still succeed
    expect("ok" in result).toBe(true);
    if ("ok" in result) {
      expect(result.ok.length).toBeGreaterThan(0);
    }
  });
});
