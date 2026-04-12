import {
  afterAll,
  beforeAll,
  beforeEach,
  describe,
  expect,
  it,
} from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import {
  createTestCanister,
  freshTestCanister,
  type TestCanisterService,
} from "../../../../../setup";

// ============================================
// DeleteWorkspaceHandler Unit Tests
//
// This handler (synchronous — no HTTP outcall):
//   1. Parses JSON args for { workspaceId }
//   2. Authorizes the caller via UserAuthContext (#IsPrimaryOwner or #IsOrgAdmin).
//      Workspace admins are NOT allowed — workspace deletion is an org-level action.
//   3. Rejects deletion of workspace 0 (the protected org workspace)
//   4. Validates the triggerMessageText (the verbatim text of the Slack message that
//      triggered this turn) against the expected confirmation phrase "::admin <name>".
//      This value is sourced from channel history — the LLM cannot fabricate it.
//      This is the beginning of the approvals system.
//   5. Removes the workspace record from state
//   6. Unregisters the workspace's admin agent from the agent registry (if present)
//
// The test canister is pre-seeded with workspaces 0 (Default), 1 (Test Workspace 1),
// and 2 (Test Workspace 2).
//
// testDeleteWorkspaceHandler(args, triggerMessageText, auth)
//   triggerMessageText: [] = no message (null), ["::admin Foo"] = user typed that phrase
// ============================================

function parseResponse(json: string): {
  success: boolean;
  id?: number;
  message?: string;
  error?: string;
} {
  return JSON.parse(json);
}

const NO_TRIGGER = [] as [] | [string];
const TRIGGER_WS1 = ["::admin Test Workspace 1"] as [] | [string];
const TRIGGER_WS2 = ["::admin Test Workspace 2"] as [] | [string];
const TRIGGER_WRONG = ["::admin WrongName"] as [] | [string];

const NO_AUTH = {
  isPrimaryOwner: false,
  isOrgAdmin: false,
  workspaceAdminFor: [] as [] | [bigint],
};

const PRIMARY_OWNER = {
  isPrimaryOwner: true,
  isOrgAdmin: false,
  workspaceAdminFor: [] as [] | [bigint],
};

const ORG_ADMIN = {
  isPrimaryOwner: false,
  isOrgAdmin: true,
  workspaceAdminFor: [] as [] | [bigint],
};

function workspaceAdmin(wsId: bigint) {
  return {
    isPrimaryOwner: false,
    isOrgAdmin: false,
    workspaceAdminFor: [wsId] as [] | [bigint],
  };
}

describe("DeleteWorkspaceHandler", () => {
  let pic: PocketIc;
  let testCanister: Actor<TestCanisterService>;

  beforeAll(async () => {
    pic = (await createTestCanister()).pic;
  });

  beforeEach(async () => {
    testCanister = (await freshTestCanister(pic)).actor;
  });

  afterAll(async () => {
    await pic.tearDown();
  });

  describe("argument validation", () => {
    it("should return error for invalid JSON", async () => {
      const result = await testCanister.testDeleteWorkspaceHandler(
        "not-valid-json",
        TRIGGER_WS1,
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Failed to parse arguments");
    });

    it("should return error when workspaceId is missing", async () => {
      const result = await testCanister.testDeleteWorkspaceHandler(
        JSON.stringify({}),
        TRIGGER_WS1,
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Missing required field");
    });

    it("should return error when workspaceId is negative", async () => {
      const result = await testCanister.testDeleteWorkspaceHandler(
        JSON.stringify({ workspaceId: -1 }),
        TRIGGER_WS1,
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Missing required field");
    });

    it("should return error when deleting workspace 0 (protected)", async () => {
      const result = await testCanister.testDeleteWorkspaceHandler(
        JSON.stringify({ workspaceId: 0 }),
        TRIGGER_WS1,
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Workspace 0");
      expect(response.error).toContain("cannot be deleted");
    });

    it("should return error for non-existent workspace", async () => {
      const result = await testCanister.testDeleteWorkspaceHandler(
        JSON.stringify({ workspaceId: 999 }),
        TRIGGER_WS1,
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("not found");
    });

    it("should return error when no trigger message is available", async () => {
      // No triggerMessageText — the system cannot verify the confirmation
      const result = await testCanister.testDeleteWorkspaceHandler(
        JSON.stringify({ workspaceId: 1 }),
        NO_TRIGGER,
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("::admin Test Workspace 1");
    });

    it("should return error when trigger message does not match expected phrase", async () => {
      // User typed something other than the exact confirmation phrase
      const result = await testCanister.testDeleteWorkspaceHandler(
        JSON.stringify({ workspaceId: 1 }),
        TRIGGER_WRONG,
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("does not match");
      expect(response.error).toContain("::admin Test Workspace 1");
    });
  });

  describe("authorization", () => {
    it("should return error when caller has no permissions", async () => {
      const result = await testCanister.testDeleteWorkspaceHandler(
        JSON.stringify({ workspaceId: 1 }),
        TRIGGER_WS1,
        NO_AUTH,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Unauthorized");
    });

    it("should return error when caller is only a workspace admin (not an org admin)", async () => {
      // Workspace admins must NOT be allowed to delete workspaces
      const result = await testCanister.testDeleteWorkspaceHandler(
        JSON.stringify({ workspaceId: 1 }),
        TRIGGER_WS1,
        workspaceAdmin(1n),
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Unauthorized");
    });
  });

  describe("happy path", () => {
    it("should allow primary owner to delete a workspace", async () => {
      const result = await testCanister.testDeleteWorkspaceHandler(
        JSON.stringify({ workspaceId: 1 }),
        TRIGGER_WS1,
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.id).toBe(1);
    });

    it("should allow org admin to delete a workspace", async () => {
      const result = await testCanister.testDeleteWorkspaceHandler(
        JSON.stringify({ workspaceId: 1 }),
        TRIGGER_WS1,
        ORG_ADMIN,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.id).toBe(1);
    });

    it("should no longer list the workspace after deletion", async () => {
      await testCanister.testDeleteWorkspaceHandler(
        JSON.stringify({ workspaceId: 1 }),
        TRIGGER_WS1,
        PRIMARY_OWNER,
      );
      const listResult = await testCanister.testListWorkspacesHandler("{}");
      const list = JSON.parse(listResult) as {
        success: boolean;
        workspaces: Array<{ id: number }>;
      };
      expect(list.success).toBe(true);
      const ids = list.workspaces.map((w) => w.id);
      expect(ids).not.toContain(1);
    });

    it("should return error when deleting the same workspace a second time", async () => {
      await testCanister.testDeleteWorkspaceHandler(
        JSON.stringify({ workspaceId: 1 }),
        TRIGGER_WS1,
        PRIMARY_OWNER,
      );
      const result = await testCanister.testDeleteWorkspaceHandler(
        JSON.stringify({ workspaceId: 1 }),
        TRIGGER_WS1,
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("not found");
    });

    it("should be able to delete workspace 2 as well", async () => {
      const result = await testCanister.testDeleteWorkspaceHandler(
        JSON.stringify({ workspaceId: 2 }),
        TRIGGER_WS2,
        ORG_ADMIN,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.id).toBe(2);
    });
  });
});
