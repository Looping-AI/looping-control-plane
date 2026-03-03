import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, DeferredActor } from "@dfinity/pic";
import {
  createDeferredTestCanister,
  type TestCanisterService,
  SLACK_TEST_TOKEN,
} from "../../../setup";
import { withCassette } from "../../../lib/cassette";

// ===========================================================================
// Typed helpers for the summary returned by testWeeklyReconciliation.
// (The DID type is inferred from the Motoko source; we assert it here for
// readability and to keep tests self-documenting.)
// ===========================================================================
interface WorkspaceScopeChange {
  slackUserId: string;
  workspaceId: bigint;
  changeType:
    | { adminGranted: null }
    | { adminRevoked: null }
    | { memberGranted: null }
    | { memberRevoked: null };
}

interface ReconciliationSummary {
  usersUpdated: bigint; // newly added or profile-changed users
  orgAdminChannelOk: boolean;
  workspacesChecked: bigint;
  goneChannels: string[];
  errors: string[];
  // Audit fields (Phase 4+)
  orgAdminsGranted: string[];
  orgAdminsRevoked: string[];
  workspaceScopeChanges: WorkspaceScopeChange[];
  staleUsersRemoved: string[];
  logsPurged: bigint;
}

// Candid optional encoding helpers
const none: [] = [];
function some<T>(value: T): [T] {
  return [value];
}

// ---------------------------------------------------------------------------
// Slack mock response builders
// ---------------------------------------------------------------------------

const ORG_ADMIN_CHANNEL_ID = "C_ORG_ADMIN";
const ORG_ADMIN_CHANNEL_NAME = "looping-ai-org-admins";

/** A minimal user that satisfies the Slack users.list shape used by SlackWrapper. */
function slackUsersListResponse(
  members: Array<{
    id: string;
    name: string;
    isPrimaryOwner?: boolean;
    isAdmin?: boolean;
    isBot?: boolean;
    isDeleted?: boolean;
  }>,
  nextCursor = "",
) {
  return {
    ok: true,
    members: members.map((u) => ({
      id: u.id,
      name: u.name,
      is_admin: u.isAdmin ?? false,
      is_owner: u.isPrimaryOwner ?? false,
      is_primary_owner: u.isPrimaryOwner ?? false,
      is_bot: u.isBot ?? false,
      deleted: u.isDeleted ?? false,
    })),
    response_metadata: { next_cursor: nextCursor },
  };
}

/** A minimal conversations.members response. */
function slackChannelMembersResponse(memberIds: string[], nextCursor = "") {
  return {
    ok: true,
    members: memberIds,
    response_metadata: { next_cursor: nextCursor },
  };
}

/** A minimal chat.postMessage success response. */
function slackPostMessageResponse(channelId: string) {
  return { ok: true, channel: channelId, ts: "1234567890.000001" };
}

const slackAuthError = { ok: false, error: "invalid_auth" };
const slackChannelNotFoundError = { ok: false, error: "channel_not_found" };

// ===========================================================================
// Mock-driving helpers
// ===========================================================================

/**
 * Drive a sequence of HTTPS outcall interactions:
 * 1. Tick to let the canister process the initial message.
 * 2. For each expected response, find the first pending outcall, mock it, then
 *    tick again so the canister processes the response and may issue the next call.
 * 3. Resolve the deferred call to get the final result.
 *
 * `call` is the deferred callback returned by `await testCanister.method(...)`.
 */
async function mockSequentialResponses(
  pic: PocketIc,
  call: () => Promise<unknown>,
  responses: object[],
): Promise<unknown> {
  await pic.tick(5);

  for (let i = 0; i < responses.length; i++) {
    const pending = await pic.getPendingHttpsOutcalls();
    if (pending.length === 0) break;

    const { requestId, subnetId } = pending[0];
    await pic.mockPendingHttpsOutcall({
      requestId,
      subnetId,
      response: {
        type: "success",
        statusCode: 200,
        headers: [],
        body: new TextEncoder().encode(JSON.stringify(responses[i])),
      },
    });
    await pic.tick(5);
  }

  // Assert that the canister has no remaining outcalls after all mocked
  // responses have been consumed, to catch cases where it makes more calls
  // than the test expects.
  const remaining = await pic.getPendingHttpsOutcalls();
  if (remaining.length > 0) {
    throw new Error(
      `mockSequentialResponses: ${remaining.length} unexpected pending HTTPS outcall(s) remain after consuming all ${responses.length} mocked responses.`,
    );
  }

  return call();
}

// ===========================================================================
// Tests
// ===========================================================================

describe("Weekly Reconciliation Service Unit Tests", () => {
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

  // Helper: reset and optionally pre-seed the Slack user cache between tests.
  async function resetCache() {
    const reset = await testCanister.resetSlackUserCache();
    await reset();
  }

  async function seedUser(opts: {
    slackUserId: string;
    displayName: string;
    isPrimaryOwner: boolean;
    isOrgAdmin: boolean;
    isBot?: boolean;
  }) {
    const deferred = await testCanister.seedSlackUser(
      opts.slackUserId,
      opts.displayName,
      opts.isPrimaryOwner,
      opts.isOrgAdmin,
      opts.isBot ?? false,
    );
    await deferred();
  }

  async function seedWorkspaceMembership(
    slackUserId: string,
    workspaceId: bigint,
    slot: "admin" | "member",
  ) {
    const slotVariant = slot === "admin" ? { admin: null } : { member: null };
    const deferred = await testCanister.seedWorkspaceMembership(
      slackUserId,
      workspaceId,
      slotVariant as { admin: null } | { member: null },
    );
    await deferred();
  }

  // The test workspace state pre-seeded in test-canister.mo has:
  //   Workspace 0: default — no channel anchors
  //   Workspace 1: adminChannelId = "C_ADMIN_CHANNEL", memberChannelId = "C_MEMBER_CHANNEL"
  //   Workspace 2: adminChannelId = "C_ROUND_TRIP_ADMIN", memberChannelId = "C_ROUND_TRIP_MEMBER"
  //
  // Hence a run without org admin channel triggers exactly 4 workspace channel
  // HTTP calls (ws1-admin, ws1-member, ws2-admin, ws2-member).
  const WORKSPACE_CHANNEL_RESPONSES = [
    slackChannelMembersResponse([]), // ws1 admin channel
    slackChannelMembersResponse([]), // ws1 member channel
    slackChannelMembersResponse([]), // ws2 admin channel
    slackChannelMembersResponse([]), // ws2 member channel
  ];

  // ===========================================================================
  // User Refresh
  // ===========================================================================

  describe("user refresh", () => {
    it("should abort reconciliation when users.list fails", async () => {
      const call = await testCanister.testWeeklyReconciliation(
        "xoxb-invalid",
        none,
        none,
      );

      // Only 1 HTTP call is made before abort; no workspace channel calls follow.
      const result = (await mockSequentialResponses(pic, call, [
        slackAuthError,
      ])) as ReconciliationSummary;

      expect(result.usersUpdated).toBe(0n);
      expect(result.orgAdminChannelOk).toBe(false);
      expect(result.workspacesChecked).toBe(0n);
      expect(result.goneChannels).toHaveLength(0);
      expect(result.errors.length).toBeGreaterThan(0);
      expect(result.errors[0]).toContain("invalid_auth");
    });

    it("should populate the Slack user cache with refreshed users", async () => {
      await resetCache();

      const members = [
        { id: "U_OWNER", name: "owner", isPrimaryOwner: true },
        { id: "U_ADMIN", name: "admin", isAdmin: true },
      ];

      const call = await testCanister.testWeeklyReconciliation(
        SLACK_TEST_TOKEN,
        none,
        none,
      );

      await mockSequentialResponses(pic, call, [
        slackUsersListResponse(members),
        ...WORKSPACE_CHANNEL_RESPONSES,
      ]);

      const getUsers = await testCanister.getSlackUsers();
      const cachedUsers = await getUsers();
      const userMap = new Map(cachedUsers.map((u) => [u.slackUserId, u]));

      expect(userMap.has("U_OWNER")).toBe(true);
      expect(userMap.has("U_ADMIN")).toBe(true);
    });

    it("should report the correct usersUpdated count", async () => {
      await resetCache();

      const members = [
        { id: "U001", name: "alice", isPrimaryOwner: true },
        { id: "U002", name: "bob" },
        { id: "U003", name: "carol" },
      ];

      const call = await testCanister.testWeeklyReconciliation(
        SLACK_TEST_TOKEN,
        none,
        none,
      );

      const result = (await mockSequentialResponses(pic, call, [
        slackUsersListResponse(members),
        ...WORKSPACE_CHANNEL_RESPONSES,
      ])) as ReconciliationSummary;

      expect(result.usersUpdated).toBe(3n);
    });

    it("should preserve an existing user's isOrgAdmin flag during refresh", async () => {
      await resetCache();

      // Seed a user who is already an org admin.
      await seedUser({
        slackUserId: "U_ADMIN",
        displayName: "admin-old",
        isPrimaryOwner: false,
        isOrgAdmin: true,
      });

      // users.list returns the same user — reconciliation must NOT clobber isOrgAdmin.
      const membersFromSlack = [{ id: "U_ADMIN", name: "admin-new" }];

      const call = await testCanister.testWeeklyReconciliation(
        SLACK_TEST_TOKEN,
        none,
        none,
      );

      await mockSequentialResponses(pic, call, [
        slackUsersListResponse(membersFromSlack),
        ...WORKSPACE_CHANNEL_RESPONSES,
      ]);

      const getUserFn = await testCanister.getSlackUser("U_ADMIN");
      const user = await getUserFn();

      expect(user).toHaveLength(1);
      const u = user[0];
      if (!u) throw new Error("Expected user to be defined");
      expect(u.isOrgAdmin).toBe(true);
      // Display name should be updated from Slack.
      expect(u.displayName).toBe("admin-new");
    });

    it("should prune stale users absent from users.list", async () => {
      await resetCache();

      // Seed a user that will disappear from Slack (deactivated / deleted).
      await seedUser({
        slackUserId: "U_STALE",
        displayName: "stale-user",
        isPrimaryOwner: false,
        isOrgAdmin: false,
      });

      // users.list returns nobody — U_STALE is no longer in Slack.
      const call = await testCanister.testWeeklyReconciliation(
        SLACK_TEST_TOKEN,
        none,
        none,
      );
      const result = (await mockSequentialResponses(pic, call, [
        slackUsersListResponse([]), // empty — no current members
        ...WORKSPACE_CHANNEL_RESPONSES,
      ])) as ReconciliationSummary;

      // User must be removed from cache.
      const getUserFn = await testCanister.getSlackUser("U_STALE");
      const user = await getUserFn();
      expect(user).toHaveLength(0);

      // Audit summary must report the removal.
      expect(result.staleUsersRemoved).toContain("U_STALE");
    });

    it("should not upsert users marked as deleted in users.list", async () => {
      await resetCache();

      const call = await testCanister.testWeeklyReconciliation(
        SLACK_TEST_TOKEN,
        none,
        none,
      );
      const result = (await mockSequentialResponses(pic, call, [
        slackUsersListResponse([
          { id: "U_ACTIVE", name: "active" },
          { id: "U_DELETED", name: "deleted-user", isDeleted: true },
        ]),
        ...WORKSPACE_CHANNEL_RESPONSES,
      ])) as ReconciliationSummary;

      // Only the active user should count as updated.
      expect(result.usersUpdated).toBe(1n);

      const getDeletedFn = await testCanister.getSlackUser("U_DELETED");
      const deletedUser = await getDeletedFn();
      expect(deletedUser).toHaveLength(0);

      const getActiveFn = await testCanister.getSlackUser("U_ACTIVE");
      const activeUser = await getActiveFn();
      expect(activeUser).toHaveLength(1);
    });

    it("should set isBot flag when users.list indicates a bot user", async () => {
      await resetCache();

      const call = await testCanister.testWeeklyReconciliation(
        SLACK_TEST_TOKEN,
        none,
        none,
      );
      await mockSequentialResponses(pic, call, [
        slackUsersListResponse([
          { id: "U_BOT", name: "bot-user", isBot: true },
          { id: "U_HUMAN", name: "human-user" },
        ]),
        ...WORKSPACE_CHANNEL_RESPONSES,
      ]);

      const getBotFn = await testCanister.getSlackUser("U_BOT");
      const botUser = await getBotFn();
      expect(botUser).toHaveLength(1);
      const b = botUser[0];
      if (!b) throw new Error("Expected bot user to be defined");
      expect(b.isBot).toBe(true);

      const getHumanFn = await testCanister.getSlackUser("U_HUMAN");
      const humanUser = await getHumanFn();
      expect(humanUser).toHaveLength(1);
      const h = humanUser[0];
      if (!h) throw new Error("Expected human user to be defined");
      expect(h.isBot).toBe(false);
    });
  });

  // ===========================================================================
  // Org Admin Channel Sync
  // ===========================================================================

  describe("org admin channel sync", () => {
    it("should skip org admin sync when no channel is configured", async () => {
      await resetCache();

      const call = await testCanister.testWeeklyReconciliation(
        SLACK_TEST_TOKEN,
        none, // no org admin channel
        none,
      );

      const result = (await mockSequentialResponses(pic, call, [
        slackUsersListResponse([
          { id: "U001", name: "alice", isPrimaryOwner: true },
        ]),
        ...WORKSPACE_CHANNEL_RESPONSES,
      ])) as ReconciliationSummary;

      // orgAdminChannelOk defaults to true when no channel is configured.
      expect(result.orgAdminChannelOk).toBe(true);
      expect(result.goneChannels).toHaveLength(0);
      expect(result.errors).toHaveLength(0);
    });

    it("should sync isOrgAdmin from the configured org admin channel", async () => {
      await resetCache();

      // Seed two users; U_ORG_ADMIN is currently in the admin channel.
      await seedUser({
        slackUserId: "U_ORG_ADMIN",
        displayName: "org-admin",
        isPrimaryOwner: false,
        isOrgAdmin: false,
      });
      await seedUser({
        slackUserId: "U_REG",
        displayName: "regular",
        isPrimaryOwner: false,
        isOrgAdmin: false,
      });

      const call = await testCanister.testWeeklyReconciliation(
        SLACK_TEST_TOKEN,
        some(ORG_ADMIN_CHANNEL_ID),
        some(ORG_ADMIN_CHANNEL_NAME),
      );

      await mockSequentialResponses(pic, call, [
        slackUsersListResponse([
          { id: "U_ORG_ADMIN", name: "org-admin" },
          { id: "U_REG", name: "regular" },
        ]),
        slackChannelMembersResponse(["U_ORG_ADMIN"]), // org admin channel — only U_ORG_ADMIN
        ...WORKSPACE_CHANNEL_RESPONSES,
      ]);

      const getAdminUserFn = await testCanister.getSlackUser("U_ORG_ADMIN");
      const adminUser = await getAdminUserFn();
      const getRegUserFn = await testCanister.getSlackUser("U_REG");
      const regUser = await getRegUserFn();

      expect(adminUser).toHaveLength(1);
      const au = adminUser[0];
      if (!au) throw new Error("Expected adminUser to be defined");
      expect(au.isOrgAdmin).toBe(true);
      expect(regUser).toHaveLength(1);
      const ru = regUser[0];
      if (!ru) throw new Error("Expected regUser to be defined");
      expect(ru.isOrgAdmin).toBe(false);
    });

    it("should clear isOrgAdmin when a user has left the org admin channel", async () => {
      await resetCache();

      // U_EX_ADMIN was an org admin but is no longer in the channel.
      await seedUser({
        slackUserId: "U_EX_ADMIN",
        displayName: "ex-admin",
        isPrimaryOwner: false,
        isOrgAdmin: true,
      });

      const call = await testCanister.testWeeklyReconciliation(
        SLACK_TEST_TOKEN,
        some(ORG_ADMIN_CHANNEL_ID),
        some(ORG_ADMIN_CHANNEL_NAME),
      );

      await mockSequentialResponses(pic, call, [
        slackUsersListResponse([{ id: "U_EX_ADMIN", name: "ex-admin" }]),
        slackChannelMembersResponse([]), // org admin channel — now empty
        ...WORKSPACE_CHANNEL_RESPONSES,
      ]);

      const getExAdminFn = await testCanister.getSlackUser("U_EX_ADMIN");
      const user = await getExAdminFn();

      expect(user).toHaveLength(1);
      const u = user[0];
      if (!u) throw new Error("Expected user to be defined");
      expect(u.isOrgAdmin).toBe(false);
    });

    it("should mark org admin channel as gone when getChannelMembers fails", async () => {
      await resetCache();

      // Seed a primary owner so a DM can be sent.
      await seedUser({
        slackUserId: "U_OWNER",
        displayName: "owner",
        isPrimaryOwner: true,
        isOrgAdmin: false,
      });

      const call = await testCanister.testWeeklyReconciliation(
        SLACK_TEST_TOKEN,
        some(ORG_ADMIN_CHANNEL_ID),
        some(ORG_ADMIN_CHANNEL_NAME),
      );

      // org admin channel → channel_not_found; DM to primary owner → success;
      // then workspace channel calls.
      const result = (await mockSequentialResponses(pic, call, [
        slackUsersListResponse([
          { id: "U_OWNER", name: "owner", isPrimaryOwner: true },
        ]),
        slackChannelNotFoundError, // org admin channel gone
        slackPostMessageResponse("U_OWNER"), // DM to primary owner
        ...WORKSPACE_CHANNEL_RESPONSES,
      ])) as ReconciliationSummary;

      expect(result.orgAdminChannelOk).toBe(false);
      expect(result.goneChannels).toContain(ORG_ADMIN_CHANNEL_ID);
    });

    it("should record orgAdminChannelOk=false and the gone channel in goneChannels", async () => {
      await resetCache();

      await seedUser({
        slackUserId: "U_OWNER",
        displayName: "owner",
        isPrimaryOwner: true,
        isOrgAdmin: false,
      });

      const call = await testCanister.testWeeklyReconciliation(
        SLACK_TEST_TOKEN,
        some(ORG_ADMIN_CHANNEL_ID),
        some(ORG_ADMIN_CHANNEL_NAME),
      );

      const result = (await mockSequentialResponses(pic, call, [
        slackUsersListResponse([
          { id: "U_OWNER", name: "owner", isPrimaryOwner: true },
        ]),
        slackChannelNotFoundError, // org admin channel gone
        slackPostMessageResponse("U_OWNER"), // DM to primary owner
        ...WORKSPACE_CHANNEL_RESPONSES,
      ])) as ReconciliationSummary;

      expect(result.orgAdminChannelOk).toBe(false);
      expect(result.goneChannels).toContain(ORG_ADMIN_CHANNEL_ID);
    });

    it("should record an error when org admin channel is gone and no primary owner in cache", async () => {
      await resetCache();
      // No primary owner seeded — users.list returns no primary owner either.

      const call = await testCanister.testWeeklyReconciliation(
        SLACK_TEST_TOKEN,
        some(ORG_ADMIN_CHANNEL_ID),
        some(ORG_ADMIN_CHANNEL_NAME),
      );

      const result = (await mockSequentialResponses(pic, call, [
        slackUsersListResponse([{ id: "U_REG", name: "regular" }]),
        slackChannelNotFoundError, // org admin channel gone
        // No postMessage call because there is no primary owner to DM.
        ...WORKSPACE_CHANNEL_RESPONSES,
      ])) as ReconciliationSummary;

      expect(result.orgAdminChannelOk).toBe(false);
      expect(result.goneChannels).toContain(ORG_ADMIN_CHANNEL_ID);
      expect(result.errors.length).toBeGreaterThan(0);
      expect(
        result.errors.some((e) => e.includes("Primary Owner not found")),
      ).toBe(true);
    });
  });

  // ===========================================================================
  // Workspace Channel Sync
  // ===========================================================================

  describe("workspace channel sync", () => {
    it("should check all configured workspaces (including those without channels)", async () => {
      await resetCache();

      const call = await testCanister.testWeeklyReconciliation(
        SLACK_TEST_TOKEN,
        none,
        none,
      );

      const result = (await mockSequentialResponses(pic, call, [
        slackUsersListResponse([]),
        ...WORKSPACE_CHANNEL_RESPONSES,
      ])) as ReconciliationSummary;

      // 3 workspaces are seeded (0, 1, 2).
      expect(result.workspacesChecked).toBe(3n);
    });

    it("should mark workspace admin channel as gone when getChannelMembers fails", async () => {
      await resetCache();

      const call = await testCanister.testWeeklyReconciliation(
        SLACK_TEST_TOKEN,
        some(ORG_ADMIN_CHANNEL_ID),
        some(ORG_ADMIN_CHANNEL_NAME),
      );

      const result = (await mockSequentialResponses(pic, call, [
        slackUsersListResponse([]),
        slackChannelMembersResponse([]), // org admin channel — ok
        slackChannelNotFoundError, // ws1 admin channel — gone
        slackPostMessageResponse(ORG_ADMIN_CHANNEL_ID), // notification to org admin channel
        slackChannelMembersResponse([]), // ws1 member channel — ok
        slackChannelMembersResponse([]), // ws2 admin channel — ok
        slackChannelMembersResponse([]), // ws2 member channel — ok
      ])) as ReconciliationSummary;

      expect(result.goneChannels).toContain("C_ADMIN_CHANNEL");
    });

    it("should mark workspace member channel as gone when getChannelMembers fails", async () => {
      await resetCache();

      const call = await testCanister.testWeeklyReconciliation(
        SLACK_TEST_TOKEN,
        some(ORG_ADMIN_CHANNEL_ID),
        some(ORG_ADMIN_CHANNEL_NAME),
      );

      const result = (await mockSequentialResponses(pic, call, [
        slackUsersListResponse([]),
        slackChannelMembersResponse([]), // org admin channel — ok
        slackChannelMembersResponse([]), // ws1 admin channel — ok
        slackChannelNotFoundError, // ws1 member channel — gone
        slackPostMessageResponse("C_ADMIN_CHANNEL"), // notification to ws1 admin channel
        slackChannelMembersResponse([]), // ws2 admin channel — ok
        slackChannelMembersResponse([]), // ws2 member channel — ok
      ])) as ReconciliationSummary;

      expect(result.goneChannels).toContain("C_MEMBER_CHANNEL");
    });

    it("should sync workspace admin channel membership flags", async () => {
      await resetCache();

      // Seed two users.
      await seedUser({
        slackUserId: "U_WS_ADMIN",
        displayName: "ws-admin",
        isPrimaryOwner: false,
        isOrgAdmin: false,
      });
      await seedUser({
        slackUserId: "U_OTHER",
        displayName: "other",
        isPrimaryOwner: false,
        isOrgAdmin: false,
      });

      const call = await testCanister.testWeeklyReconciliation(
        SLACK_TEST_TOKEN,
        none,
        none,
      );

      await mockSequentialResponses(pic, call, [
        slackUsersListResponse([
          { id: "U_WS_ADMIN", name: "ws-admin" },
          { id: "U_OTHER", name: "other" },
        ]),
        slackChannelMembersResponse(["U_WS_ADMIN"]), // ws1 admin — U_WS_ADMIN is a member
        slackChannelMembersResponse([]), // ws1 member
        slackChannelMembersResponse([]), // ws2 admin
        slackChannelMembersResponse([]), // ws2 member
      ]);

      // Verify via getSlackUser that the workspaceMembership flag was set.
      const getWsAdminFn = await testCanister.getSlackUser("U_WS_ADMIN");
      const user = await getWsAdminFn();

      expect(user).toHaveLength(1);
      const u = user[0];
      if (!u) throw new Error("Expected user to be defined");
      const memberships = u.workspaceMemberships;
      // Workspace 1 should have the admin flag set.
      const ws1 = memberships.find(([wsId]) => wsId === 1n);
      expect(ws1).toBeDefined();
      if (ws1) {
        expect("admin" in ws1[1]).toBe(true);
      }
    });

    it("should clear workspace admin flag when user has left the admin channel", async () => {
      await resetCache();

      // Seed user with the admin flag pre-set on workspace 1.
      await seedUser({
        slackUserId: "U_EX_WS_ADMIN",
        displayName: "ex-ws-admin",
        isPrimaryOwner: false,
        isOrgAdmin: false,
      });
      await seedWorkspaceMembership("U_EX_WS_ADMIN", 1n, "admin");

      const call = await testCanister.testWeeklyReconciliation(
        SLACK_TEST_TOKEN,
        none,
        none,
      );
      await mockSequentialResponses(pic, call, [
        slackUsersListResponse([{ id: "U_EX_WS_ADMIN", name: "ex-ws-admin" }]),
        slackChannelMembersResponse([]), // ws1 admin — now empty, user left
        slackChannelMembersResponse([]), // ws1 member
        slackChannelMembersResponse([]), // ws2 admin
        slackChannelMembersResponse([]), // ws2 member
      ]);

      const getFn = await testCanister.getSlackUser("U_EX_WS_ADMIN");
      const user = await getFn();
      expect(user).toHaveLength(1);
      const u = user[0];
      if (!u) throw new Error("Expected user to be defined");
      // Workspace 1 membership should be gone (no admin or member flag).
      const ws1 = u.workspaceMemberships.find(([wsId]) => wsId === 1n);
      expect(ws1).toBeUndefined();
    });

    it("should clear workspace member flag when user has left the member channel", async () => {
      await resetCache();

      await seedUser({
        slackUserId: "U_EX_WS_MEM",
        displayName: "ex-ws-member",
        isPrimaryOwner: false,
        isOrgAdmin: false,
      });
      await seedWorkspaceMembership("U_EX_WS_MEM", 1n, "member");

      const call = await testCanister.testWeeklyReconciliation(
        SLACK_TEST_TOKEN,
        none,
        none,
      );
      await mockSequentialResponses(pic, call, [
        slackUsersListResponse([{ id: "U_EX_WS_MEM", name: "ex-ws-member" }]),
        slackChannelMembersResponse([]), // ws1 admin
        slackChannelMembersResponse([]), // ws1 member — now empty, user left
        slackChannelMembersResponse([]), // ws2 admin
        slackChannelMembersResponse([]), // ws2 member
      ]);

      const getFn = await testCanister.getSlackUser("U_EX_WS_MEM");
      const user = await getFn();
      expect(user).toHaveLength(1);
      const u = user[0];
      if (!u) throw new Error("Expected user to be defined");
      const ws1 = u.workspaceMemberships.find(([wsId]) => wsId === 1n);
      expect(ws1).toBeUndefined();
    });

    it("should NOT notify org admin channel when it is already inaccessible and a workspace channel is also gone", async () => {
      await resetCache();

      // Seed primary owner so the DM path is exercised.
      await seedUser({
        slackUserId: "U_PO",
        displayName: "primary-owner",
        isPrimaryOwner: true,
        isOrgAdmin: false,
      });

      const call = await testCanister.testWeeklyReconciliation(
        SLACK_TEST_TOKEN,
        some(ORG_ADMIN_CHANNEL_ID),
        some(ORG_ADMIN_CHANNEL_NAME),
      );

      // Sequence: users.list → org admin gone → DM to PO → ws1 admin GONE
      //           (no postMessage to org admin channel — it's gone!) → ws1 member ok
      //           → ws2 admin ok → ws2 member ok
      const result = (await mockSequentialResponses(pic, call, [
        slackUsersListResponse([
          { id: "U_PO", name: "primary-owner", isPrimaryOwner: true },
        ]),
        slackChannelNotFoundError, // org admin channel — gone
        slackPostMessageResponse("U_PO"), // DM to primary owner
        slackChannelNotFoundError, // ws1 admin channel — also gone
        // Critically: no postMessage response here (code must NOT try to notify)
        slackChannelMembersResponse([]), // ws1 member channel — ok
        slackChannelMembersResponse([]), // ws2 admin channel — ok
        slackChannelMembersResponse([]), // ws2 member channel — ok
      ])) as ReconciliationSummary;

      expect(result.orgAdminChannelOk).toBe(false);
      expect(result.goneChannels).toContain(ORG_ADMIN_CHANNEL_ID);
      expect(result.goneChannels).toContain("C_ADMIN_CHANNEL");
      // Must not contain a postMessage error (the fallback was correctly skipped).
      expect(
        result.errors.some((e) =>
          e.includes("notify org admin channel about gone workspace"),
        ),
      ).toBe(false);
    });

    it("should not grant workspace flag for a channel member not in user cache", async () => {
      await resetCache();

      // Only U_KNOWN is in the cache; U_GHOST is in the channel but not in cache.
      await seedUser({
        slackUserId: "U_KNOWN",
        displayName: "known",
        isPrimaryOwner: false,
        isOrgAdmin: false,
      });

      const call = await testCanister.testWeeklyReconciliation(
        SLACK_TEST_TOKEN,
        none,
        none,
      );
      await mockSequentialResponses(pic, call, [
        slackUsersListResponse([{ id: "U_KNOWN", name: "known" }]),
        slackChannelMembersResponse(["U_KNOWN", "U_GHOST"]), // ws1 admin
        slackChannelMembersResponse([]), // ws1 member
        slackChannelMembersResponse([]), // ws2 admin
        slackChannelMembersResponse([]), // ws2 member
      ]);

      // U_GHOST must NOT have been added to the cache (warning is logged but user is not created).
      const getGhostFn = await testCanister.getSlackUser("U_GHOST");
      const ghost = await getGhostFn();
      expect(ghost).toHaveLength(0);

      // U_KNOWN should have received the ws1 admin flag.
      const getKnownFn = await testCanister.getSlackUser("U_KNOWN");
      const known = await getKnownFn();
      expect(known).toHaveLength(1);
      const k = known[0];
      if (!k) throw new Error("Expected known user to be defined");
      const ws1 = k.workspaceMemberships.find(([wsId]) => wsId === 1n);
      expect(ws1).toBeDefined();
      if (ws1) expect("admin" in ws1[1]).toBe(true);
    });
  });

  // ===========================================================================
  // Access Change Log
  // ===========================================================================

  describe("access change log", () => {
    it("should record reconciliation source in change log entries after a run", async () => {
      await resetCache();

      // Seed U_A with isOrgAdmin=false; the org admin channel will grant it.
      await seedUser({
        slackUserId: "U_A",
        displayName: "user-a",
        isPrimaryOwner: false,
        isOrgAdmin: false,
      });

      const call = await testCanister.testWeeklyReconciliation(
        SLACK_TEST_TOKEN,
        some(ORG_ADMIN_CHANNEL_ID),
        some(ORG_ADMIN_CHANNEL_NAME),
      );
      await mockSequentialResponses(pic, call, [
        slackUsersListResponse([{ id: "U_A", name: "user-a" }]),
        slackChannelMembersResponse(["U_A"]), // org admin channel — U_A granted
        ...WORKSPACE_CHANNEL_RESPONSES,
      ]);

      const getLogFn = await testCanister.getChangeLog();
      const log = await getLogFn();

      // Should contain an orgAdminGranted entry for U_A with source=reconciliation.
      const grantEntry = log.find(
        (e) =>
          e.slackUserId === "U_A" &&
          e.changeType === "orgAdminGranted" &&
          e.source === "reconciliation",
      );
      expect(grantEntry).toBeDefined();
    });

    it("should record #slackEvent source after a member_joined_channel event", async () => {
      await resetCache();

      // Seed U_EVENT so the handler can look it up.
      await seedUser({
        slackUserId: "U_EVENT",
        displayName: "event-user",
        isPrimaryOwner: false,
        isOrgAdmin: false,
      });

      // C_ADMIN_CHANNEL is the admin channel for workspace 1 in the test harness.
      const handlerFn = await testCanister.testMemberJoinedChannelHandler({
        userId: "U_EVENT",
        channelId: "C_ADMIN_CHANNEL",
        channelType: "C",
        teamId: "T_TEST",
        eventTs: "1700000000.000001",
      });
      await handlerFn();

      const getLogFn = await testCanister.getChangeLog();
      const log = await getLogFn();

      const eventEntry = log.find(
        (e) =>
          e.slackUserId === "U_EVENT" &&
          e.changeType === "workspaceAdminGranted" &&
          e.source === "slackEvent:1700000000.000001",
      );
      expect(eventEntry).toBeDefined();
      expect(eventEntry?.workspaceId).toEqual([1n]);
    });

    it("should purge old access change log entries during reconciliation", async () => {
      await resetCache();

      // pic.setTime() takes milliseconds (number | Date).
      // Set a fixed start time so first-run entries are stamped at this moment.
      const startTimeMs = Date.now();
      await pic.setTime(startTimeMs);
      await pic.tick(3);

      // Run first reconciliation — this seeds log entries at startTimeMs.
      const call1 = await testCanister.testWeeklyReconciliation(
        SLACK_TEST_TOKEN,
        none,
        none,
      );
      await mockSequentialResponses(pic, call1, [
        slackUsersListResponse([{ id: "U_PURGE", name: "purge-test" }]),
        ...WORKSPACE_CHANNEL_RESPONSES,
      ]);

      // Advance PocketIC clock by 2 years (past the 1-year retention period).
      const twoYearsMs = 2 * 365 * 24 * 3600 * 1000;
      await pic.setTime(startTimeMs + twoYearsMs);
      await pic.tick(3);

      // Run second reconciliation — should detect and purge the old entries.
      const call2 = await testCanister.testWeeklyReconciliation(
        SLACK_TEST_TOKEN,
        none,
        none,
      );
      const result = (await mockSequentialResponses(pic, call2, [
        slackUsersListResponse([{ id: "U_PURGE", name: "purge-test" }]),
        ...WORKSPACE_CHANNEL_RESPONSES,
      ])) as ReconciliationSummary;

      expect(result.logsPurged).toBeGreaterThan(0n);
    });
  });

  // ===========================================================================
  // Summary fields
  // ===========================================================================

  describe("summary", () => {
    it("should return zero goneChannels and errors on a clean run", async () => {
      await resetCache();

      const call = await testCanister.testWeeklyReconciliation(
        SLACK_TEST_TOKEN,
        some(ORG_ADMIN_CHANNEL_ID),
        some(ORG_ADMIN_CHANNEL_NAME),
      );

      const result = (await mockSequentialResponses(pic, call, [
        slackUsersListResponse([
          { id: "U001", name: "alice", isPrimaryOwner: true },
        ]),
        slackChannelMembersResponse(["U001"]), // org admin channel
        ...WORKSPACE_CHANNEL_RESPONSES,
      ])) as ReconciliationSummary;

      expect(result.orgAdminChannelOk).toBe(true);
      expect(result.goneChannels).toHaveLength(0);
      expect(result.errors).toHaveLength(0);
      expect(result.workspacesChecked).toBe(3n);
      expect(result.usersUpdated).toBe(1n);
      // Audit fields should be present (may be empty on a trivially clean run).
      expect(Array.isArray(result.orgAdminsGranted)).toBe(true);
      expect(Array.isArray(result.orgAdminsRevoked)).toBe(true);
      expect(Array.isArray(result.workspaceScopeChanges)).toBe(true);
      expect(Array.isArray(result.staleUsersRemoved)).toBe(true);
      expect(typeof result.logsPurged).toBe("bigint");
    });
  });

  // ===========================================================================
  // Full happy-path cassette test (real Slack API)
  // ===========================================================================

  describe("full happy-path (cassette)", () => {
    it("should complete reconciliation with real Slack responses", async () => {
      const { result } = await withCassette(
        pic,
        "unit-tests/open-org-backend/services/weekly-reconciliation-service/full-run",
        () =>
          testCanister.testWeeklyReconciliation(SLACK_TEST_TOKEN, none, none),
        { ticks: 5, maxRounds: 20 },
      );

      const summary = (await result) as ReconciliationSummary;

      expect(summary.usersUpdated).toBeGreaterThan(0n);
      expect(summary.workspacesChecked).toBeGreaterThanOrEqual(0n);
      expect(Array.isArray(summary.goneChannels)).toBe(true);
      expect(Array.isArray(summary.errors)).toBe(true);
      expect(Array.isArray(summary.orgAdminsGranted)).toBe(true);
      expect(Array.isArray(summary.staleUsersRemoved)).toBe(true);
      expect(typeof summary.logsPurged).toBe("bigint");
    });
  });
});
