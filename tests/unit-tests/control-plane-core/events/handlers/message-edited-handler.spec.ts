import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import {
  createTestCanister,
  type TestCanisterService,
} from "../../../../setup";
import messageChangedStub from "../../../../stubs/slack-payloads/message-changed.json";

describe("MessageEditedHandler Unit Tests", () => {
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

  it("should successfully handle message edited event", async () => {
    // Arrange: Extract event data from stub
    const event = messageChangedStub.event;

    const editedInput = {
      channel: event.channel,
      messageTs: event.message.ts,
      threadTs: [] as [],
      newText: event.message.text,
      editedBy: event.message.edited?.user
        ? ([event.message.edited.user] as [string])
        : ([] as []),
    };

    // Act: Call the handler via test canister
    const result = await testCanister.testMessageEditedHandler(editedInput);

    // Assert: Handler should succeed
    expect("ok" in result).toBe(true);
    if ("ok" in result) {
      expect(result.ok.length).toBeGreaterThan(0);
      expect(result.ok[0].action).toBe("update_conversation");
      // result is #err("message not found") because the store is empty — expected
      expect("err" in result.ok[0].result).toBe(true);
    }
  });

  it("should handle edited message without explicit editor", async () => {
    // Arrange: Use stub but remove editor info for edge case
    const event = messageChangedStub.event;
    const editedInput = {
      channel: event.channel,
      messageTs: event.message.ts,
      threadTs: [] as [],
      newText: event.message.text,
      editedBy: [] as [], // No explicit editor
    };

    // Act
    const result = await testCanister.testMessageEditedHandler(editedInput);

    // Assert: Handler should still succeed
    expect("ok" in result).toBe(true);
    if ("ok" in result) {
      expect(result.ok.length).toBeGreaterThan(0);
    }
  });
});
