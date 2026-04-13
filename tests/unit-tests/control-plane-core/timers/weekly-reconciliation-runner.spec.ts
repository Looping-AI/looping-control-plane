import {
  afterAll,
  beforeAll,
  beforeEach,
  describe,
  expect,
  it,
} from "bun:test";
import type { PocketIc, DeferredActor } from "@dfinity/pic";
import {
  createDeferredTestCanister,
  type TestCanisterService,
  SLACK_TEST_TOKEN,
  freshDeferredTestCanister,
} from "../../../setup";
import { withCassette } from "../../../lib/cassette";

// ===========================================================================
// Typed helpers for the summary returned by testWeeklyReconciliationRunner.
// (The DID type is inferred from the Motoko source; we assert it here for
// readability and to keep tests self-documenting.)
// ===========================================================================
interface WorkspaceScopeChange {
  slackUserId: string;
  workspaceId: bigint;
  changeType: { adminGranted: null } | { adminRevoked: null };
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

/** A minimal conversations.info success response. */
function slackChannelInfoResponse(channelId: string, channelName: string) {
  return { ok: true, channel: { id: channelId, name: channelName } };
}

/** A minimal conversations.list success response (used by listChannels / auto-discovery). */
function slackListChannelsResponse(
  channels: Array<{ id: string; name: string }>,
  nextCursor = "",
) {
  return {
    ok: true,
    channels: channels.map((c) => ({ id: c.id, name: c.name })),
    response_metadata: { next_cursor: nextCursor },
  };
}

/** conversations.list returning no channels (used as "not found" in auto-discovery). */
const slackListChannelsEmpty = slackListChannelsResponse([]);

const slackAuthError = { ok: false, error: "invalid_auth" };
const slackChannelNotFoundError = { ok: false, error: "channel_not_found" };

// ===========================================================================
// Mock-driving helpers
// ===========================================================================

/** Unwrap a Result variant returned by testWeeklyReconciliationRunner. */
function expectSummary(raw: unknown): ReconciliationSummary {
  const r = raw as { ok?: ReconciliationSummary; err?: string };
  if ("err" in (r as object))
    throw new Error(`Reconciliation run failed: ${r.err}`);
  return r.ok!;
}

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
): Promise<ReconciliationSummary> {
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

  return expectSummary(await call());
}

// ===========================================================================
// Tests
// ===========================================================================

describe("Weekly Reconciliation Runner Unit Tests", () => {
  let pic: PocketIc;
  let testCanister: DeferredActor<TestCanisterService>;

  beforeAll(async () => {
    const testEnv = await createDeferredTestCanister();
    pic = testEnv.pic;
  });

  beforeEach(async () => {
    testCanister = (await freshDeferredTestCanister(pic)).actor;
  });

  afterAll(async () => {
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
  ) {
    const deferred = await testCanister.seedWorkspaceMembership(
      slackUserId,
      workspaceId,
    );
    await deferred();
  }

  // The test workspace state pre-seeded in test-canister.mo has:
  //   Workspace 0: default — no channel anchors
  //   Workspace 1: adminChannelId = "C_ADMIN_CHANNEL"
  //   Workspace 2: adminChannelId = "C_ROUND_TRIP_ADMIN"
  //
  // A run without org admin channel now triggers 2 auto-discovery calls
  // (listChannels private + listChannels public), then 2 workspace channel
  // HTTP calls (ws1-admin, ws2-admin).
  const WORKSPACE_CHANNEL_RESPONSES = [
    slackChannelMembersResponse([]), // ws1 admin channel
    slackChannelMembersResponse([]), // ws2 admin channel
  ];

  // ===========================================================================
  // User Refresh
  // ===========================================================================

  describe("user refresh", () => {
    it("should abort reconciliation when users.list fails", async () => {
      const call = await testCanister.testWeeklyReconciliationRunner(
        "xoxb-invalid",
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

      const call = await testCanister.testWeeklyReconciliationRunner(
        SLACK_TEST_TOKEN,
        none,
      );

      await mockSequentialResponses(pic, call, [
        slackUsersListResponse(members),
        slackListChannelsEmpty, // auto-discovery (private) — not found
        slackListChannelsEmpty, // public channel check — not found
        ...WORKSPACE_CHANNEL_RESPONSES,
      ]);

      const getUsers = await testCanister.getSlackUsers();
      const cachedUsers = await getUsers();
      const userMap = new Map(
        cachedUsers.map((u: { slackUserId: string }) => [u.slackUserId, u]),
      );

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

      const call = await testCanister.testWeeklyReconciliationRunner(
        SLACK_TEST_TOKEN,
        none,
      );

      const result = (await mockSequentialResponses(pic, call, [
        slackUsersListResponse(members),
        slackListChannelsEmpty, // auto-discovery (private) — not found
        slackListChannelsEmpty, // public channel check — not found
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

      const call = await testCanister.testWeeklyReconciliationRunner(
        SLACK_TEST_TOKEN,
        none,
      );

      await mockSequentialResponses(pic, call, [
        slackUsersListResponse(membersFromSlack),
        slackListChannelsEmpty, // auto-discovery (private) — not found
        slackListChannelsEmpty, // public channel check — not found
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
      const call = await testCanister.testWeeklyReconciliationRunner(
        SLACK_TEST_TOKEN,
        none,
      );
      const result = (await mockSequentialResponses(pic, call, [
        slackUsersListResponse([]), // empty — no current members
        slackListChannelsEmpty, // auto-discovery (private) — not found
        slackListChannelsEmpty, // public channel check — not found
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

      const call = await testCanister.testWeeklyReconciliationRunner(
        SLACK_TEST_TOKEN,
        none,
      );
      const result = (await mockSequentialResponses(pic, call, [
        slackUsersListResponse([
          { id: "U_ACTIVE", name: "active" },
          { id: "U_DELETED", name: "deleted-user", isDeleted: true },
        ]),
        slackListChannelsEmpty, // auto-discovery (private) — not found
        slackListChannelsEmpty, // public channel check — not found
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

      const call = await testCanister.testWeeklyReconciliationRunner(
        SLACK_TEST_TOKEN,
        none,
      );
      await mockSequentialResponses(pic, call, [
        slackUsersListResponse([
          { id: "U_BOT", name: "bot-user", isBot: true },
          { id: "U_HUMAN", name: "human-user" },
        ]),
        slackListChannelsEmpty, // auto-discovery (private) — not found
        slackListChannelsEmpty, // public channel check — not found
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

      const call = await testCanister.testWeeklyReconciliationRunner(
        SLACK_TEST_TOKEN,
        none, // no org admin channel
      );

      const result = (await mockSequentialResponses(pic, call, [
        slackUsersListResponse([
          { id: "U001", name: "alice", isPrimaryOwner: true },
        ]),
        slackListChannelsEmpty, // auto-discovery attempt (private) — not found
        slackListChannelsEmpty, // public channel check — not found
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

      const call = await testCanister.testWeeklyReconciliationRunner(
        SLACK_TEST_TOKEN,
        some(ORG_ADMIN_CHANNEL_ID),
      );

      await mockSequentialResponses(pic, call, [
        slackUsersListResponse([
          { id: "U_ORG_ADMIN", name: "org-admin" },
          { id: "U_REG", name: "regular" },
        ]),
        slackChannelInfoResponse(ORG_ADMIN_CHANNEL_ID, ORG_ADMIN_CHANNEL_NAME), // org admin — info ok
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

      const call = await testCanister.testWeeklyReconciliationRunner(
        SLACK_TEST_TOKEN,
        some(ORG_ADMIN_CHANNEL_ID),
      );

      await mockSequentialResponses(pic, call, [
        slackUsersListResponse([{ id: "U_EX_ADMIN", name: "ex-admin" }]),
        slackChannelInfoResponse(ORG_ADMIN_CHANNEL_ID, ORG_ADMIN_CHANNEL_NAME), // org admin — info ok
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

      const call = await testCanister.testWeeklyReconciliationRunner(
        SLACK_TEST_TOKEN,
        some(ORG_ADMIN_CHANNEL_ID),
      );

      // org admin channel → getChannelInfo fails (channel_not_found); auto-discovery finds nothing;
      // DM to primary owner → success; then workspace channel calls.
      const result = (await mockSequentialResponses(pic, call, [
        slackUsersListResponse([
          { id: "U_OWNER", name: "owner", isPrimaryOwner: true },
        ]),
        slackChannelNotFoundError, // org admin channel — gone (getChannelInfo fails)
        slackListChannelsEmpty, // auto-discovery (private) — not found
        slackPostMessageResponse("U_OWNER"), // recovery DM to primary owner
        slackListChannelsEmpty, // public channel check — not found
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

      const call = await testCanister.testWeeklyReconciliationRunner(
        SLACK_TEST_TOKEN,
        some(ORG_ADMIN_CHANNEL_ID),
      );

      const result = (await mockSequentialResponses(pic, call, [
        slackUsersListResponse([
          { id: "U_OWNER", name: "owner", isPrimaryOwner: true },
        ]),
        slackChannelNotFoundError, // org admin channel — gone (getChannelInfo fails)
        slackListChannelsEmpty, // auto-discovery (private) — not found
        slackPostMessageResponse("U_OWNER"), // recovery DM to primary owner
        slackListChannelsEmpty, // public channel check — not found
        ...WORKSPACE_CHANNEL_RESPONSES,
      ])) as ReconciliationSummary;

      expect(result.orgAdminChannelOk).toBe(false);
      expect(result.goneChannels).toContain(ORG_ADMIN_CHANNEL_ID);
    });

    it("should record an error when org admin channel is gone and no primary owner in cache", async () => {
      await resetCache();
      // No primary owner seeded — users.list returns no primary owner either.

      const call = await testCanister.testWeeklyReconciliationRunner(
        SLACK_TEST_TOKEN,
        some(ORG_ADMIN_CHANNEL_ID),
      );

      const result = (await mockSequentialResponses(pic, call, [
        slackUsersListResponse([{ id: "U_REG", name: "regular" }]),
        slackChannelNotFoundError, // org admin channel — gone (getChannelInfo fails)
        slackListChannelsEmpty, // auto-discovery (private) — not found
        // No recovery DM (no primary owner), but public check still runs.
        slackListChannelsEmpty, // public channel check — not found
        ...WORKSPACE_CHANNEL_RESPONSES,
      ])) as ReconciliationSummary;

      expect(result.orgAdminChannelOk).toBe(false);
      expect(result.goneChannels).toContain(ORG_ADMIN_CHANNEL_ID);
      expect(result.errors.length).toBeGreaterThan(0);
      expect(
        result.errors.some((e) => e.includes("Primary Owner not found")),
      ).toBe(true);
    });

    it("should warn Primary Owner when org admin channel has the wrong name", async () => {
      await resetCache();

      await seedUser({
        slackUserId: "U_PO",
        displayName: "primary-owner",
        isPrimaryOwner: true,
        isOrgAdmin: false,
      });

      const call = await testCanister.testWeeklyReconciliationRunner(
        SLACK_TEST_TOKEN,
        some(ORG_ADMIN_CHANNEL_ID),
      );

      // conversations.info returns wrong name → auto-discovery finds nothing → DM warning sent
      // → public check finds nothing → conversations.members continues.
      const result = (await mockSequentialResponses(pic, call, [
        slackUsersListResponse([
          { id: "U_PO", name: "primary-owner", isPrimaryOwner: true },
        ]),
        slackChannelInfoResponse(ORG_ADMIN_CHANNEL_ID, "wrong-channel-name"), // wrong name!
        slackListChannelsEmpty, // auto-discovery (private) — not found
        slackListChannelsEmpty, // public channel check — not found
        slackPostMessageResponse("U_PO"), // rename warning DM to Primary Owner
        slackChannelMembersResponse([]), // org admin channel — members ok (original channel)
        ...WORKSPACE_CHANNEL_RESPONSES,
      ])) as ReconciliationSummary;

      // Channel is still accessible; orgAdminChannelOk = true.
      expect(result.orgAdminChannelOk).toBe(true);
      expect(result.goneChannels).toHaveLength(0);
    });

    it("should record an error when org admin channel has wrong name and no primary owner in cache", async () => {
      await resetCache();
      // No primary owner — warning DM cannot be sent.

      const call = await testCanister.testWeeklyReconciliationRunner(
        SLACK_TEST_TOKEN,
        some(ORG_ADMIN_CHANNEL_ID),
      );

      const result = (await mockSequentialResponses(pic, call, [
        slackUsersListResponse([{ id: "U_REG", name: "regular" }]),
        slackChannelInfoResponse(ORG_ADMIN_CHANNEL_ID, "wrong-channel-name"), // wrong name, no DM
        slackListChannelsEmpty, // auto-discovery (private) — not found
        slackListChannelsEmpty, // public channel check — not found
        slackChannelMembersResponse([]), // org admin channel — members ok (original channel)
        ...WORKSPACE_CHANNEL_RESPONSES,
      ])) as ReconciliationSummary;

      expect(result.orgAdminChannelOk).toBe(true);
      expect(result.errors.length).toBeGreaterThan(0);
      expect(
        result.errors.some((e) => e.includes("Primary Owner not found")),
      ).toBe(true);
    });

    it("should auto-discover and anchor a private org admin channel when none is configured", async () => {
      await resetCache();

      await seedUser({
        slackUserId: "U_ORG_ADMIN",
        displayName: "org-admin",
        isPrimaryOwner: false,
        isOrgAdmin: false,
      });

      const call = await testCanister.testWeeklyReconciliationRunner(
        SLACK_TEST_TOKEN,
        none, // no anchor configured
      );

      const result = (await mockSequentialResponses(pic, call, [
        slackUsersListResponse([{ id: "U_ORG_ADMIN", name: "org-admin" }]),
        slackListChannelsResponse([
          { id: "C_PRIV_ADMIN", name: ORG_ADMIN_CHANNEL_NAME },
        ]), // private — found!
        slackChannelMembersResponse(["U_ORG_ADMIN"]), // member sync on discovered channel
        ...WORKSPACE_CHANNEL_RESPONSES,
      ])) as ReconciliationSummary;

      expect(result.orgAdminChannelOk).toBe(true);
      expect(result.goneChannels).toHaveLength(0);
      expect(result.errors).toHaveLength(0);

      const getUserFn = await testCanister.getSlackUser("U_ORG_ADMIN");
      const user = await getUserFn();
      expect(user).toHaveLength(1);
      const u = user[0];
      if (!u) throw new Error("Expected user to be defined");
      expect(u.isOrgAdmin).toBe(true);
    });

    it("should auto-recover when the org admin channel is gone but a new private one exists", async () => {
      await resetCache();

      await seedUser({
        slackUserId: "U_ORG_ADMIN",
        displayName: "org-admin",
        isPrimaryOwner: false,
        isOrgAdmin: false,
      });

      const call = await testCanister.testWeeklyReconciliationRunner(
        SLACK_TEST_TOKEN,
        some(ORG_ADMIN_CHANNEL_ID), // stale anchor — this channel is gone
      );

      const result = (await mockSequentialResponses(pic, call, [
        slackUsersListResponse([{ id: "U_ORG_ADMIN", name: "org-admin" }]),
        slackChannelNotFoundError, // old anchor gone
        slackListChannelsResponse([
          { id: "C_NEW_PRIV_ADMIN", name: ORG_ADMIN_CHANNEL_NAME },
        ]), // private — new channel found!
        slackChannelMembersResponse(["U_ORG_ADMIN"]), // member sync on new channel
        ...WORKSPACE_CHANNEL_RESPONSES,
      ])) as ReconciliationSummary;

      // Auto-recovered silently: no DM, no gone channel, channel ok.
      expect(result.orgAdminChannelOk).toBe(true);
      expect(result.goneChannels).toHaveLength(0);
      expect(result.errors).toHaveLength(0);

      const getUserFn = await testCanister.getSlackUser("U_ORG_ADMIN");
      const user = await getUserFn();
      expect(user).toHaveLength(1);
      const u = user[0];
      if (!u) throw new Error("Expected user to be defined");
      expect(u.isOrgAdmin).toBe(true);
    });

    it("should redirect sync to a newly discovered private channel when the anchored channel was renamed", async () => {
      await resetCache();

      await seedUser({
        slackUserId: "U_ORG_ADMIN",
        displayName: "org-admin",
        isPrimaryOwner: false,
        isOrgAdmin: false,
      });

      const call = await testCanister.testWeeklyReconciliationRunner(
        SLACK_TEST_TOKEN,
        some(ORG_ADMIN_CHANNEL_ID), // anchored to a channel that was renamed away
      );

      const result = (await mockSequentialResponses(pic, call, [
        slackUsersListResponse([{ id: "U_ORG_ADMIN", name: "org-admin" }]),
        slackChannelInfoResponse(ORG_ADMIN_CHANNEL_ID, "old-renamed-channel"), // wrong name
        slackListChannelsResponse([
          { id: "C_CORRECT_PRIV", name: ORG_ADMIN_CHANNEL_NAME },
        ]), // private — correct channel found
        slackChannelMembersResponse(["U_ORG_ADMIN"]), // member sync uses NEW channel
        ...WORKSPACE_CHANNEL_RESPONSES,
      ])) as ReconciliationSummary;

      // Silently re-anchored; no DM, no error.
      expect(result.orgAdminChannelOk).toBe(true);
      expect(result.goneChannels).toHaveLength(0);
      expect(result.errors).toHaveLength(0);

      const getUserFn = await testCanister.getSlackUser("U_ORG_ADMIN");
      const user = await getUserFn();
      expect(user).toHaveLength(1);
      const u = user[0];
      if (!u) throw new Error("Expected user to be defined");
      expect(u.isOrgAdmin).toBe(true);
    });

    it("should warn Primary Owner when a public org admin channel exists but no private one is found", async () => {
      await resetCache();

      await seedUser({
        slackUserId: "U_PO",
        displayName: "primary-owner",
        isPrimaryOwner: true,
        isOrgAdmin: false,
      });

      const call = await testCanister.testWeeklyReconciliationRunner(
        SLACK_TEST_TOKEN,
        none, // no anchor configured
      );

      const result = (await mockSequentialResponses(pic, call, [
        slackUsersListResponse([
          { id: "U_PO", name: "primary-owner", isPrimaryOwner: true },
        ]),
        slackListChannelsEmpty, // private search — not found
        slackListChannelsResponse([
          { id: "C_PUBLIC_ADMIN", name: ORG_ADMIN_CHANNEL_NAME },
        ]), // public found — must NOT be anchored, DM warning sent
        slackPostMessageResponse("U_PO"), // public-channel warning DM to Primary Owner
        ...WORKSPACE_CHANNEL_RESPONSES,
      ])) as ReconciliationSummary;

      // Public channel is never anchored; orgAdminChannelOk stays true (anchor wasn't attempted).
      expect(result.orgAdminChannelOk).toBe(true);
      expect(result.goneChannels).toHaveLength(0);
    });

    it("should warn about a public channel when the org admin channel is gone and no private replacement is found", async () => {
      await resetCache();

      await seedUser({
        slackUserId: "U_PO",
        displayName: "primary-owner",
        isPrimaryOwner: true,
        isOrgAdmin: false,
      });

      const call = await testCanister.testWeeklyReconciliationRunner(
        SLACK_TEST_TOKEN,
        some(ORG_ADMIN_CHANNEL_ID),
      );

      const result = (await mockSequentialResponses(pic, call, [
        slackUsersListResponse([
          { id: "U_PO", name: "primary-owner", isPrimaryOwner: true },
        ]),
        slackChannelNotFoundError, // old anchor gone
        slackListChannelsEmpty, // private search — not found
        slackPostMessageResponse("U_PO"), // recovery DM (gone channel)
        slackListChannelsResponse([
          { id: "C_PUBLIC_ADMIN", name: ORG_ADMIN_CHANNEL_NAME },
        ]), // public found — DM warning about visibility
        slackPostMessageResponse("U_PO"), // public-channel warning DM to Primary Owner
        ...WORKSPACE_CHANNEL_RESPONSES,
      ])) as ReconciliationSummary;

      expect(result.orgAdminChannelOk).toBe(false);
      expect(result.goneChannels).toContain(ORG_ADMIN_CHANNEL_ID);
    });
  });

  // ===========================================================================
  // Workspace Channel Sync
  // ===========================================================================

  describe("workspace channel sync", () => {
    it("should check all configured workspaces (including those without channels)", async () => {
      await resetCache();

      const call = await testCanister.testWeeklyReconciliationRunner(
        SLACK_TEST_TOKEN,
        none,
      );

      const result = (await mockSequentialResponses(pic, call, [
        slackUsersListResponse([]),
        slackListChannelsEmpty, // auto-discovery (private) — not found
        slackListChannelsEmpty, // public channel check — not found
        ...WORKSPACE_CHANNEL_RESPONSES,
      ])) as ReconciliationSummary;

      // 3 workspaces are seeded (0, 1, 2).
      expect(result.workspacesChecked).toBe(3n);
    });

    it("should mark workspace admin channel as gone when getChannelMembers fails", async () => {
      await resetCache();

      const call = await testCanister.testWeeklyReconciliationRunner(
        SLACK_TEST_TOKEN,
        some(ORG_ADMIN_CHANNEL_ID),
      );

      const result = (await mockSequentialResponses(pic, call, [
        slackUsersListResponse([]),
        slackChannelInfoResponse(ORG_ADMIN_CHANNEL_ID, ORG_ADMIN_CHANNEL_NAME), // org admin — info ok
        slackChannelMembersResponse([]), // org admin channel — members ok
        slackChannelNotFoundError, // ws1 admin channel — gone
        slackPostMessageResponse(ORG_ADMIN_CHANNEL_ID), // notification to org admin channel
        slackChannelMembersResponse([]), // ws2 admin channel — ok
      ])) as ReconciliationSummary;

      expect(result.goneChannels).toContain("C_ADMIN_CHANNEL");
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

      const call = await testCanister.testWeeklyReconciliationRunner(
        SLACK_TEST_TOKEN,
        none,
      );

      await mockSequentialResponses(pic, call, [
        slackUsersListResponse([
          { id: "U_WS_ADMIN", name: "ws-admin" },
          { id: "U_OTHER", name: "other" },
        ]),
        slackListChannelsEmpty, // auto-discovery (private) — not found
        slackListChannelsEmpty, // public channel check — not found
        slackChannelMembersResponse(["U_WS_ADMIN"]), // ws1 admin — U_WS_ADMIN is a member
        slackChannelMembersResponse([]), // ws2 admin
      ]);

      // Verify via getSlackUser that the workspaceMembership flag was set.
      const getWsAdminFn = await testCanister.getSlackUser("U_WS_ADMIN");
      const user = await getWsAdminFn();

      expect(user).toHaveLength(1);
      const u = user[0];
      if (!u) throw new Error("Expected user to be defined");
      const memberships = u.adminWorkspaces;
      // Workspace 1 should be in the admin set.
      expect(memberships).toContainEqual(1n);
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
      await seedWorkspaceMembership("U_EX_WS_ADMIN", 1n);

      const call = await testCanister.testWeeklyReconciliationRunner(
        SLACK_TEST_TOKEN,
        none,
      );
      await mockSequentialResponses(pic, call, [
        slackUsersListResponse([{ id: "U_EX_WS_ADMIN", name: "ex-ws-admin" }]),
        slackListChannelsEmpty, // auto-discovery (private) — not found
        slackListChannelsEmpty, // public channel check — not found
        slackChannelMembersResponse([]), // ws1 admin — now empty, user left
        slackChannelMembersResponse([]), // ws2 admin
      ]);

      const getFn = await testCanister.getSlackUser("U_EX_WS_ADMIN");
      const user = await getFn();
      expect(user).toHaveLength(1);
      const u = user[0];
      if (!u) throw new Error("Expected user to be defined");
      // Workspace 1 membership should be gone.
      expect(u.adminWorkspaces).not.toContainEqual(1n);
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

      const call = await testCanister.testWeeklyReconciliationRunner(
        SLACK_TEST_TOKEN,
        some(ORG_ADMIN_CHANNEL_ID),
      );

      // Sequence: users.list → org admin getChannelInfo fails (gone) → auto-discovery finds nothing
      //           → DM to PO → public check finds nothing → ws1 admin GONE
      //           (no postMessage to org admin channel — it's gone!) → ws2 admin ok
      const result = (await mockSequentialResponses(pic, call, [
        slackUsersListResponse([
          { id: "U_PO", name: "primary-owner", isPrimaryOwner: true },
        ]),
        slackChannelNotFoundError, // org admin channel — gone (getChannelInfo fails)
        slackListChannelsEmpty, // auto-discovery (private) — not found
        slackPostMessageResponse("U_PO"), // recovery DM to primary owner
        slackListChannelsEmpty, // public channel check — not found
        slackChannelNotFoundError, // ws1 admin channel — also gone
        // Critically: no postMessage response here (code must NOT try to notify)
        slackChannelMembersResponse([]), // ws2 admin channel — ok
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

      const call = await testCanister.testWeeklyReconciliationRunner(
        SLACK_TEST_TOKEN,
        none,
      );
      await mockSequentialResponses(pic, call, [
        slackUsersListResponse([{ id: "U_KNOWN", name: "known" }]),
        slackListChannelsEmpty, // auto-discovery (private) — not found
        slackListChannelsEmpty, // public channel check — not found
        slackChannelMembersResponse(["U_KNOWN", "U_GHOST"]), // ws1 admin
        slackChannelMembersResponse([]), // ws2 admin
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
      expect(k.adminWorkspaces).toContainEqual(1n);
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

      const call = await testCanister.testWeeklyReconciliationRunner(
        SLACK_TEST_TOKEN,
        some(ORG_ADMIN_CHANNEL_ID),
      );
      await mockSequentialResponses(pic, call, [
        slackUsersListResponse([{ id: "U_A", name: "user-a" }]),
        slackChannelInfoResponse(ORG_ADMIN_CHANNEL_ID, ORG_ADMIN_CHANNEL_NAME), // org admin — info ok
        slackChannelMembersResponse(["U_A"]), // org admin channel — U_A granted
        ...WORKSPACE_CHANNEL_RESPONSES,
      ]);

      const getLogFn = await testCanister.getChangeLog();
      const log = await getLogFn();

      // Should contain an orgAdminGranted entry for U_A with source=reconciliation.
      const grantEntry = log.find(
        (e: { slackUserId: string; changeType: string; source: string }) =>
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
        (e: {
          slackUserId: string;
          changeType: string;
          source: string;
          workspaceId: [] | [bigint];
        }) =>
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
      // Use max(Date.now(), pic.getTime()) + buffer to avoid SettingTimeIntoPast.
      const picNowMs = await pic.getTime();
      const startTimeMs = Math.max(Date.now(), picNowMs) + 60_000;
      await pic.setTime(startTimeMs);
      await pic.tick(3);

      // Run first reconciliation — this seeds log entries at startTimeMs.
      const call1 = await testCanister.testWeeklyReconciliationRunner(
        SLACK_TEST_TOKEN,
        none,
      );
      await mockSequentialResponses(pic, call1, [
        slackUsersListResponse([{ id: "U_PURGE", name: "purge-test" }]),
        slackListChannelsEmpty, // auto-discovery (private) — not found
        slackListChannelsEmpty, // public channel check — not found
        ...WORKSPACE_CHANNEL_RESPONSES,
      ]);

      // Advance PocketIC clock by 2 years (past the 1-year retention period).
      const twoYearsMs = 2 * 365 * 24 * 3600 * 1000;
      await pic.setTime(startTimeMs + twoYearsMs);
      await pic.tick(3);

      // Run second reconciliation — should detect and purge the old entries.
      const call2 = await testCanister.testWeeklyReconciliationRunner(
        SLACK_TEST_TOKEN,
        none,
      );
      const result = (await mockSequentialResponses(pic, call2, [
        slackUsersListResponse([{ id: "U_PURGE", name: "purge-test" }]),
        slackListChannelsEmpty, // auto-discovery (private) — not found
        slackListChannelsEmpty, // public channel check — not found
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

      const call = await testCanister.testWeeklyReconciliationRunner(
        SLACK_TEST_TOKEN,
        some(ORG_ADMIN_CHANNEL_ID),
      );

      const result = (await mockSequentialResponses(pic, call, [
        slackUsersListResponse([
          { id: "U001", name: "alice", isPrimaryOwner: true },
        ]),
        slackChannelInfoResponse(ORG_ADMIN_CHANNEL_ID, ORG_ADMIN_CHANNEL_NAME), // org admin — info ok
        slackChannelMembersResponse(["U001"]), // org admin channel — members
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
        "unit-tests/control-plane-core/timers/weekly-reconciliation-runner/full-run",
        () =>
          testCanister.testWeeklyReconciliationRunner(SLACK_TEST_TOKEN, none),
        { ticks: 5, maxRounds: 20 },
      );

      const summary = expectSummary(result);

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
