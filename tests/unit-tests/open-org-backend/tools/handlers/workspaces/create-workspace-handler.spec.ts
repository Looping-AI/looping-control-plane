import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import {
  createTestCanister,
  type TestCanisterService,
} from "../../../../../setup";

// ============================================
// CreateWorkspaceHandler Unit Tests
//
// This handler:
//   1. Parses JSON args for { name }
//   2. Authorizes the caller via UserAuthContext (#IsPrimaryOwner or #IsOrgAdmin)
//   3. Creates the workspace in WorkspacesState
//
// The test canister is pre-seeded with workspaces 0, 1, and 2 so new workspaces
// start at ID 3.
// ============================================

function parseResponse(json: string): {
  success: boolean;
  id?: number;
  name?: string;
  message?: string;
  error?: string;
} {
  return JSON.parse(json);
}

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

describe("CreateWorkspaceHandler", () => {
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

  describe("argument validation", () => {
    it("should return error for invalid JSON", async () => {
      const result = await testCanister.testCreateWorkspaceHandler(
        "not-valid-json",
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Failed to parse arguments");
    });

    it("should return error when name field is missing", async () => {
      const result = await testCanister.testCreateWorkspaceHandler(
        JSON.stringify({}),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Missing required field: name");
    });

    it("should return error for empty name", async () => {
      const result = await testCanister.testCreateWorkspaceHandler(
        JSON.stringify({ name: "" }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Workspace name cannot be empty");
    });
  });

  describe("authorization", () => {
    it("should return error when caller has no permissions", async () => {
      const result = await testCanister.testCreateWorkspaceHandler(
        JSON.stringify({ name: "Engineering" }),
        NO_AUTH,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Unauthorized");
    });

    it("should allow primary owner to create workspace", async () => {
      const result = await testCanister.testCreateWorkspaceHandler(
        JSON.stringify({ name: "Engineering" }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
    });

    it("should allow org admin to create workspace", async () => {
      const result = await testCanister.testCreateWorkspaceHandler(
        JSON.stringify({ name: "Engineering" }),
        ORG_ADMIN,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
    });
  });

  describe("happy path", () => {
    it("should create workspace and return the new ID", async () => {
      const result = await testCanister.testCreateWorkspaceHandler(
        JSON.stringify({ name: "Engineering" }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.id).toBe(3); // workspaces 0-2 are pre-seeded
      expect(response.name).toBe("Engineering");
    });

    it("should assign consecutive IDs for multiple workspaces", async () => {
      const r1 = parseResponse(
        await testCanister.testCreateWorkspaceHandler(
          JSON.stringify({ name: "Engineering" }),
          PRIMARY_OWNER,
        ),
      );
      const r2 = parseResponse(
        await testCanister.testCreateWorkspaceHandler(
          JSON.stringify({ name: "Marketing" }),
          PRIMARY_OWNER,
        ),
      );
      expect(r1.id).toBe(3);
      expect(r2.id).toBe(4);
    });

    it("newly created workspace should appear in list", async () => {
      await testCanister.testCreateWorkspaceHandler(
        JSON.stringify({ name: "Engineering" }),
        PRIMARY_OWNER,
      );
      const listResult = await testCanister.testListWorkspacesHandler("{}");
      const list = JSON.parse(listResult);
      expect(list.success).toBe(true);
      const names = list.workspaces.map((w: { name: string }) => w.name);
      expect(names).toContain("Engineering");
    });

    it("should return error for duplicate workspace name", async () => {
      await testCanister.testCreateWorkspaceHandler(
        JSON.stringify({ name: "Engineering" }),
        PRIMARY_OWNER,
      );
      const result = await testCanister.testCreateWorkspaceHandler(
        JSON.stringify({ name: "Engineering" }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("already exists");
    });
  });
});
