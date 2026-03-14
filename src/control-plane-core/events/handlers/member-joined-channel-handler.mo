/// Member Joined Channel Handler
/// Handles member_joined_channel events — fired when a user joins a channel.
///
/// Resolves the Slack channel ID against workspace channel anchors. If the channel
/// is an admin or member channel for a known workspace, the user's workspace
/// membership in the SlackUserCache is updated accordingly.
///
/// No-ops (with a warning log) when:
///   - the channel is not anchored to any workspace
///   - the user is not yet present in the Slack user cache

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
      ?"MemberJoinedChannelHandler",
      "member_joined_channel | userId: " # event.userId #
      " | channelId: " # event.channelId #
      " | channelType: " # event.channelType #
      " | teamId: " # event.teamId,
    );

    // Resolve the channel to a workspace and scope.
    switch (WorkspaceModel.resolveWorkspaceByChannel(ctx.workspaces, event.channelId)) {
      case (#none) {
        Logger.log(
          #info,
          ?"MemberJoinedChannelHandler",
          "Channel not anchored to any workspace, skipping membership update: " # event.channelId,
        );
        return #ok([
          {
            action = "log_membership_join";
            result = #ok;
            timestamp = Time.now();
          },
        ]);
      };
      case (#adminChannel(wsId)) {
        Logger.log(
          #info,
          ?"MemberJoinedChannelHandler",
          "Channel is admin channel for workspace " # debug_show (wsId) # ", granting #admin scope to user: " # event.userId,
        );
        switch (SlackUserModel.joinAdminChannel(ctx.slackUsers, event.userId, wsId, #slackEvent(event.eventTs))) {
          case (#ok(())) {};
          case (#err(msg)) {
            Logger.log(
              #warn,
              ?"MemberJoinedChannelHandler",
              "Could not update workspace membership (user not in cache?): " # msg,
            );
          };
        };
      };
      case (#memberChannel(wsId)) {
        Logger.log(
          #info,
          ?"MemberJoinedChannelHandler",
          "Channel is member channel for workspace " # debug_show (wsId) # ", granting #member scope to user: " # event.userId,
        );
        switch (SlackUserModel.joinMemberChannel(ctx.slackUsers, event.userId, wsId, #slackEvent(event.eventTs))) {
          case (#ok(())) {};
          case (#err(msg)) {
            Logger.log(
              #warn,
              ?"MemberJoinedChannelHandler",
              "Could not update workspace membership (user not in cache?): " # msg,
            );
          };
        };
      };
    };

    #ok([
      {
        action = "update_membership_join";
        result = #ok;
        timestamp = Time.now();
      },
    ]);
  };
};
