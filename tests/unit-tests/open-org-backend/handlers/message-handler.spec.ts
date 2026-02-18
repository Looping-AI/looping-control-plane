import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import { createTestCanister, type TestCanisterService } from "../../../setup";
import messageStandardStub from "../../../stubs/slack-payloads/message-standard.json";

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

  it("should successfully handle standard message event", async () => {
    // Arrange: Extract event data from stub
    const event = messageStandardStub.event;
    const workspaceId = 1n;

    const messageInput = {
      user: event.user,
      text: event.text,
      channel: event.channel,
      ts: event.ts,
      threadTs: event.thread_ts ? ([event.thread_ts] as [string]) : ([] as []),
    };

    // Act: Call the handler via test canister
    const result = await testCanister.testMessageHandler(
      workspaceId,
      messageInput,
    );

    // Assert: Handler should succeed
    expect("ok" in result).toBe(true);
    if ("ok" in result) {
      expect(result.ok.length).toBeGreaterThan(0);
      expect(result.ok[0].action).toBe("log_event");
      expect("ok" in result.ok[0].result).toBe(true);
    }
  });

  it("should handle message without thread context", async () => {
    // Arrange: Use stub but remove thread context for edge case
    const event = messageStandardStub.event;
    const workspaceId = 1n;

    const messageInput = {
      user: event.user,
      text: event.text,
      channel: event.channel,
      ts: event.ts,
      threadTs: [] as [], // No thread context
    };

    // Act
    const result = await testCanister.testMessageHandler(
      workspaceId,
      messageInput,
    );

    // Assert: Handler should still succeed
    expect("ok" in result).toBe(true);
    if ("ok" in result) {
      expect(result.ok.length).toBeGreaterThan(0);
    }
  });
});
