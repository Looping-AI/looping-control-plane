import {
  afterAll,
  beforeAll,
  beforeEach,
  describe,
  expect,
  it,
} from "bun:test";
import type { PocketIc, Actor, DeferredActor } from "@dfinity/pic";
import {
  createTestCanister,
  createDeferredTestCanister,
  freshTestCanister,
  freshDeferredTestCanister,
  type TestCanisterService,
  SLACK_TEST_TOKEN,
} from "../../../../../setup";
import { withCassette } from "../../../../../lib/cassette";
import { resolveSpecsChannelForInfo } from "../../../../../helpers";

// ============================================
// CreateWorkspaceHandler Unit Tests
//
// This handler:
//   1. Parses JSON args for { name, channelId }
//   2. Authorizes the caller via UserAuthContext (#IsPrimaryOwner or #IsOrgAdmin)
//   3. Verifies the channelId exists and the bot has access (conversations.info)
//   4. Creates the workspace in WorkspacesState
//   5. Sets the admin channel anchor
//   6. Registers an #admin agent with the real channel ID
//
// Tests are split into two groups:
//   (A) Fast-fail tests — fail before any HTTP call (bad JSON, auth, missing fields).
//   (B) Cassette tests — the handler calls conversations.info, so we use a
//       deferred actor + cassette to record/replay the Slack HTTP response.
//
// The test canister is pre-seeded with workspaces 0, 1, and 2 so new workspaces
// start at ID 3.
// ============================================

const CASSETTE_BASE =
  "unit-tests/control-plane-core/tools/handlers/create-workspace-handler";

function parseResponse(json: string): {
  success: boolean;
  id?: number;
  name?: string;
  adminChannelId?: string;
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

// ============================================
// (A) Fast-fail tests — no HTTP outcall required
// ============================================

describe("CreateWorkspaceHandler — fast-fail paths", () => {
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
      const result = await testCanister.testCreateWorkspaceHandler(
        "not-valid-json",
        "xoxb-fake",
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Failed to parse arguments");
    });

    it("should return error when both name and channelId are missing", async () => {
      const result = await testCanister.testCreateWorkspaceHandler(
        JSON.stringify({}),
        "xoxb-fake",
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Missing required fields");
    });

    it("should return error when channelId is missing", async () => {
      const result = await testCanister.testCreateWorkspaceHandler(
        JSON.stringify({ name: "Engineering" }),
        "xoxb-fake",
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Missing required fields");
    });

    it("should return error when name is missing", async () => {
      const result = await testCanister.testCreateWorkspaceHandler(
        JSON.stringify({ channelId: "C123" }),
        "xoxb-fake",
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Missing required fields");
    });
  });

  describe("authorization", () => {
    it("should return error when caller has no permissions", async () => {
      const result = await testCanister.testCreateWorkspaceHandler(
        JSON.stringify({ name: "Engineering", channelId: "C123" }),
        "xoxb-fake",
        NO_AUTH,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Unauthorized");
    });
  });
});

// ============================================
// (B) Cassette tests — conversations.info HTTP outcall involved
//
// Cassettes are pre-seeded with deterministic fake Slack responses so tests
// run immediately in CI without a live Slack connection. Re-record with:
//   RECORD_CASSETTES=true bun test .../create-workspace-handler.spec.ts
// ============================================

describe("CreateWorkspaceHandler — channel verification (cassette)", () => {
  let pic: PocketIc;
  let testCanister: DeferredActor<TestCanisterService>;

  beforeAll(async () => {
    pic = (await createDeferredTestCanister()).pic;
  });

  beforeEach(async () => {
    testCanister = (await freshDeferredTestCanister(pic)).actor;
  });

  afterAll(async () => {
    await pic.tearDown();
  });

  it("should verify channel, create workspace, and return the new ID (primary owner)", async () => {
    const cassetteKey = `${CASSETTE_BASE}/create-workspace-primary-owner`;
    const channelId = await resolveSpecsChannelForInfo(cassetteKey);

    const { result } = await withCassette(
      pic,
      cassetteKey,
      () =>
        testCanister.testCreateWorkspaceHandler(
          JSON.stringify({ name: "Engineering", channelId }),
          SLACK_TEST_TOKEN,
          PRIMARY_OWNER,
        ),
      { ticks: 5, maxRounds: 2 },
    );

    const response = parseResponse(await result);
    expect(response.success).toBe(true);
    expect(response.id).toBe(3); // workspaces 0-2 are pre-seeded
    expect(response.name).toBe("Engineering");
    expect(response.adminChannelId).toBe(channelId);
  });

  it("should verify channel, create workspace, and return the new ID (org admin)", async () => {
    const cassetteKey = `${CASSETTE_BASE}/create-workspace-org-admin`;
    const channelId = await resolveSpecsChannelForInfo(cassetteKey);

    const { result } = await withCassette(
      pic,
      cassetteKey,
      () =>
        testCanister.testCreateWorkspaceHandler(
          JSON.stringify({ name: "Marketing", channelId }),
          SLACK_TEST_TOKEN,
          ORG_ADMIN,
        ),
      { ticks: 5, maxRounds: 2 },
    );

    const response = parseResponse(await result);
    expect(response.success).toBe(true);
    expect(response.name).toBe("Marketing");
    expect(response.adminChannelId).toBe(channelId);
  });

  it("should appear in ListWorkspacesHandler results after creation", async () => {
    const cassetteKey = `${CASSETTE_BASE}/create-workspace-primary-owner`;
    const channelId = await resolveSpecsChannelForInfo(cassetteKey);

    const { result } = await withCassette(
      pic,
      cassetteKey,
      () =>
        testCanister.testCreateWorkspaceHandler(
          JSON.stringify({ name: "Engineering", channelId }),
          SLACK_TEST_TOKEN,
          PRIMARY_OWNER,
        ),
      { ticks: 5, maxRounds: 2 },
    );

    const createResponse = parseResponse(await result);
    expect(createResponse.success).toBe(true);
    const newId = createResponse.id!;

    // Verify the newly created workspace is returned by ListWorkspacesHandler
    const executeList = await testCanister.testListWorkspacesHandler("{}");
    await pic.tick(2);
    const listResult = await executeList();
    const listResponse = JSON.parse(listResult) as {
      success: boolean;
      workspaces: Array<{
        id: number;
        name: string;
        adminChannelId: string | null;
      }>;
    };

    expect(listResponse.success).toBe(true);
    expect(
      listResponse.workspaces.some(
        (w) => w.id === newId && w.name === "Engineering",
      ),
    ).toBe(true);
  });

  it("should return error when Slack cannot verify the channel", async () => {
    const cassetteKey = `${CASSETTE_BASE}/channel-not-accessible`;

    const { result } = await withCassette(
      pic,
      cassetteKey,
      () =>
        testCanister.testCreateWorkspaceHandler(
          JSON.stringify({ name: "Engineering", channelId: "CNOACCESS0" }),
          SLACK_TEST_TOKEN,
          PRIMARY_OWNER,
        ),
      { ticks: 5, maxRounds: 2 },
    );

    const response = parseResponse(await result);
    expect(response.success).toBe(false);
    expect(response.error).toContain("Could not verify channel");
    expect(response.error).toContain("CNOACCESS0");
  });
});
