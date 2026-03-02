import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { Principal } from "@icp-sdk/core/principal";
import type { PocketIc, Actor } from "@dfinity/pic";
import { generateRandomIdentity } from "@dfinity/pic";
import {
  createTestEnvironment,
  setupAdminUser,
  setupRegularUser,
  createGroqAgent,
  type _SERVICE,
} from "../../setup.ts";
import { expectErr } from "../../helpers.ts";

describe("Conversation Management", () => {
  let pic: PocketIc;
  let actor: Actor<_SERVICE>;
  let ownerIdentity: ReturnType<typeof generateRandomIdentity>;
  let adminIdentity: ReturnType<typeof generateRandomIdentity>;

  beforeEach(async () => {
    const testEnv = await createTestEnvironment();
    pic = testEnv.pic;
    actor = testEnv.actor;
    ownerIdentity = testEnv.ownerIdentity;

    // Set up an admin
    ({ adminIdentity } = await setupAdminUser(actor));

    // Create a Groq agent (needed so the workspace exists in a valid state)
    await setupRegularUser(actor);
    await createGroqAgent(actor, ownerIdentity, adminIdentity);
  });

  afterEach(async () => {
    await pic.tearDown();
  });

  describe("get_admin_conversation", () => {
    it("should return err message for non-existent workspace", async () => {
      actor.setIdentity(adminIdentity);
      const result = await actor.getAdminConversation(999n);
      expect(expectErr(result)).toEqual("Workspace not found.");
    });

    it("should reject non-workspace admins from viewing admin conversation", async () => {
      // Create a new user who is not a workspace admin
      const outsiderIdentity = generateRandomIdentity();

      actor.setIdentity(outsiderIdentity);
      const result = await actor.getAdminConversation(0n);
      expect(expectErr(result)).toEqual(
        "Only workspace admins can perform this action.",
      );
    });

    it("should reject anonymous users from viewing admin conversation", async () => {
      actor.setPrincipal(Principal.anonymous());
      const result = await actor.getAdminConversation(0n);
      expect(expectErr(result)).toEqual(
        "Please login before calling this function.",
      );
    });
  });
});
