import Json "mo:json";
import { str; obj; bool } "mo:json";
import Nat "mo:core/Nat";
import Int "mo:core/Int";
import Set "mo:core/Set";
import Text "mo:core/Text";
import WorkspaceModel "../../../models/workspace-model";
import AgentModel "../../../models/agent-model";
import SlackAuthMiddleware "../../../middleware/slack-auth-middleware";
import SlackWrapper "../../../wrappers/slack-wrapper";
import Constants "../../../constants";
import Helpers "../handler-helpers"

module {
  public func handle(
    state : WorkspaceModel.WorkspacesState,
    agentRegistry : AgentModel.AgentRegistryState,
    uac : SlackAuthMiddleware.UserAuthContext,
    resolveSlackBotToken : Text -> ?Text,
    args : Text,
  ) : async Text {
    switch (Json.parse(args)) {
      case (#err(error)) {
        Helpers.buildErrorResponse("Failed to parse arguments: " # debug_show error);
      };
      case (#ok(json)) {
        let wsIdOpt : ?Nat = switch (Json.get(json, "workspaceId")) {
          case (?#number(#int n)) {
            if (n >= 0) { ?Int.abs(n) } else { null };
          };
          case _ { null };
        };
        let channelIdOpt = switch (Json.get(json, "channelId")) {
          case (?#string(s)) { ?s };
          case _ { null };
        };
        switch (wsIdOpt, channelIdOpt) {
          case (?wsId, ?channelId) {
            // Authorization: workspace 0 is org-owner only; all others allow org/workspace admins
            let requiredRoles : [SlackAuthMiddleware.AuthStep] = if (wsId == 0) {
              [#IsPrimaryOwner];
            } else {
              [#IsPrimaryOwner, #IsOrgAdmin, #IsWorkspaceAdmin(wsId)];
            };
            switch (SlackAuthMiddleware.authorize(uac, requiredRoles)) {
              case (#err(msg)) {
                return Helpers.buildErrorResponse("Unauthorized: " # msg);
              };
              case (#ok(())) {};
            };

            // Resolve the Slack bot token on-demand via the bot token resolver
            let botToken = switch (resolveSlackBotToken("set-workspace-admin-channel")) {
              case (null) {
                return Helpers.buildErrorResponse("No Slack bot token configured. Store the slackBotToken secret on workspace 0 first.");
              };
              case (?t) { t };
            };

            // Verify the channel exists and the bot has access via conversations.info
            let channelInfo = switch (await SlackWrapper.getChannelInfo(botToken, channelId)) {
              case (#err(msg)) {
                return Helpers.buildErrorResponse(
                  "Could not verify channel '" # channelId # "' with Slack: " # msg # ". " #
                  "Ensure the channel exists and the bot has been invited to it."
                );
              };
              case (#ok(info)) { info };
            };

            // For workspace 0, enforce the required channel name
            if (wsId == 0) {
              if (channelInfo.name != Constants.ORG_ADMIN_CHANNEL_NAME) {
                return Helpers.buildErrorResponse(
                  "The org-admin channel must be named '#" # Constants.ORG_ADMIN_CHANNEL_NAME # "', " #
                  "but '#" # channelInfo.name # "' was found. " #
                  "Please rename the Slack channel before anchoring it."
                );
              };
            };

            switch (WorkspaceModel.setAdminChannel(state, wsId, channelId)) {
              case (#err(msg)) { Helpers.buildErrorResponse(msg) };
              case (#ok(())) {
                // Keep the workspace's admin agent allowedChannelIds in sync with
                // the new admin channel. Replace whatever was there (including the
                // PENDING_ADMIN_CHANNEL placeholder) with exactly {channelId}.
                switch (AgentModel.lookupAdminAgentByWorkspace(wsId, agentRegistry)) {
                  case (?adminAgent) {
                    ignore AgentModel.updateById(
                      adminAgent.id,
                      null,
                      null,
                      null,
                      null,
                      null,
                      null,
                      null,
                      null,
                      null,
                      ?Set.singleton<Text>(channelId),
                      agentRegistry,
                    );
                  };
                  case (null) {}; // no admin agent for this workspace yet
                };
                Json.stringify(
                  obj([
                    ("success", bool(true)),
                    ("message", str("Admin channel set to " # channelId # " for workspace " # Nat.toText(wsId))),
                  ]),
                  null,
                );
              };
            };
          };
          case _ {
            Helpers.buildErrorResponse("Missing required fields: workspaceId and channelId");
          };
        };
      };
    };
  };
};
