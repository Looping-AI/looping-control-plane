import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import { generateRandomIdentity } from "@dfinity/pic";
import { Principal } from "@dfinity/principal";
import {
  createTestEnvironment,
  generateTestPrincipal,
  type _SERVICE,
} from "../../setup.ts";
import { expectErr, expectOk } from "../../helpers.ts";

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
      expect(expectErr(result)).toEqual(
        "Only the owner can perform this action",
      );
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
        "Only workspace admins can perform this action",
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
      expect(expectErr(result)).toEqual("Principal is already an admin");
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

  describe("addWorkspaceMember", () => {
    it("should allow owner to add workspace member", async () => {
      const newMemberPrincipal = generateTestPrincipal(1);
      const workspaceId = 0n; // Default workspace

      const result = await actor.addWorkspaceMember(
        workspaceId,
        newMemberPrincipal,
      );
      expect(result).toEqual({ ok: null });
    });

    it("should allow existing workspace admin to add workspace member", async () => {
      const adminIdentity = generateRandomIdentity();
      const adminPrincipal = adminIdentity.getPrincipal();
      const newMemberPrincipal = generateTestPrincipal(1);
      const workspaceId = 0n; // Default workspace

      // Owner adds admin
      await actor.addWorkspaceAdmin(workspaceId, adminPrincipal);

      // Switch to admin identity
      actor.setIdentity(adminIdentity);

      // Admin adds member
      const result = await actor.addWorkspaceMember(
        workspaceId,
        newMemberPrincipal,
      );
      expect(result).toEqual({ ok: null });
    });

    it("should reject non-admin from adding workspace members", async () => {
      const nonAdminIdentity = generateRandomIdentity();
      const newMemberPrincipal = generateTestPrincipal(1);
      const workspaceId = 0n; // Default workspace

      // Switch to non-admin identity
      actor.setIdentity(nonAdminIdentity);

      const result = await actor.addWorkspaceMember(
        workspaceId,
        newMemberPrincipal,
      );
      expect(expectErr(result)).toEqual(
        "Only workspace admins can perform this action",
      );
    });

    it("should reject anonymous principal as workspace member", async () => {
      const workspaceId = 0n; // Default workspace
      const anonymousPrincipal = Principal.fromText("2vxsx-fae");

      const result = await actor.addWorkspaceMember(
        workspaceId,
        anonymousPrincipal,
      );
      expect(expectErr(result)).toEqual("Anonymous users cannot be members");
    });

    it("should reject duplicate workspace member addition", async () => {
      const memberPrincipal = generateTestPrincipal(1);
      const workspaceId = 0n; // Default workspace

      // Add member first time
      await actor.addWorkspaceMember(workspaceId, memberPrincipal);

      // Try to add same member again
      const result = await actor.addWorkspaceMember(
        workspaceId,
        memberPrincipal,
      );
      expect(expectErr(result)).toEqual("Principal is already a member");
    });

    it("should reject adding member to non-existent workspace", async () => {
      const newMemberPrincipal = generateTestPrincipal(1);
      const nonExistentWorkspaceId = 999n;

      const result = await actor.addWorkspaceMember(
        nonExistentWorkspaceId,
        newMemberPrincipal,
      );
      expect(expectErr(result)).toEqual("Workspace not found");
    });
  });

  describe("getWorkspaceMembers", () => {
    it("should return empty list for workspace with no members when called by admin", async () => {
      const workspaceId = 0n;
      const result = await actor.getWorkspaceMembers(workspaceId);
      const members = expectOk(result);
      expect(members).toEqual([]);
    });

    it("should return an array of member principals after adding members when called by admin", async () => {
      const memberPrincipal1 = generateTestPrincipal(1);
      const memberPrincipal2 = generateTestPrincipal(2);
      const workspaceId = 0n;

      // Add first member
      await actor.addWorkspaceMember(workspaceId, memberPrincipal1);

      // Add second member
      await actor.addWorkspaceMember(workspaceId, memberPrincipal2);

      const result = await actor.getWorkspaceMembers(workspaceId);
      const members = expectOk(result);
      expect(members).toHaveLength(2);
      expect(members[0]).toEqual(memberPrincipal1);
      expect(members[1]).toEqual(memberPrincipal2);
    });

    it("should return error for non-existent workspace", async () => {
      const nonExistentWorkspaceId = 999n;
      const result = await actor.getWorkspaceMembers(nonExistentWorkspaceId);
      expect(expectErr(result)).toEqual("Workspace not found");
    });

    it("should reject non-admin caller", async () => {
      const nonAdminIdentity = generateRandomIdentity();
      actor.setIdentity(nonAdminIdentity);

      const workspaceId = 0n;
      const result = await actor.getWorkspaceMembers(workspaceId);
      expect(expectErr(result)).toEqual(
        "Only workspace admins can perform this action",
      );
    });

    it("should reject anonymous caller", async () => {
      const anonymousIdentity = generateRandomIdentity();
      anonymousIdentity.getPrincipal = () => Principal.anonymous();
      actor.setIdentity(anonymousIdentity);

      const workspaceId = 0n;
      const result = await actor.getWorkspaceMembers(workspaceId);
      expect(expectErr(result)).toEqual(
        "Please login before calling this function",
      );
    });
  });

  describe("isCallerWorkspaceMember", () => {
    it("should return false for non-member caller", async () => {
      const nonMemberIdentity = generateRandomIdentity();
      const workspaceId = 0n;

      actor.setIdentity(nonMemberIdentity);
      const isMember = await actor.isCallerWorkspaceMember(workspaceId);
      expect(isMember).toBe(false);
    });

    it("should return true for member caller", async () => {
      const memberIdentity = generateRandomIdentity();
      const memberPrincipal = memberIdentity.getPrincipal();
      const workspaceId = 0n;

      // Owner adds the caller as member
      await actor.addWorkspaceMember(workspaceId, memberPrincipal);

      // Set caller identity
      actor.setIdentity(memberIdentity);

      const isMember = await actor.isCallerWorkspaceMember(workspaceId);
      expect(isMember).toBe(true);
    });

    it("should return false for member in non-existent workspace", async () => {
      const memberIdentity = generateRandomIdentity();
      const nonExistentWorkspaceId = 999n;

      actor.setIdentity(memberIdentity);
      const isMember = await actor.isCallerWorkspaceMember(
        nonExistentWorkspaceId,
      );
      expect(isMember).toBe(false);
    });
  });
});
