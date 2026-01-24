import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { Principal } from "@dfinity/principal";
import type { PocketIc, Actor, DeferredActor } from "@dfinity/pic";
import { generateRandomIdentity } from "@dfinity/pic";
import {
  createTestEnvironment,
  setupAdminUser,
  setupRegularUser,
  createGroqAgent,
  idlFactory,
  type _SERVICE,
} from "../../setup.ts";
import { expectOk, expectErr } from "../../helpers.ts";
import { withCassette } from "../../lib/cassette";

describe("Conversation Management", () => {
  let pic: PocketIc;
  let actor: Actor<_SERVICE>;
  let canisterId: Principal;
  let adminIdentity: ReturnType<typeof generateRandomIdentity>;
  let userIdentity: ReturnType<typeof generateRandomIdentity>;
  let agentId: bigint;

  beforeEach(async () => {
    const testEnv = await createTestEnvironment();
    pic = testEnv.pic;
    actor = testEnv.actor;
    canisterId = testEnv.canisterId;

    // Set up an admin
    ({ adminIdentity } = await setupAdminUser(actor));

    // Create a Groq agent with real API key for HTTP outcall tests
    ({ userIdentity } = await setupRegularUser(actor));
    agentId = await createGroqAgent(actor, adminIdentity);
  });

  afterEach(async () => {
    await pic.tearDown();
  });

  describe("get_conversation", () => {
    it("should return err message when no conversation exists with agent", async () => {
      actor.setIdentity(userIdentity);
      const result = await actor.getConversation(0n, agentId);
      expect(expectErr(result)).toEqual(
        "No conversation found with agent " + agentId,
      );
    });

    it("should contain correct message content in conversation history", async () => {
      const testMessage = "What is the capital of Germany?";

      // Create a deferred actor for the HTTP outcall
      const deferredActor: DeferredActor<_SERVICE> = pic.createDeferredActor(
        idlFactory,
        canisterId,
      );
      deferredActor.setIdentity(userIdentity);

      await withCassette(
        pic,
        "integration-tests/open-org-backend/conversations/correct-message-content",
        () => deferredActor.workspaceTalk(0n, agentId, testMessage),
        { ticks: 5 },
      );

      actor.setIdentity(userIdentity);
      const result = await actor.getConversation(0n, agentId);
      const messages = expectOk(result);

      const userMessage = messages.find(
        (msg: { author?: Record<string, unknown>; content?: string }) =>
          msg.author && "user" in msg.author,
      );
      expect(userMessage).toBeDefined();
      expect(userMessage?.content).toEqual(testMessage);
    });

    it("should maintain conversation history across multiple messages", async () => {
      const message1 = "What is 2 + 2?";
      const message2 = "What is 3 + 3?";
      const message3 = "What is 4 + 4?";

      // Create a deferred actor for the HTTP outcalls
      const deferredActor: DeferredActor<_SERVICE> = pic.createDeferredActor(
        idlFactory,
        canisterId,
      );
      deferredActor.setIdentity(userIdentity);

      await withCassette(
        pic,
        "integration-tests/open-org-backend/conversations/history-message-1",
        () => deferredActor.workspaceTalk(0n, agentId, message1),
        { ticks: 5 },
      );

      await withCassette(
        pic,
        "integration-tests/open-org-backend/conversations/history-message-2",
        () => deferredActor.workspaceTalk(0n, agentId, message2),
        { ticks: 5 },
      );

      await withCassette(
        pic,
        "integration-tests/open-org-backend/conversations/history-message-3",
        () => deferredActor.workspaceTalk(0n, agentId, message3),
        { ticks: 5 },
      );

      actor.setIdentity(userIdentity);
      const result = await actor.getConversation(0n, agentId);
      const messages = expectOk(result);
      expect(messages.length).toBeGreaterThanOrEqual(3);
    });

    it("should isolate conversations between different agents", async () => {
      // Create another Groq agent
      const user2 = await setupRegularUser(actor);
      const agentId2 = await createGroqAgent(actor, adminIdentity);

      const message1 = "What is the capital of France?";
      const message2 = "What is the capital of Spain?";

      // Create deferred actors for both users
      const deferredActor1: DeferredActor<_SERVICE> = pic.createDeferredActor(
        idlFactory,
        canisterId,
      );
      deferredActor1.setIdentity(userIdentity);

      const deferredActor2: DeferredActor<_SERVICE> = pic.createDeferredActor(
        idlFactory,
        canisterId,
      );
      deferredActor2.setIdentity(user2.userIdentity);

      // Send message to first agent
      await withCassette(
        pic,
        "integration-tests/open-org-backend/conversations/isolate-agent-1",
        () => deferredActor1.workspaceTalk(0n, agentId, message1),
        { ticks: 5 },
      );

      // Send message to second agent
      await withCassette(
        pic,
        "integration-tests/open-org-backend/conversations/isolate-agent-2",
        () => deferredActor2.workspaceTalk(0n, agentId2, message2),
        { ticks: 5 },
      );

      // Check conversation history for first agent
      actor.setIdentity(userIdentity);
      const result1 = await actor.getConversation(0n, agentId);
      const messages1 = expectOk(result1);
      const foundMsg1 = messages1.some(
        (msg: { content?: string }) => msg.content === message1,
      );
      expect(foundMsg1).toBe(true);

      // Check conversation history for second agent
      actor.setIdentity(user2.userIdentity);
      const result2 = await actor.getConversation(0n, agentId2);
      const messages2 = expectOk(result2);
      const foundMsg2 = messages2.some(
        (msg: { content?: string }) => msg.content === message2,
      );
      expect(foundMsg2).toBe(true);
    });
  });
});
