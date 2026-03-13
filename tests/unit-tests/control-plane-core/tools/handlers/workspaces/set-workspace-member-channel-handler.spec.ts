import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor, DeferredActor } from "@dfinity/pic";
import {
  createTestCanister,
  createDeferredTestCanister,
  type TestCanisterService,
  SLACK_TEST_TOKEN,
} from "../../../../../setup";
import { withCassette } from "../../../../../lib/cassette";
import { resolveSpecsChannelForInfo } from "../../../../../helpers";

// ============================================
// SetWorkspaceMemberChannelHandler Unit Tests
//
// This handler:
//   1. Parses JSON args for workspaceId + channelId
//   2. Authorizes the caller via UserAuthContext
//   3. Verifies the channel exists and the bot has access (conversations.info)
//   4. Persists the member channel anchor in workspace state
//
// Tests are split into two groups:
//   (A) Fast-fail tests — fail before any HTTP call, use regular actor.
//   (B) Cassette tests — the handler calls conversations.info, so we use a
//       deferred actor + cassette to record/replay the Slack HTTP response.
//
// Pre-seeded test workspace state (from test-canister.mo):
//   Workspace 0: Default (no channel anchors)
//   Workspace 1: adminChannelId = C_ADMIN_CHANNEL, memberChannelId = C_MEMBER_CHANNEL
//   Workspace 2: adminChannelId = C_ROUND_TRIP_ADMIN, memberChannelId = C_ROUND_TRIP_MEMBER
// ============================================

const CASSETTE_BASE =
  "unit-tests/control-plane-core/tools/handlers/set-workspace-member-channel-handler";

function parseResponse(json: string): {
  success: boolean;
  error?: string;
  message?: string;
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

function workspaceAdmin(wsId: bigint) {
  return {
    isPrimaryOwner: false,
    isOrgAdmin: false,
    workspaceAdminFor: [wsId] as [bigint],
  };
}

// ============================================
// (A) Fast-fail tests — no HTTP outcall required
// ============================================

describe("SetWorkspaceMemberChannelHandler — fast-fail paths", () => {
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
    it("should return error for invalid JSON args", async () => {
      const result = await testCanister.testSetWorkspaceMemberChannelHandler(
        "not-valid-json",
        "xoxb-fake",
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Failed to parse arguments");
    });

    it("should return error when workspaceId is missing", async () => {
      const result = await testCanister.testSetWorkspaceMemberChannelHandler(
        JSON.stringify({ channelId: "C123" }),
        "xoxb-fake",
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Missing required fields");
    });

    it("should return error when channelId is missing", async () => {
      const result = await testCanister.testSetWorkspaceMemberChannelHandler(
        JSON.stringify({ workspaceId: 1 }),
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
      const result = await testCanister.testSetWorkspaceMemberChannelHandler(
        JSON.stringify({ workspaceId: 1, channelId: "C123" }),
        "xoxb-fake",
        NO_AUTH,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Unauthorized");
    });

    it("should return error when workspace admin for ws2 tries to configure workspace 1", async () => {
      const result = await testCanister.testSetWorkspaceMemberChannelHandler(
        JSON.stringify({ workspaceId: 1, channelId: "C123" }),
        "xoxb-fake",
        workspaceAdmin(2n),
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
// Re-record with:
//   RECORD_CASSETTES=true bun test .../set-workspace-member-channel-handler.spec.ts
// ============================================

describe("SetWorkspaceMemberChannelHandler — channel verification (cassette)", () => {
  let pic: PocketIc;
  let testCanister: DeferredActor<TestCanisterService>;

  beforeEach(async () => {
    const testEnv = await createDeferredTestCanister();
    pic = testEnv.pic;
    testCanister = testEnv.actor;
  });

  afterEach(async () => {
    await pic.tearDown();
  });

  it("should verify channel and set member channel for workspace 1 (org admin)", async () => {
    const cassetteKey = `${CASSETTE_BASE}/set-member-channel-ws1`;
    const channelId = await resolveSpecsChannelForInfo(cassetteKey);

    const { result } = await withCassette(
      pic,
      cassetteKey,
      () =>
        testCanister.testSetWorkspaceMemberChannelHandler(
          JSON.stringify({ workspaceId: 1, channelId }),
          SLACK_TEST_TOKEN,
          ORG_ADMIN,
        ),
      { ticks: 5, maxRounds: 2 },
    );

    const response = parseResponse(await result);
    expect(response.success).toBe(true);
    expect(response.message).toContain(channelId);
    expect(response.message).toContain("workspace 1");
  });

  it("should return error when Slack cannot verify the channel", async () => {
    const cassetteKey = `${CASSETTE_BASE}/channel-not-accessible`;

    const { result } = await withCassette(
      pic,
      cassetteKey,
      () =>
        testCanister.testSetWorkspaceMemberChannelHandler(
          JSON.stringify({ workspaceId: 1, channelId: "CNOACCESS0" }),
          SLACK_TEST_TOKEN,
          ORG_ADMIN,
        ),
      { ticks: 5, maxRounds: 2 },
    );

    const response = parseResponse(await result);
    expect(response.success).toBe(false);
    expect(response.error).toContain("Could not verify channel");
    expect(response.error).toContain("CNOACCESS0");
  });
});
