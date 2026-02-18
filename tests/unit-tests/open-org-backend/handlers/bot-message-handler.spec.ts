import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import { createTestCanister, type TestCanisterService } from "../../../setup";
import botMessageStub from "../../../stubs/slack-payloads/message-bot.json";

describe("BotMessageHandler Unit Tests", () => {
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

  it("should successfully handle bot message event", async () => {
    // Arrange: Extract event data from stub
    const event = botMessageStub.event;
    const workspaceId = 1n;

    const botInput = {
      botId: event.bot_id,
      text: event.text,
      channel: event.channel,
      ts: event.ts,
      username: event.username ? ([event.username] as [string]) : ([] as []),
    };

    // Act: Call the handler via test canister
    const result = await testCanister.testBotMessageHandler(
      workspaceId,
      botInput,
    );

    // Assert: Handler should succeed
    expect("ok" in result).toBe(true);
    if ("ok" in result) {
      expect(result.ok.length).toBeGreaterThan(0);
      expect(result.ok[0].action).toBe("log_event");
      expect("ok" in result.ok[0].result).toBe(true);
    }
  });

  it("should handle bot message without username", async () => {
    // Arrange: Use stub but remove username for edge case
    const event = botMessageStub.event;
    const workspaceId = 1n;

    const botInput = {
      botId: event.bot_id,
      text: event.text,
      channel: event.channel,
      ts: event.ts,
      username: [] as [], // No username
    };

    // Act
    const result = await testCanister.testBotMessageHandler(
      workspaceId,
      botInput,
    );

    // Assert: Handler should still succeed
    expect("ok" in result).toBe(true);
    if ("ok" in result) {
      expect(result.ok.length).toBeGreaterThan(0);
    }
  });
});
