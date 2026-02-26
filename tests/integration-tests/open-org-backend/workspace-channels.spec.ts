import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import { generateRandomIdentity } from "@dfinity/pic";
import { createTestEnvironment, type _SERVICE } from "../../setup.ts";
import { expectOk, expectErr, expectSome, expectNone } from "../../helpers.ts";

describe("Workspace Channel Anchors (Phase 0.5)", () => {
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

  // ---------------------------------------------------------------------------
  // listWorkspaces / getWorkspace — default workspace 0
  // ---------------------------------------------------------------------------

  describe("default workspace", () => {
    it("should list the pre-seeded default workspace", async () => {
      const result = await actor.listWorkspaces();
      const list = expectOk(result);
      expect(list).toHaveLength(1);
      expect(list[0].id).toEqual(0n);
      expect(list[0].name).toEqual("Default");
      expect(list[0].adminChannelId).toEqual([]); // null → [] in Candid
      expect(list[0].memberChannelId).toEqual([]);
    });

    it("should return default workspace by ID", async () => {
      const result = await actor.getWorkspace(0n);
      const record = expectSome(expectOk(result));
      expect(record.id).toEqual(0n);
      expect(record.name).toEqual("Default");
    });

    it("should return null for non-existent workspace ID", async () => {
      const result = await actor.getWorkspace(999n);
      expectNone(expectOk(result));
    });
  });

  // ---------------------------------------------------------------------------
  // createWorkspace
  // ---------------------------------------------------------------------------

  describe("createWorkspace", () => {
    it("should reject non-admin caller", async () => {
      actor.setIdentity(generateRandomIdentity());
      const result = await actor.createWorkspace("Engineering");
      expect(expectErr(result)).toContain("Only org owner, org admins");
    });

    it("should reject empty name", async () => {
      const result = await actor.createWorkspace("");
      expect(expectErr(result)).toEqual("Workspace name cannot be empty.");
    });

    it("should create a new workspace with incremental ID", async () => {
      const result = await actor.createWorkspace("Engineering");
      expect(expectOk(result)).toEqual(1n);
    });

    it("should create multiple workspaces with consecutive IDs", async () => {
      const id1 = expectOk(await actor.createWorkspace("Engineering"));
      const id2 = expectOk(await actor.createWorkspace("Marketing"));
      expect(id1).toEqual(1n);
      expect(id2).toEqual(2n);
    });

    it("should appear in listWorkspaces after creation", async () => {
      await actor.createWorkspace("Engineering");
      const result = await actor.listWorkspaces();
      const list = expectOk(result);
      expect(list).toHaveLength(2);
      const names = list.map((w) => w.name).sort();
      expect(names).toEqual(["Default", "Engineering"]);
    });

    it("org admin (non-owner) can create workspace", async () => {
      const adminIdentity = generateRandomIdentity();
      await actor.addOrgAdmin(adminIdentity.getPrincipal());
      actor.setIdentity(adminIdentity);
      const result = await actor.createWorkspace("Engineering");
      expect(expectOk(result)).toEqual(1n);
    });

    it("should reject duplicate workspace name", async () => {
      await actor.createWorkspace("Engineering");
      const result = await actor.createWorkspace("Engineering");
      expect(expectErr(result)).toEqual(
        "A workspace with this name already exists.",
      );
    });
  });

  // ---------------------------------------------------------------------------
  // setWorkspaceAdminChannel / setWorkspaceMemberChannel
  // ---------------------------------------------------------------------------

  describe("setWorkspaceAdminChannel", () => {
    it("should reject non-admin caller", async () => {
      actor.setIdentity(generateRandomIdentity());
      const result = await actor.setWorkspaceAdminChannel(0n, "C12345");
      expect(expectErr(result)).toContain("Only org owner");
    });

    it("should reject unknown workspace ID", async () => {
      const result = await actor.setWorkspaceAdminChannel(999n, "C12345");
      expect(expectErr(result)).toEqual("Workspace not found.");
    });

    it("should set admin channel for default workspace", async () => {
      const setResult = await actor.setWorkspaceAdminChannel(0n, "C_ADMIN_1");
      expect(setResult).toEqual({ ok: null });

      const ws = expectSome(expectOk(await actor.getWorkspace(0n)));
      expect(expectSome(ws.adminChannelId)).toEqual("C_ADMIN_1");
    });

    it("should overwrite an existing admin channel", async () => {
      await actor.setWorkspaceAdminChannel(0n, "C_OLD");
      await actor.setWorkspaceAdminChannel(0n, "C_NEW");

      const ws = expectSome(expectOk(await actor.getWorkspace(0n)));
      expect(expectSome(ws.adminChannelId)).toEqual("C_NEW");
    });

    it("existing workspace admin can set admin channel", async () => {
      const adminIdentity = generateRandomIdentity();
      await actor.addWorkspaceAdmin(0n, adminIdentity.getPrincipal());
      actor.setIdentity(adminIdentity);

      const result = await actor.setWorkspaceAdminChannel(0n, "C_ADMIN_2");
      expect(result).toEqual({ ok: null });
    });
  });

  describe("setWorkspaceMemberChannel", () => {
    it("should reject non-admin caller", async () => {
      actor.setIdentity(generateRandomIdentity());
      const result = await actor.setWorkspaceMemberChannel(0n, "C12345");
      expect(expectErr(result)).toContain("Only org owner");
    });

    it("should reject unknown workspace ID", async () => {
      const result = await actor.setWorkspaceMemberChannel(999n, "C12345");
      expect(expectErr(result)).toEqual("Workspace not found.");
    });

    it("should set member channel for default workspace", async () => {
      const setResult = await actor.setWorkspaceMemberChannel(0n, "C_MEMBER_1");
      expect(setResult).toEqual({ ok: null });

      const ws = expectSome(expectOk(await actor.getWorkspace(0n)));
      expect(expectSome(ws.memberChannelId)).toEqual("C_MEMBER_1");
    });

    it("should not affect the admin channel when setting member channel", async () => {
      await actor.setWorkspaceAdminChannel(0n, "C_ADMIN_1");
      await actor.setWorkspaceMemberChannel(0n, "C_MEMBER_1");

      const ws = expectSome(expectOk(await actor.getWorkspace(0n)));
      expect(expectSome(ws.adminChannelId)).toEqual("C_ADMIN_1");
      expect(expectSome(ws.memberChannelId)).toEqual("C_MEMBER_1");
    });
  });

  // ---------------------------------------------------------------------------
  // setOrgAdminChannel / getOrgAdminChannel
  // ---------------------------------------------------------------------------

  describe("setOrgAdminChannel / getOrgAdminChannel", () => {
    it("should return null when no org-admin channel is set", async () => {
      const result = await actor.getOrgAdminChannel();
      expectNone(result);
    });

    it("should reject non-owner from setting org-admin channel", async () => {
      const adminIdentity = generateRandomIdentity();
      await actor.addOrgAdmin(adminIdentity.getPrincipal());
      actor.setIdentity(adminIdentity);

      const result = await actor.setOrgAdminChannel(
        "C_ORG",
        "looping-ai-org-admins",
      );
      expect(expectErr(result)).toContain("Only org owner");
    });

    it("should allow org owner to set org-admin channel", async () => {
      const setResult = await actor.setOrgAdminChannel(
        "C_ORG_1",
        "looping-ai-org-admins",
      );
      expect(setResult).toEqual({ ok: null });

      const anchor = expectSome(await actor.getOrgAdminChannel());
      expect(anchor.channelId).toEqual("C_ORG_1");
      expect(anchor.channelName).toEqual("looping-ai-org-admins");
    });

    it("should overwrite a previously set org-admin channel", async () => {
      await actor.setOrgAdminChannel("C_OLD_ORG", "looping-ai-old");
      await actor.setOrgAdminChannel("C_NEW_ORG", "looping-ai-org-admins");

      const anchor = expectSome(await actor.getOrgAdminChannel());
      expect(anchor.channelId).toEqual("C_NEW_ORG");
      expect(anchor.channelName).toEqual("looping-ai-org-admins");
    });
  });

  // ---------------------------------------------------------------------------
  // createWorkspace seeds all per-workspace maps correctly
  // ---------------------------------------------------------------------------

  describe("createWorkspace seeds all per-workspace maps", () => {
    it("agents endpoint works on freshly created workspace", async () => {
      const wsId = expectOk(await actor.createWorkspace("Engineering"));

      // Should be able to list agents for new workspace (not return workspace-not-found)
      const listResult = await actor.listAgents(wsId);
      expect(expectOk(listResult)).toEqual([]);
    });

    it("getWorkspaceMembers works on freshly created workspace", async () => {
      const wsId = expectOk(await actor.createWorkspace("Engineering"));
      const result = await actor.getWorkspaceMembers(wsId);
      expect(expectOk(result)).toEqual([]);
    });
  });
});
