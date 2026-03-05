import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import {
  createTestCanister,
  type TestCanisterService,
} from "../../../../setup";
import messageDeletedStub from "../../../../stubs/slack-payloads/message-deleted.json";

describe("MessageDeletedHandler Unit Tests", () => {
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

  it("should successfully handle message deleted event", async () => {
    // Arrange: Extract event data from stub
    const event = messageDeletedStub.event;

    const deletedInput = {
      channel: event.channel,
      deletedTs: event.deleted_ts,
    };

    // Act: Call the handler via test canister
    const result = await testCanister.testMessageDeletedHandler(deletedInput);

    // Assert: Handler should succeed
    expect("ok" in result).toBe(true);
    if ("ok" in result) {
      expect(result.ok.length).toBeGreaterThan(0);
      expect(result.ok[0].action).toBe("delete_message");
      // result is #err("message not found") because the store is empty — expected
      expect("err" in result.ok[0].result).toBe(true);
    }
  });

  it("should handle deleted message with different channel types", async () => {
    // Arrange: Use stub but change to a public channel for edge case
    const event = messageDeletedStub.event;

    const deletedInput = {
      channel: "C0TESTCHANNEL", // Public channel instead of DM
      deletedTs: event.deleted_ts,
    };

    // Act
    const result = await testCanister.testMessageDeletedHandler(deletedInput);

    // Assert: Handler should still succeed
    expect("ok" in result).toBe(true);
    if ("ok" in result) {
      expect(result.ok.length).toBeGreaterThan(0);
    }
  });
});
