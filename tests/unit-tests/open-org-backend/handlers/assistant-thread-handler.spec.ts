import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import { createTestCanister, type TestCanisterService } from "../../../setup";
import assistantThreadStartedStub from "../../../stubs/slack-payloads/assistant-thread-started.json";
import assistantThreadContextChangedStub from "../../../stubs/slack-payloads/assistant-thread-context-changed.json";

describe("AssistantThreadHandler Unit Tests", () => {
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

  it("should successfully handle assistant thread event", async () => {
    // Arrange: Extract event data from assistant_thread_started stub
    const at = assistantThreadStartedStub.event.assistant_thread;

    const threadInput = {
      eventType: { threadStarted: null },
      userId: at.user_id,
      channelId: at.channel_id,
      threadTs: at.thread_ts,
      eventTs: assistantThreadStartedStub.event.event_ts,
      context: { started: { forceSearch: at.context.force_search } },
    };

    // Act: Call the handler via test canister (covers thread lifecycle events)
    const result =
      await testCanister.testAssistantThreadEventHandler(threadInput);

    // Assert: Handler should succeed
    expect("ok" in result).toBe(true);
    if ("ok" in result) {
      expect(result.ok.length).toBeGreaterThan(0);
      expect(result.ok[0].action).toBe("log_event");
      expect("ok" in result.ok[0].result).toBe(true);
    }
  });

  it("should handle assistant thread event in different channel context", async () => {
    // Arrange: Extract event data from assistant_thread_context_changed stub
    const at = assistantThreadContextChangedStub.event.assistant_thread;
    const threadInput = {
      eventType: { threadContextChanged: null },
      userId: at.user_id,
      channelId: at.channel_id,
      threadTs: at.thread_ts,
      eventTs: assistantThreadContextChangedStub.event.event_ts,
      context: {
        contextChanged: {
          channelId: [at.context.channel_id] as [string],
          teamId: [at.context.team_id] as [string],
          enterpriseId: [at.context.enterprise_id] as [string],
        },
      },
    };

    // Act
    const result =
      await testCanister.testAssistantThreadEventHandler(threadInput);

    // Assert: Handler should still succeed
    expect("ok" in result).toBe(true);
    if ("ok" in result) {
      expect(result.ok.length).toBeGreaterThan(0);
    }
  });
});
