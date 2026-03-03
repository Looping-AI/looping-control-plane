import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import { createTestCanister, type TestCanisterService } from "../../../setup";

// Unwrap Candid opt ([] | [T]) to T | null
const unwrapOpt = <T>(opt: [] | [T]): T | null => (opt.length ? opt[0]! : null);

// ============================================
// TeamJoinHandler tests
// Fired when a brand-new user joins the Slack workspace.
// Handler upserts the user in the SlackUserCache with basic org-level info.
// Workspace memberships are populated later via member_joined_channel events.
// ============================================

describe("TeamJoinHandler", () => {
  let pic: PocketIc;
  let testCanister: Actor<TestCanisterService>;

  beforeEach(async () => {
    const testEnv = await createTestCanister();
    pic = testEnv.pic;
    testCanister = testEnv.actor;
    // Reset cache for test isolation
    await testCanister.resetSlackUserCache();
  });

  afterEach(async () => {
    await pic.tearDown();
  });

  it("should upsert a new user in SlackUserCache with basic org-level info", async () => {
    const result = await testCanister.testTeamJoinHandler({
      userId: "U_NEW_USER",
      displayName: "newuser",
      realName: ["New User"],
      isPrimaryOwner: false,
      isOrgAdmin: false,
      eventTs: "1700000001.000000",
    });

    expect("ok" in result).toBe(true);

    // Verify the user was added to the cache with correct properties
    const user = unwrapOpt(await testCanister.getSlackUser("U_NEW_USER"));
    expect(user).not.toBeNull();
    if (user) {
      expect(user.slackUserId).toBe("U_NEW_USER");
      expect(user.displayName).toBe("New User");
      expect(user.isPrimaryOwner).toBe(false);
      expect(user.isOrgAdmin).toBe(false);
      expect(user.workspaceMemberships.length).toBe(0);
    }
  });

  it("should process team_join when real_name is absent and use display name", async () => {
    const result = await testCanister.testTeamJoinHandler({
      userId: "U_NO_REALNAME",
      displayName: "norealname",
      realName: [],
      isPrimaryOwner: false,
      isOrgAdmin: false,
      eventTs: "1700000101.000001",
    });

    expect("ok" in result).toBe(true);

    // Verify user was added with display name fallback
    const user = unwrapOpt(await testCanister.getSlackUser("U_NO_REALNAME"));
    expect(user).not.toBeNull();
    if (user) {
      expect(user.displayName).toBe("norealname");
    }
  });

  it("should mark user as org admin when is_admin is true", async () => {
    const result = await testCanister.testTeamJoinHandler({
      userId: "U_ORG_ADMIN",
      displayName: "orgadmin",
      realName: ["Org Admin"],
      isPrimaryOwner: false,
      isOrgAdmin: true,
      eventTs: "1700000102.000001",
    });

    expect("ok" in result).toBe(true);

    // Verify user was marked as org admin
    const user = unwrapOpt(await testCanister.getSlackUser("U_ORG_ADMIN"));
    expect(user).not.toBeNull();
    if (user) {
      expect(user.isOrgAdmin).toBe(true);
      expect(user.isPrimaryOwner).toBe(false);
    }
  });

  it("should mark user as primary owner when is_primary_owner is true", async () => {
    const result = await testCanister.testTeamJoinHandler({
      userId: "U_PRIMARY_OWNER",
      displayName: "owner",
      realName: ["Primary Owner"],
      isPrimaryOwner: true,
      isOrgAdmin: true,
      eventTs: "1700000103.000001",
    });

    expect("ok" in result).toBe(true);

    // Verify user was marked as primary owner
    const user = unwrapOpt(await testCanister.getSlackUser("U_PRIMARY_OWNER"));
    expect(user).not.toBeNull();
    if (user) {
      expect(user.isPrimaryOwner).toBe(true);
      expect(user.isOrgAdmin).toBe(true);
    }
  });
});
