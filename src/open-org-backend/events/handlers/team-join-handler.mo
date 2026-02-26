/// Team Join Handler
/// Handles the team_join event — fired when a new user joins the Slack workspace.
///
/// Responsibilities:
///   - Upsert the new user in the Slack user cache with basic org-level info
///   - No workspace memberships are set here; those are derived from channel
///     membership events (member_joined_channel) resolved against workspace
///     channel anchors once Phase 0.5 (workspace-to-channel mapping) is in place.

import Time "mo:core/Time";
import NormalizedEventTypes "../types/normalized-event-types";
import EventProcessingContextTypes "../types/event-processing-context";
import SlackUserModel "../../models/slack-user-model";
import Logger "../../utilities/logger";

module {

  public func handle(
    workspaceId : Nat,
    event : {
      userId : Text;
      displayName : Text;
      realName : ?Text;
      isPrimaryOwner : Bool;
      isOrgAdmin : Bool;
      eventTs : Text;
    },
    ctx : EventProcessingContextTypes.EventProcessingContext,
  ) : async NormalizedEventTypes.HandlerResult {
    Logger.log(
      #info,
      ?"TeamJoinHandler",
      "team_join in workspace " # debug_show (workspaceId) #
      " | userId: " # event.userId #
      " | displayName: " # event.displayName #
      " | isPrimaryOwner: " # debug_show (event.isPrimaryOwner) #
      " | isOrgAdmin: " # debug_show (event.isOrgAdmin),
    );

    // Resolve the best display name: prefer real_name when present.
    let displayName = switch (event.realName) {
      case (?rn) { rn };
      case (null) { event.displayName };
    };

    // Upsert in cache. For a brand-new member, workspace memberships start empty;
    // they will be populated when the user joins relevant tracked channels
    // (member_joined_channel handler, resolved via Phase 0.5 channel anchors).
    let entry = SlackUserModel.newEntry(
      event.userId,
      displayName,
      event.isPrimaryOwner,
      event.isOrgAdmin,
    );
    SlackUserModel.upsertUser(ctx.slackUsers, entry);

    Logger.log(
      #info,
      ?"TeamJoinHandler",
      "Upserted slack user in cache: " # event.userId,
    );

    #ok([
      {
        action = "upsert_slack_user";
        result = #ok;
        timestamp = Time.now();
      },
    ]);
  };
};
