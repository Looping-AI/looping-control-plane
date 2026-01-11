import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { Principal } from "@dfinity/principal";
import type { PocketIc, Actor } from "@dfinity/pic";
import { generateRandomIdentity } from "@dfinity/pic";
import type { _SERVICE } from "../../../.dfx/local/canisters/bot-agent-backend/service.did.js";
import {
  createTestEnvironment,
  setupAdminUser,
  setupRegularUser,
  createTestAgent,
} from "./setup.ts";
import { expectOk, expectErr } from "./helpers.ts";

describe("Conversation Management", () => {
  let pic: PocketIc;
  let actor: Actor<_SERVICE>;
  let adminIdentity: ReturnType<typeof generateRandomIdentity>;
  let userIdentity: ReturnType<typeof generateRandomIdentity>;
  let agentId: bigint;

  beforeEach(async () => {
    const testEnv = await createTestEnvironment();
    pic = testEnv.pic;
    actor = testEnv.actor;

    // Set up an admin
    ({ adminIdentity } = await setupAdminUser(actor));

    // Create a test agent
    agentId = await createTestAgent(
      actor,
      "Test Conversation Agent",
      { openai: null },
      "gpt-4",
    );

    // Set up a regular user
    ({ userIdentity } = setupRegularUser(actor));
  });

  afterEach(async () => {
    await pic.tearDown();
  });

  describe("talk_to", () => {
    it("should reject anonymous users from sending messages", async () => {
      actor.setPrincipal(Principal.anonymous());

      const result = await actor.talkTo(agentId, "Hello Agent");
      expect(expectErr(result)).toEqual(
        "Please login before calling this function",
      );
    });

    it("should accept message from authenticated user", async () => {
      const result = await actor.talkTo(agentId, "Hello Agent");
      expectOk(result);
    });
  });

  describe("get_conversation", () => {
    it("should return err message when no conversation exists with agent", async () => {
      const result = await actor.getConversation(agentId);
      expect(expectErr(result)).toEqual(
        "No conversation found with agent " + agentId,
      );
    });

    it("should contain correct message content in conversation history", async () => {
      const testMessage = "This is a test message";
      await actor.talkTo(agentId, testMessage);

      const result = await actor.getConversation(agentId);
      const messages = expectOk(result);

      const userMessage = messages.find(
        (msg: { author?: Record<string, unknown>; content?: string }) =>
          msg.author && "user" in msg.author,
      );
      expect(userMessage).toBeDefined();
      expect(userMessage?.content).toEqual(testMessage);
    });

    it("should maintain conversation history across multiple messages", async () => {
      const message1 = "First message";
      const message2 = "Second message";
      const message3 = "Third message";

      await actor.talkTo(agentId, message1);
      await actor.talkTo(agentId, message2);
      await actor.talkTo(agentId, message3);

      const result = await actor.getConversation(agentId);
      const messages = expectOk(result);
      expect(messages.length).toBeGreaterThanOrEqual(3);
    });

    it("should isolate conversations between different agents", async () => {
      // Create another agent
      actor.setIdentity(adminIdentity);
      const agentId2 = await createTestAgent(
        actor,
        "Another Agent",
        { groq: null },
        "mixtral",
      );

      // Switch back to user and send messages to different agents
      actor.setIdentity(userIdentity);
      const message1 = "Message for first agent";
      const message2 = "Message for second agent";

      await actor.talkTo(agentId, message1);
      await actor.talkTo(agentId2, message2);

      // Check conversation history for first agent
      const result1 = await actor.getConversation(agentId);
      const messages1 = expectOk(result1);
      const foundMsg1 = messages1.some(
        (msg: { content?: string }) => msg.content === message1,
      );
      expect(foundMsg1).toBe(true);

      // Check conversation history for second agent
      const result2 = await actor.getConversation(agentId2);
      const messages2 = expectOk(result2);
      const foundMsg2 = messages2.some(
        (msg: { content?: string }) => msg.content === message2,
      );
      expect(foundMsg2).toBe(true);
    });
  });
});
