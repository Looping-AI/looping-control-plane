import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { Principal } from "@dfinity/principal";
import type { PocketIc, Actor } from "@dfinity/pic";
import { generateRandomIdentity } from "@dfinity/pic";
import type { _SERVICE } from "../../../.dfx/local/canisters/bot-agent-backend/service.did.js";
import { createTestEnvironment, generateTestPrincipal } from "./setup.ts";
import { expectErr } from "./helpers.ts";

describe("Admin Management", () => {
  let pic: PocketIc;
  let actor: Actor<_SERVICE>;

  beforeEach(async () => {
    const testEnv = await createTestEnvironment();
    pic = testEnv.pic;
    actor = testEnv.actor;
  });

  afterEach(async () => {
    await pic.tearDown();
  });

  describe("add_admin", () => {
    it("should reject anonymous users from adding admins", async () => {
      // caller will be anonymous
      actor.setPrincipal(Principal.anonymous());

      const newAdminPrincipal = generateTestPrincipal(1);
      const result = await actor.addAdmin(newAdminPrincipal);
      expect(expectErr(result)).toEqual("Anonymous users cannot be admins");
    });

    it("should reject duplicate admin addition attempts", async () => {
      const samePrincipal = generateTestPrincipal(2);

      // caller will be a non-anonymous principal
      actor.setIdentity(generateRandomIdentity());

      // add first admin
      await actor.addAdmin(samePrincipal);

      // Second call should fail due to being duplicate
      const result = await actor.addAdmin(samePrincipal);
      expect(expectErr(result)).toEqual("Principal is already an admin");
    });
  });

  describe("get_admins", () => {
    it("should return an array of admin principals", async () => {
      const somePrincipal = generateTestPrincipal(1);

      // caller will be a non-anonymous principal
      actor.setIdentity(generateRandomIdentity());

      // add first admin
      await actor.addAdmin(somePrincipal);

      const adminsList = await actor.getAdmins();
      expect(adminsList[1]).toEqual(somePrincipal);
    });
  });

  describe("is_caller_admin", () => {
    it("should return false for non-admin caller", async () => {
      // Without setting up as admin, caller should not be admin
      const isAdmin = await actor.isCallerAdmin();
      expect(isAdmin).toBe(false);
    });

    it("should return true for admin caller", async () => {
      const identity = generateRandomIdentity();
      const principalOfIdentity = identity.getPrincipal();

      // Set the caller identity
      actor.setIdentity(identity);

      // Add the caller as admin
      await actor.addAdmin(principalOfIdentity);

      // Now check if caller is admin
      const isAdmin = await actor.isCallerAdmin();
      expect(isAdmin).toBe(true);
    });
  });
});
