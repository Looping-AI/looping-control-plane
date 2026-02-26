import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import { createTestCanister, type TestCanisterService } from "../../../setup";

// Unwrap Candid opt ([] | [T]) to T | null
const unwrapOpt = <T>(opt: [] | [T]): T | null => (opt.length ? opt[0]! : null);

// ============================================
// MemberJoinedChannelHandler tests
// Fired when a user joins a Slack channel.
// Handler resolves the channel against workspace admin/member channel anchors.
// If anchored: updates the user's workspace membership in the SlackUserCache.
// If not anchored: no-op (logged as info).
// ============================================

describe("MemberJoinedChannelHandler", () => {
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

  it("should be a no-op when channel has no workspace anchor", async () => {
    const result = await testCanister.testMemberJoinedChannelHandler(1n, {
      userId: "U_USER_1",
      channelId: "C_UNANCHORED",
      channelType: "public_channel",
      teamId: "T_TEST_TEAM",
      eventTs: "1700000001.000000",
    });

    expect("ok" in result).toBe(true);
  });

  it("should add user to workspace members when channel is admin anchor", async () => {
    // First, add the user to the cache via team_join
    await testCanister.testTeamJoinHandler(1n, {
      userId: "U_USER_ADMIN_1",
      displayName: "user_admin_1",
      realName: ["User Admin 1"],
      isPrimaryOwner: false,
      isOrgAdmin: false,
      eventTs: "1700000002.000000",
    });

    // Now add them to the admin channel anchor
    const result = await testCanister.testMemberJoinedChannelHandler(1n, {
      userId: "U_USER_ADMIN_1",
      channelId: "C_ADMIN_CHANNEL",
      channelType: "public_channel",
      teamId: "T_TEST_TEAM",
      eventTs: "1700000003.000000",
    });

    expect("ok" in result).toBe(true);

    // Verify the user now has workspace membership as admin
    const user = unwrapOpt(await testCanister.getSlackUser("U_USER_ADMIN_1"));
    expect(user).not.toBeNull();
    if (user) {
      const membership = user.workspaceMemberships.find(
        ([wsId]: [bigint, unknown]) => wsId === 1n,
      );
      expect(membership).toBeDefined();
      if (membership) {
        expect(membership[1]).toEqual({ admin: null });
      }
    }
  });

  it("should add user to workspace members when channel is member anchor", async () => {
    // First, add the user to the cache via team_join
    await testCanister.testTeamJoinHandler(1n, {
      userId: "U_USER_MEM_1",
      displayName: "user_mem_1",
      realName: ["User Mem 1"],
      isPrimaryOwner: false,
      isOrgAdmin: false,
      eventTs: "1700000004.000000",
    });

    // Now add them to the member channel anchor
    const result = await testCanister.testMemberJoinedChannelHandler(1n, {
      userId: "U_USER_MEM_1",
      channelId: "C_MEMBER_CHANNEL",
      channelType: "public_channel",
      teamId: "T_TEST_TEAM",
      eventTs: "1700000005.000000",
    });

    expect("ok" in result).toBe(true);

    // Verify the user now has workspace membership as member
    const user = unwrapOpt(await testCanister.getSlackUser("U_USER_MEM_1"));
    expect(user).not.toBeNull();
    if (user) {
      const membership = user.workspaceMemberships.find(
        ([wsId]: [bigint, unknown]) => wsId === 1n,
      );
      expect(membership).toBeDefined();
      if (membership) {
        expect(membership[1]).toEqual({ member: null });
      }
    }
  });

  it("should handle direct message channels gracefully", async () => {
    const result = await testCanister.testMemberJoinedChannelHandler(1n, {
      userId: "U_USER_3",
      channelId: "D_DIRECT_MSG",
      channelType: "im",
      teamId: "T_TEST_TEAM",
      eventTs: "1700000006.000000",
    });

    expect("ok" in result).toBe(true);
  });

  it("should add existing user (from team_join) to workspace when joining anchored channel", async () => {
    const userId = "U_USER_4";

    // First, add user via team_join
    await testCanister.testTeamJoinHandler(1n, {
      userId: userId,
      displayName: "user_4",
      realName: ["User 4"],
      isPrimaryOwner: false,
      isOrgAdmin: false,
      eventTs: "1700000007.000000",
    });

    // Then process member_joined_channel (user should be found in cache)
    const result = await testCanister.testMemberJoinedChannelHandler(1n, {
      userId: userId,
      channelId: "C_MEMBER_CHANNEL_2",
      channelType: "public_channel",
      teamId: "T_TEST_TEAM",
      eventTs: "1700000008.000000",
    });

    expect("ok" in result).toBe(true);

    // Verify user exists and can be queried
    const user = unwrapOpt(await testCanister.getSlackUser(userId));
    expect(user).not.toBeNull();
  });
});
