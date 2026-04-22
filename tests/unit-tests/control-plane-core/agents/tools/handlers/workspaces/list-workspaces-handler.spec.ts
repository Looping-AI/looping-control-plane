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
  type TestCanisterService,
  freshTestCanister,
} from "../../../../../../setup";

// ============================================
// ListWorkspacesHandler Unit Tests
//
// This handler reads from WorkspacesState and returns all workspace records as JSON.
// The test canister is pre-seeded with three workspaces:
//   Workspace 0: Default (no channel anchors)
//   Workspace 1: adminChannelId = C_ADMIN_CHANNEL
//   Workspace 2: adminChannelId = C_ROUND_TRIP_ADMIN
// ============================================

function parseResponse(json: string): {
  success: boolean;
  workspaces?: Array<{
    id: number;
    name: string;
    adminChannelId: string | null;
  }>;
  error?: string;
} {
  return JSON.parse(json);
}

describe("ListWorkspacesHandler", () => {
  let pic: PocketIc;
  let testCanister: Actor<TestCanisterService>;

  beforeAll(async () => {
    const testEnv = await createTestCanister();
    pic = testEnv.pic;
  });

  beforeEach(async () => {
    testCanister = (await freshTestCanister(pic)).actor;
  });

  afterAll(async () => {
    await pic.tearDown();
  });

  it("should return all pre-seeded workspaces", async () => {
    const result = await testCanister.testListWorkspacesHandler("{}");
    const response = parseResponse(result);
    expect(response.success).toBe(true);
    expect(response.workspaces).toHaveLength(3);
  });

  it("should include workspace 0 with name 'Default' and no channel anchors", async () => {
    const result = await testCanister.testListWorkspacesHandler("{}");
    const response = parseResponse(result);
    const ws0 = response.workspaces!.find((w) => w.id === 0);
    expect(ws0).toBeDefined();
    expect(ws0!.name).toBe("Default");
    expect(ws0!.adminChannelId).toBeNull();
  });

  it("should include workspace 1 with correct channel anchors", async () => {
    const result = await testCanister.testListWorkspacesHandler("{}");
    const response = parseResponse(result);
    const ws1 = response.workspaces!.find((w) => w.id === 1);
    expect(ws1).toBeDefined();
    expect(ws1!.name).toBe("Test Workspace 1");
    expect(ws1!.adminChannelId).toBe("C_ADMIN_CHANNEL");
  });

  it("should include workspace 2 with correct channel anchors", async () => {
    const result = await testCanister.testListWorkspacesHandler("{}");
    const response = parseResponse(result);
    const ws2 = response.workspaces!.find((w) => w.id === 2);
    expect(ws2).toBeDefined();
    expect(ws2!.name).toBe("Test Workspace 2");
    expect(ws2!.adminChannelId).toBe("C_ROUND_TRIP_ADMIN");
  });
});
