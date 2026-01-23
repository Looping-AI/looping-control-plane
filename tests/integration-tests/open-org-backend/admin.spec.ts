import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { Principal } from "@dfinity/principal";
import type { PocketIc, Actor } from "@dfinity/pic";
import { generateRandomIdentity } from "@dfinity/pic";
import type { _SERVICE } from "../../../.dfx/local/canisters/open-org-backend/service.did.js";
import { createTestEnvironment, generateTestPrincipal } from "../../setup.ts";
import { expectErr } from "../../helpers.ts";

describe("Admin Management", () => {
  let pic: PocketIc;
  let actor: Actor<_SERVICE>;
  let ownerPrincipal: Principal;

  beforeEach(async () => {
    const testEnv = await createTestEnvironment();
    pic = testEnv.pic;
    actor = testEnv.actor;
    ownerPrincipal = testEnv.ownerPrincipal;
  });

  afterEach(async () => {
    await pic.tearDown();
  });

  describe("add_admin", () => {
    it("should reject non-owner from adding admins", async () => {
      // Set caller to non-owner principal
      actor.setIdentity(generateRandomIdentity());

      const newAdminPrincipal = generateTestPrincipal(1);
      const result = await actor.addAdmin(newAdminPrincipal);
      expect(expectErr(result)).toEqual("Only the owner can add admins");
    });

    it("should reject duplicate admin addition attempts", async () => {
      const samePrincipal = generateTestPrincipal(2);

      // Owner should be able to add
      await actor.addAdmin(samePrincipal);

      // Second call should fail due to being duplicate
      const result = await actor.addAdmin(samePrincipal);
      expect(expectErr(result)).toEqual("Principal is already an admin");
    });
  });

  describe("get_admins", () => {
    it("should return an array of admin principals including the owner", async () => {
      const somePrincipal = generateTestPrincipal(1);

      // Owner adds a new admin
      await actor.addAdmin(somePrincipal);

      const adminsList = await actor.getAdmins();
      // Owner should be at index 0, newly added admin at index 1
      expect(adminsList[0]).toEqual(ownerPrincipal);
      expect(adminsList[1]).toEqual(somePrincipal);
    });
  });

  describe("is_caller_admin", () => {
    it("should return false for non-admin caller", async () => {
      // Set caller to non-admin
      actor.setIdentity(generateRandomIdentity());

      const isAdmin = await actor.isCallerAdmin();
      expect(isAdmin).toBe(false);
    });

    it("should return true for owner caller", async () => {
      // Owner should be admin
      const isAdmin = await actor.isCallerAdmin();
      expect(isAdmin).toBe(true);
    });

    it("should return true for added admin caller", async () => {
      const identity = generateRandomIdentity();
      const principalOfIdentity = identity.getPrincipal();

      // Owner adds the caller as admin
      await actor.addAdmin(principalOfIdentity);

      // Set the caller identity
      actor.setIdentity(identity);

      // Now check if caller is admin
      const isAdmin = await actor.isCallerAdmin();
      expect(isAdmin).toBe(true);
    });
  });
});
