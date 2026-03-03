/// Member Left Channel Handler
/// Handles member_left_channel events — fired when a user leaves a channel.
///
/// Resolves the Slack channel ID against workspace channel anchors.  When a
/// channel is an anchor for a workspace the handler updates the user's scope
/// in the SlackUserCache rather than unconditionally removing the membership:
///
///   - Leaving the admin channel while still in the member channel
///     → scope downgrades from #admin to #member.
///   - Leaving the member channel while still in the admin channel
///     → scope stays #admin (no change).
///   - Leaving the only channel the user was in
///     → workspace membership is removed entirely.
///
/// No-ops (with a warning log) when:
///   - the channel is not anchored to any workspace
///   - the user is not present in the Slack user cache

import Time "mo:core/Time";
import NormalizedEventTypes "../types/normalized-event-types";
import EventProcessingContextTypes "../types/event-processing-context";
import SlackUserModel "../../models/slack-user-model";
import WorkspaceModel "../../models/workspace-model";
import Logger "../../utilities/logger";

module {

  public func handle(
    event : {
      userId : Text;
      channelId : Text;
      channelType : Text;
      teamId : Text;
      eventTs : Text;
    },
    ctx : EventProcessingContextTypes.EventProcessingContext,
  ) : async NormalizedEventTypes.HandlerResult {
    Logger.log(
      #info,
      ?"MemberLeftChannelHandler",
      "member_left_channel | userId: " # event.userId #
      " | channelId: " # event.channelId #
      " | channelType: " # event.channelType #
      " | teamId: " # event.teamId,
    );

    // Resolve the channel to a workspace.
    // When a user leaves a channel that is an admin or member anchor, their
    // workspace membership is removed from the cache regardless of which role
    // the channel represents (both #adminChannel and #memberChannel revoke
    // the membership for that workspace).
    switch (WorkspaceModel.resolveWorkspaceByChannel(ctx.workspaces, event.channelId)) {
      case (#none) {
        Logger.log(
          #info,
          ?"MemberLeftChannelHandler",
          "Channel not anchored to any workspace, skipping membership removal: " # event.channelId,
        );
        return #ok([
          {
            action = "log_membership_leave";
            result = #ok;
            timestamp = Time.now();
          },
        ]);
      };
      case (#adminChannel(wsId)) {
        Logger.log(
          #info,
          ?"MemberLeftChannelHandler",
          "Channel is admin channel for workspace " # debug_show (wsId) # ", clearing admin-channel flag for user: " # event.userId,
        );
        switch (SlackUserModel.leaveAdminChannel(ctx.slackUsers, event.userId, wsId, #slackEvent(event.eventTs))) {
          case (#ok(_)) {};
          case (#err(msg)) {
            Logger.log(
              #warn,
              ?"MemberLeftChannelHandler",
              "Could not update workspace membership on admin-channel leave: " # msg,
            );
          };
        };
      };
      case (#memberChannel(wsId)) {
        Logger.log(
          #info,
          ?"MemberLeftChannelHandler",
          "Channel is member channel for workspace " # debug_show (wsId) # ", clearing member-channel flag for user: " # event.userId,
        );
        switch (SlackUserModel.leaveMemberChannel(ctx.slackUsers, event.userId, wsId, #slackEvent(event.eventTs))) {
          case (#ok(_)) {};
          case (#err(msg)) {
            Logger.log(
              #warn,
              ?"MemberLeftChannelHandler",
              "Could not update workspace membership on member-channel leave: " # msg,
            );
          };
        };
      };
    };

    #ok([
      {
        action = "update_membership_leave";
        result = #ok;
        timestamp = Time.now();
      },
    ]);
  };
};
