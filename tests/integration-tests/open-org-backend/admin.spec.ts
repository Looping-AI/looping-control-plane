import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import { generateRandomIdentity } from "@dfinity/pic";
import { Principal } from "@dfinity/principal";
import {
  createTestEnvironment,
  generateTestPrincipal,
  type _SERVICE,
} from "../../setup.ts";
import { expectErr } from "../../helpers.ts";

describe("Admin Management", () => {
  let pic: PocketIc;
  let actor: Actor<_SERVICE>;
  let ownerIdentity: ReturnType<typeof generateRandomIdentity>;

  beforeEach(async () => {
    const testEnv = await createTestEnvironment();
    pic = testEnv.pic;
    actor = testEnv.actor;
    ownerIdentity = testEnv.ownerIdentity;
  });

  afterEach(async () => {
    await pic.tearDown();
  });

  describe("add_admin", () => {
    it("should reject non-owner from adding admins", async () => {
      // Set caller to non-owner principal
      actor.setIdentity(generateRandomIdentity());

      const newAdminPrincipal = generateTestPrincipal(1);
      const result = await actor.addOrgAdmin(newAdminPrincipal);
      expect(expectErr(result)).toEqual("Only the owner can add admins");
    });

    it("should reject duplicate admin addition attempts", async () => {
      const samePrincipal = generateTestPrincipal(2);

      // Owner should be able to add
      await actor.addOrgAdmin(samePrincipal);

      // Second call should fail due to being duplicate
      const result = await actor.addOrgAdmin(samePrincipal);
      expect(expectErr(result)).toEqual("Principal is already an admin");
    });
  });

  describe("get_admins", () => {
    it("should return an array of admin principals including the owner", async () => {
      const somePrincipal = generateTestPrincipal(1);

      // Owner adds a new admin
      await actor.addOrgAdmin(somePrincipal);

      const adminsList = await actor.getOrgAdmins();
      // Owner should be at index 0, newly added admin at index 1
      expect(adminsList[0]).toEqual(ownerIdentity.getPrincipal());
      expect(adminsList[1]).toEqual(somePrincipal);
    });
  });

  describe("is_caller_admin", () => {
    it("should return false for non-admin caller", async () => {
      // Set caller to non-admin
      actor.setIdentity(generateRandomIdentity());

      const isAdmin = await actor.isCallerOrgAdmin();
      expect(isAdmin).toBe(false);
    });

    it("should return true for owner caller", async () => {
      // Owner should be admin
      const isAdmin = await actor.isCallerOrgAdmin();
      expect(isAdmin).toBe(true);
    });

    it("should return true for added admin caller", async () => {
      const identity = generateRandomIdentity();
      const principalOfIdentity = identity.getPrincipal();

      // Owner adds the caller as admin
      await actor.addOrgAdmin(principalOfIdentity);

      // Set the caller identity
      actor.setIdentity(identity);

      // Now check if caller is admin
      const isAdmin = await actor.isCallerOrgAdmin();
      expect(isAdmin).toBe(true);
    });
  });

  describe("addWorkspaceAdmin", () => {
    it("should allow owner to add workspace admin", async () => {
      const newAdminPrincipal = generateTestPrincipal(1);
      const workspaceId = 0n; // Default workspace

      const result = await actor.addWorkspaceAdmin(
        workspaceId,
        newAdminPrincipal,
      );
      expect(result).toEqual({ ok: null });
    });

    it("should allow existing workspace admin to add another workspace admin", async () => {
      const adminIdentity = generateRandomIdentity();
      const adminPrincipal = adminIdentity.getPrincipal();
      const newAdminPrincipal = generateTestPrincipal(1);
      const workspaceId = 0n; // Default workspace

      // Owner adds first admin
      await actor.addWorkspaceAdmin(workspaceId, adminPrincipal);

      // Switch to the first admin's identity
      actor.setIdentity(adminIdentity);

      // First admin adds second admin
      const result = await actor.addWorkspaceAdmin(
        workspaceId,
        newAdminPrincipal,
      );
      expect(result).toEqual({ ok: null });
    });

    it("should reject non-admin from adding workspace admins", async () => {
      const nonAdminIdentity = generateRandomIdentity();
      const newAdminPrincipal = generateTestPrincipal(1);
      const workspaceId = 0n; // Default workspace

      // Switch to non-admin identity
      actor.setIdentity(nonAdminIdentity);

      const result = await actor.addWorkspaceAdmin(
        workspaceId,
        newAdminPrincipal,
      );
      expect(expectErr(result)).toEqual(
        "Only the owner or workspace admins can add workspace admins",
      );
    });

    it("should reject anonymous principal as workspace admin", async () => {
      const workspaceId = 0n; // Default workspace

      // Create the anonymous principal
      const anonymousPrincipal = Principal.fromText("2vxsx-fae");

      const result = await actor.addWorkspaceAdmin(
        workspaceId,
        anonymousPrincipal,
      );
      expect(expectErr(result)).toEqual("Anonymous users cannot be admins");
    });

    it("should reject duplicate workspace admin addition", async () => {
      const adminPrincipal = generateTestPrincipal(1);
      const workspaceId = 0n; // Default workspace

      // Add admin first time
      await actor.addWorkspaceAdmin(workspaceId, adminPrincipal);

      // Try to add same admin again
      const result = await actor.addWorkspaceAdmin(workspaceId, adminPrincipal);
      expect(expectErr(result)).toEqual(
        "Principal is already a workspace admin",
      );
    });

    it("should reject adding admin to non-existent workspace", async () => {
      const newAdminPrincipal = generateTestPrincipal(1);
      const nonExistentWorkspaceId = 999n;

      const result = await actor.addWorkspaceAdmin(
        nonExistentWorkspaceId,
        newAdminPrincipal,
      );
      expect(expectErr(result)).toEqual("Workspace not found");
    });
  });
});
