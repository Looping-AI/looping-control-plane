import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor, DeferredActor } from "@dfinity/pic";
import { generateRandomIdentity } from "@dfinity/pic";
import {
  createBackendCanister,
  idlFactory,
  type _SERVICE,
  SLACK_TEST_TOKEN,
  SLACK_ORG_ADMIN_CHANNEL_ID,
  SLACK_SPECS_CHANNEL_ID,
} from "../../setup.ts";
import { expectOk, expectErr, expectSome } from "../../helpers.ts";
import {
  withCassette,
  withCassetteMulti,
  shouldSkipWithoutCassette,
} from "../../lib/cassette.ts";

// Cassette base path for all channel-verification tests.
const CASSETTE_BASE = "integration-tests/open-org-backend/workspace-channels";

// Helper to create a deferred actor for the main canister using the owner identity.
// The deferred actor pattern lets PocketIC intercept and mock HTTP outcalls.
function makeDeferredActor(
  pic: PocketIc,
  canisterId: Awaited<ReturnType<typeof createBackendCanister>>["canisterId"],
  ownerIdentity: ReturnType<typeof generateRandomIdentity>,
): DeferredActor<_SERVICE> {
  const deferredActor = pic.createDeferredActor<_SERVICE>(
    idlFactory,
    canisterId,
  );
  deferredActor.setIdentity(ownerIdentity);
  return deferredActor;
}

describe("Workspace Channel Anchors", () => {
  let pic: PocketIc;
  let actor: Actor<_SERVICE>;
  let canisterId: Awaited<
    ReturnType<typeof createBackendCanister>
  >["canisterId"];
  let ownerIdentity: ReturnType<typeof generateRandomIdentity>;

  beforeEach(async () => {
    const testEnv = await createBackendCanister();
    pic = testEnv.pic;
    actor = testEnv.actor;
    canisterId = testEnv.canisterId;
    ownerIdentity = testEnv.ownerIdentity;
  });

  afterEach(async () => {
    await pic.tearDown();
  });

  // ---------------------------------------------------------------------------
  // listWorkspaces — default workspace 0
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
  // setWorkspaceAdminChannel
  //
  // Tests are split into two groups:
  //   (A) Fast-fail tests — fail before any HTTP call (auth, workspace lookup,
  //       or missing token). Use the regular actor; no cassette needed.
  //   (B) Slack API-verified tests — the canister calls conversations.info to
  //       validate the channel. Use a deferred actor + cassette.
  // ---------------------------------------------------------------------------

  describe("setWorkspaceAdminChannel", () => {
    // -----------------------------------------------------------------------
    // (A) Fast-fail tests — no HTTP outcall required
    // -----------------------------------------------------------------------

    it("should reject non-admin caller", async () => {
      actor.setIdentity(generateRandomIdentity());
      const result = await actor.setWorkspaceAdminChannel(0n, "C12345");
      expect(expectErr(result)).toContain("Only org owner");
    });

    it("should reject unknown workspace ID", async () => {
      const result = await actor.setWorkspaceAdminChannel(999n, "C12345");
      expect(expectErr(result)).toEqual("Workspace not found.");
    });

    it("should reject when Slack bot token is not configured", async () => {
      // No token stored — fails at token lookup before any HTTP outcall.
      const result = await actor.setWorkspaceAdminChannel(0n, "C_ADMIN_1");
      expect(expectErr(result)).toContain("Slack bot token not configured");
    });

    it("workspace admin cannot set admin channel for default workspace (org owner only)", async () => {
      const adminIdentity = generateRandomIdentity();
      await actor.addWorkspaceAdmin(0n, adminIdentity.getPrincipal());
      actor.setIdentity(adminIdentity);
      const result = await actor.setWorkspaceAdminChannel(0n, "C_ADMIN_2");
      expect(expectErr(result)).toContain("Only org owner");
    });

    // -----------------------------------------------------------------------
    // (B) Slack API-verified tests — cassette required
    //
    // Run with RECORD_CASSETTES=true to record against a real Slack workspace.
    // -----------------------------------------------------------------------

    it("should verify channel via Slack API and set admin channel for default workspace", async () => {
      if (
        await shouldSkipWithoutCassette(
          `${CASSETTE_BASE}/set-admin-channel-ws0`,
        )
      )
        return;

      await actor.storeSecret(0n, { slackBotToken: null }, SLACK_TEST_TOKEN);
      const deferredActor = makeDeferredActor(pic, canisterId, ownerIdentity);

      const { result } = await withCassette(
        pic,
        `${CASSETTE_BASE}/set-admin-channel-ws0`,
        () =>
          deferredActor.setWorkspaceAdminChannel(
            0n,
            SLACK_ORG_ADMIN_CHANNEL_ID,
          ),
        { ticks: 5, maxRounds: 3 },
      );

      expect(await result).toEqual({ ok: null });

      const list = expectOk(await actor.listWorkspaces());
      const ws = list.find((w) => w.id === 0n)!;
      expect(expectSome(ws.adminChannelId)).toEqual(SLACK_ORG_ADMIN_CHANNEL_ID);
    });

    it("should overwrite an existing admin channel", async () => {
      if (
        await shouldSkipWithoutCassette(
          `${CASSETTE_BASE}/overwrite-admin-channel`,
        )
      )
        return;

      await actor.storeSecret(0n, { slackBotToken: null }, SLACK_TEST_TOKEN);
      const deferredActor = makeDeferredActor(pic, canisterId, ownerIdentity);

      const { results } = await withCassetteMulti(
        pic,
        `${CASSETTE_BASE}/overwrite-admin-channel`,
        [
          () =>
            deferredActor.setWorkspaceAdminChannel(
              0n,
              SLACK_ORG_ADMIN_CHANNEL_ID,
            ),
          () =>
            deferredActor.setWorkspaceAdminChannel(
              0n,
              SLACK_ORG_ADMIN_CHANNEL_ID,
            ),
        ],
        { ticks: 5 },
      );

      expect(await results[0]).toEqual({ ok: null });
      expect(await results[1]).toEqual({ ok: null });

      const list = expectOk(await actor.listWorkspaces());
      const ws = list.find((w) => w.id === 0n)!;
      expect(expectSome(ws.adminChannelId)).toEqual(SLACK_ORG_ADMIN_CHANNEL_ID);
    });

    it("should reject when Slack reports the channel has the wrong name for workspace 0", async () => {
      if (
        await shouldSkipWithoutCassette(
          `${CASSETTE_BASE}/reject-wrong-channel-name`,
        )
      )
        return;

      await actor.storeSecret(0n, { slackBotToken: null }, SLACK_TEST_TOKEN);
      const deferredActor = makeDeferredActor(pic, canisterId, ownerIdentity);

      const { result } = await withCassette(
        pic,
        `${CASSETTE_BASE}/reject-wrong-channel-name`,
        () =>
          deferredActor.setWorkspaceAdminChannel(0n, SLACK_SPECS_CHANNEL_ID),
        { ticks: 5, maxRounds: 3 },
      );

      const err = expectErr(await result);
      expect(err).toContain("#looping-ai-org-admins");
    });

    it("should reject when channel is not found or not accessible in Slack", async () => {
      if (
        await shouldSkipWithoutCassette(
          `${CASSETTE_BASE}/reject-channel-not-found`,
        )
      )
        return;

      await actor.storeSecret(0n, { slackBotToken: null }, SLACK_TEST_TOKEN);
      const deferredActor = makeDeferredActor(pic, canisterId, ownerIdentity);

      const { result } = await withCassette(
        pic,
        `${CASSETTE_BASE}/reject-channel-not-found`,
        () => deferredActor.setWorkspaceAdminChannel(0n, "C_MISSING"),
        { ticks: 5, maxRounds: 3 },
      );

      const err = expectErr(await result);
      expect(err).toContain("Could not verify channel");
      expect(err).toContain("C_MISSING");
    });
  });

  // ---------------------------------------------------------------------------
  // setWorkspaceMemberChannel
  //
  // Same split as setWorkspaceAdminChannel: fast-fail tests first,
  // then Slack API-verified tests that require a cassette.
  // ---------------------------------------------------------------------------

  describe("setWorkspaceMemberChannel", () => {
    // -----------------------------------------------------------------------
    // (A) Fast-fail tests — no HTTP outcall required
    // -----------------------------------------------------------------------

    it("should reject non-admin caller", async () => {
      actor.setIdentity(generateRandomIdentity());
      const result = await actor.setWorkspaceMemberChannel(0n, "C12345");
      expect(expectErr(result)).toContain("Only org owner");
    });

    it("should reject unknown workspace ID", async () => {
      const result = await actor.setWorkspaceMemberChannel(999n, "C12345");
      expect(expectErr(result)).toEqual("Workspace not found.");
    });

    it("should reject when Slack bot token is not configured", async () => {
      // No token stored — fails at token lookup before any HTTP outcall.
      const result = await actor.setWorkspaceMemberChannel(0n, "C_MEMBER_1");
      expect(expectErr(result)).toContain("Slack bot token not configured");
    });

    // -----------------------------------------------------------------------
    // (B) Slack API-verified tests — cassette required
    // -----------------------------------------------------------------------

    it("should verify channel via Slack API and set member channel for default workspace", async () => {
      if (
        await shouldSkipWithoutCassette(`${CASSETTE_BASE}/set-member-channel`)
      )
        return;

      await actor.storeSecret(0n, { slackBotToken: null }, SLACK_TEST_TOKEN);
      const deferredActor = makeDeferredActor(pic, canisterId, ownerIdentity);

      const { result } = await withCassette(
        pic,
        `${CASSETTE_BASE}/set-member-channel`,
        () =>
          deferredActor.setWorkspaceMemberChannel(0n, SLACK_SPECS_CHANNEL_ID),
        { ticks: 5, maxRounds: 3 },
      );

      expect(await result).toEqual({ ok: null });

      const list = expectOk(await actor.listWorkspaces());
      const ws = list.find((w) => w.id === 0n)!;
      expect(expectSome(ws.memberChannelId)).toEqual(SLACK_SPECS_CHANNEL_ID);
    });

    it("should not affect the admin channel when setting member channel", async () => {
      if (await shouldSkipWithoutCassette(`${CASSETTE_BASE}/both-channels`))
        return;

      await actor.storeSecret(0n, { slackBotToken: null }, SLACK_TEST_TOKEN);
      const deferredActor = makeDeferredActor(pic, canisterId, ownerIdentity);

      const { results } = await withCassetteMulti(
        pic,
        `${CASSETTE_BASE}/both-channels`,
        [
          () =>
            deferredActor.setWorkspaceAdminChannel(
              0n,
              SLACK_ORG_ADMIN_CHANNEL_ID,
            ),
          () =>
            deferredActor.setWorkspaceMemberChannel(0n, SLACK_SPECS_CHANNEL_ID),
        ],
        { ticks: 5 },
      );

      expect(await results[0]).toEqual({ ok: null });
      expect(await results[1]).toEqual({ ok: null });

      const list = expectOk(await actor.listWorkspaces());
      const ws = list.find((w) => w.id === 0n)!;
      expect(expectSome(ws.adminChannelId)).toEqual(SLACK_ORG_ADMIN_CHANNEL_ID);
      expect(expectSome(ws.memberChannelId)).toEqual(SLACK_SPECS_CHANNEL_ID);
    });
  });

  // ---------------------------------------------------------------------------
  // createWorkspace seeds all per-workspace maps correctly
  // ---------------------------------------------------------------------------

  describe("createWorkspace seeds all per-workspace maps", () => {
    it("getWorkspaceMembers works on freshly created workspace", async () => {
      const wsId = expectOk(await actor.createWorkspace("Engineering"));
      const result = await actor.getWorkspaceMembers(wsId);
      expect(expectOk(result)).toEqual([]);
    });
  });
});
