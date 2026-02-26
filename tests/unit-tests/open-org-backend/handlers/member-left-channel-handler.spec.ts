import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import { createTestCanister, type TestCanisterService } from "../../../setup";

// Unwrap Candid opt ([] | [T]) to T | null
const unwrapOpt = <T>(opt: [] | [T]): T | null => (opt.length ? opt[0]! : null);

// ============================================
// MemberLeftChannelHandler tests
// Fired when a user leaves (or is removed from) a Slack channel.
// Handler resolves the channel against workspace channel anchors.
// If anchored: removes the user's workspace membership from the SlackUserCache.
// If not anchored: no-op (logged as info).
// ============================================

describe("MemberLeftChannelHandler", () => {
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
    const result = await testCanister.testMemberLeftChannelHandler(1n, {
      userId: "U_USER_1",
      channelId: "C_UNANCHORED",
      channelType: "public_channel",
      teamId: "T_TEST_TEAM",
      eventTs: "1700000001.000000",
    });

    expect("ok" in result).toBe(true);
  });

  it("should remove user from workspace members when leaving admin anchor channel", async () => {
    const userId = "U_USER_LEAVE_ADMIN";

    // First, add the user and give them admin workspace membership
    await testCanister.testTeamJoinHandler(1n, {
      userId: userId,
      displayName: "user_leave_admin",
      realName: ["User Leave Admin"],
      isPrimaryOwner: false,
      isOrgAdmin: false,
      eventTs: "1700000002.000000",
    });

    await testCanister.testMemberJoinedChannelHandler(1n, {
      userId: userId,
      channelId: "C_ADMIN_CHANNEL",
      channelType: "public_channel",
      teamId: "T_TEST_TEAM",
      eventTs: "1700000003.000000",
    });

    // Verify user has admin membership before leaving
    let user = unwrapOpt(await testCanister.getSlackUser(userId));
    expect(user?.workspaceMemberships.length).toBe(1);

    // Now they leave the admin channel
    const result = await testCanister.testMemberLeftChannelHandler(1n, {
      userId: userId,
      channelId: "C_ADMIN_CHANNEL",
      channelType: "public_channel",
      teamId: "T_TEST_TEAM",
      eventTs: "1700000004.000000",
    });

    expect("ok" in result).toBe(true);

    // Verify the membership was removed
    user = unwrapOpt(await testCanister.getSlackUser(userId));
    expect(user?.workspaceMemberships.length).toBe(0);
  });

  it("should remove user from workspace members when leaving member anchor channel", async () => {
    const userId = "U_USER_LEAVE_MEM";

    // First, add the user and give them member workspace membership
    await testCanister.testTeamJoinHandler(1n, {
      userId: userId,
      displayName: "user_leave_mem",
      realName: ["User Leave Mem"],
      isPrimaryOwner: false,
      isOrgAdmin: false,
      eventTs: "1700000005.000000",
    });

    await testCanister.testMemberJoinedChannelHandler(1n, {
      userId: userId,
      channelId: "C_MEMBER_CHANNEL",
      channelType: "public_channel",
      teamId: "T_TEST_TEAM",
      eventTs: "1700000006.000000",
    });

    // Verify user has member membership before leaving
    let user = unwrapOpt(await testCanister.getSlackUser(userId));
    expect(user?.workspaceMemberships.length).toBe(1);

    // Now they leave the member channel
    const result = await testCanister.testMemberLeftChannelHandler(1n, {
      userId: userId,
      channelId: "C_MEMBER_CHANNEL",
      channelType: "public_channel",
      teamId: "T_TEST_TEAM",
      eventTs: "1700000007.000000",
    });

    expect("ok" in result).toBe(true);

    // Verify the membership was removed
    user = unwrapOpt(await testCanister.getSlackUser(userId));
    expect(user?.workspaceMemberships.length).toBe(0);
  });

  it("should handle user leaving direct message channel", async () => {
    const result = await testCanister.testMemberLeftChannelHandler(1n, {
      userId: "U_USER_3",
      channelId: "D_DIRECT_MSG",
      channelType: "im",
      teamId: "T_TEST_TEAM",
      eventTs: "1700000008.000000",
    });

    expect("ok" in result).toBe(true);
  });

  it("should successfully handle join then leave cycle for member anchor", async () => {
    const channelId = "C_ROUND_TRIP_MEMBER";
    const userId = "U_CYCLE_USER_MEMBER";

    // First, create and add the user
    await testCanister.testTeamJoinHandler(1n, {
      userId: userId,
      displayName: "cycle_user_member",
      realName: ["Cycle User Member"],
      isPrimaryOwner: false,
      isOrgAdmin: false,
      eventTs: "1700000009.000000",
    });

    // Join the channel
    const joinResult = await testCanister.testMemberJoinedChannelHandler(1n, {
      userId: userId,
      channelId: channelId,
      channelType: "public_channel",
      teamId: "T_TEST_TEAM",
      eventTs: "1700000010.000000",
    });
    expect("ok" in joinResult).toBe(true);

    // Verify membership was added
    let user = unwrapOpt(await testCanister.getSlackUser(userId));
    expect(user?.workspaceMemberships.length).toBe(1);

    // Leave the channel
    const leaveResult = await testCanister.testMemberLeftChannelHandler(1n, {
      userId: userId,
      channelId: channelId,
      channelType: "public_channel",
      teamId: "T_TEST_TEAM",
      eventTs: "1700000011.000000",
    });
    expect("ok" in leaveResult).toBe(true);

    // Verify membership was removed
    user = unwrapOpt(await testCanister.getSlackUser(userId));
    expect(user?.workspaceMemberships.length).toBe(0);
  });

  it("should successfully handle join then leave cycle for admin anchor", async () => {
    const channelId = "C_ROUND_TRIP_ADMIN";
    const userId = "U_CYCLE_USER_ADMIN";

    // First, create and add the user
    await testCanister.testTeamJoinHandler(1n, {
      userId: userId,
      displayName: "cycle_user_admin",
      realName: ["Cycle User Admin"],
      isPrimaryOwner: false,
      isOrgAdmin: false,
      eventTs: "1700000012.000000",
    });

    // Join the channel
    const joinResult = await testCanister.testMemberJoinedChannelHandler(1n, {
      userId: userId,
      channelId: channelId,
      channelType: "public_channel",
      teamId: "T_TEST_TEAM",
      eventTs: "1700000013.000000",
    });
    expect("ok" in joinResult).toBe(true);

    // Verify membership was added
    let user = unwrapOpt(await testCanister.getSlackUser(userId));
    expect(user?.workspaceMemberships.length).toBe(1);

    // Leave the channel
    const leaveResult = await testCanister.testMemberLeftChannelHandler(1n, {
      userId: userId,
      channelId: channelId,
      channelType: "public_channel",
      teamId: "T_TEST_TEAM",
      eventTs: "1700000014.000000",
    });
    expect("ok" in leaveResult).toBe(true);

    // Verify membership was removed
    user = unwrapOpt(await testCanister.getSlackUser(userId));
    expect(user?.workspaceMemberships.length).toBe(0);
  });

  it("should handle gracefully when user leaving was not in cache", async () => {
    const channelId = "C_MEMBER_CHANNEL_2";

    const result = await testCanister.testMemberLeftChannelHandler(1n, {
      userId: "U_GHOST_USER",
      channelId: channelId,
      channelType: "public_channel",
      teamId: "T_TEST_TEAM",
      eventTs: "1700000015.000000",
    });

    // Handler should still succeed even if user isn't in cache (with warning log)
    expect("ok" in result).toBe(true);

    // User should not be in cache
    const user = unwrapOpt(await testCanister.getSlackUser("U_GHOST_USER"));
    expect(user).toBeNull();
  });
});
