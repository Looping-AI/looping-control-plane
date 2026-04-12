import Json "mo:json";
import { str; obj; int; bool } "mo:json";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Set "mo:core/Set";
import Text "mo:core/Text";
import WorkspaceModel "../../../models/workspace-model";
import AgentModel "../../../models/agent-model";
import SlackAuthMiddleware "../../../middleware/slack-auth-middleware";
import SlackWrapper "../../../wrappers/slack-wrapper";
import Helpers "../handler-helpers";

module {
  public func handle(
    state : WorkspaceModel.WorkspacesState,
    agentRegistry : ?AgentModel.AgentRegistryState,
    uac : SlackAuthMiddleware.UserAuthContext,
    resolveSlackBotToken : Text -> ?Text,
    args : Text,
  ) : async Text {
    // Authorization: only org owners/admins may create workspaces
    switch (SlackAuthMiddleware.authorize(uac, [#IsPrimaryOwner, #IsOrgAdmin])) {
      case (#err(msg)) {
        return Helpers.buildErrorResponse("Unauthorized: " # msg);
      };
      case (#ok(())) {};
    };
    switch (Json.parse(args)) {
      case (#err(error)) {
        Helpers.buildErrorResponse("Failed to parse arguments: " # debug_show error);
      };
      case (#ok(json)) {
        let nameOpt = switch (Json.get(json, "name")) {
          case (?#string(s)) { ?s };
          case _ { null };
        };
        let channelIdOpt = switch (Json.get(json, "channelId")) {
          case (?#string(s)) { ?s };
          case _ { null };
        };
        switch (nameOpt, channelIdOpt) {
          case (?name, ?channelId) {
            // Resolve the Slack bot token on-demand via the bot token resolver
            let botToken = switch (resolveSlackBotToken("create-workspace")) {
              case (null) {
                return Helpers.buildErrorResponse("No Slack bot token configured. Store the slackBotToken secret on workspace 0 first.");
              };
              case (?t) { t };
            };

            // Verify the channel exists and the bot has access via conversations.info
            switch (await SlackWrapper.getChannelInfo(botToken, channelId)) {
              case (#err(msg)) {
                return Helpers.buildErrorResponse(
                  "Could not verify channel '" # channelId # "' with Slack: " # msg # ". " #
                  "Ensure the channel exists and the bot has been invited to it."
                );
              };
              case (#ok(_)) {};
            };

            switch (WorkspaceModel.createWorkspace(state, name)) {
              case (#err(msg)) { Helpers.buildErrorResponse(msg) };
              case (#ok(wsId)) {
                // Set the admin channel for the new workspace
                switch (WorkspaceModel.setAdminChannel(state, wsId, channelId)) {
                  case (#err(msg)) {
                    // Roll back: remove the workspace so state stays consistent
                    ignore WorkspaceModel.deleteWorkspace(state, wsId);
                    return Helpers.buildErrorResponse("Failed to set admin channel for workspace: " # msg);
                  };
                  case (#ok(_)) {};
                };

                // Register an #admin agent for the new workspace using the real channel ID
                switch (agentRegistry) {
                  case (?registry) {
                    let agentName = "ws-" # Nat.toText(wsId) # "-admin";
                    switch (
                      AgentModel.register(
                        agentName,
                        wsId,
                        #admin,
                        #api({ model = "openai/gpt-oss-120b" }),
                        [],
                        [],
                        [],
                        [],
                        Map.empty<Text, AgentModel.ToolState>(),
                        [],
                        Set.singleton<Text>(channelId),
                        registry,
                      )
                    ) {
                      case (#err(msg)) {
                        // Roll back: remove the workspace so state stays consistent
                        ignore WorkspaceModel.deleteWorkspace(state, wsId);
                        return Helpers.buildErrorResponse("Failed to register admin agent: " # msg);
                      };
                      case (#ok(_)) {};
                    };
                  };
                  case (null) {
                    // Roll back: remove the workspace so state stays consistent
                    let rollbackMsg = switch (WorkspaceModel.deleteWorkspace(state, wsId)) {
                      case (#err(rollbackErr)) {
                        " (rollback failed: " # rollbackErr # ")";
                      };
                      case (#ok(())) { "" };
                    };
                    return Helpers.buildErrorResponse("Failed to register admin agent: agent registry is unavailable" # rollbackMsg);
                  };
                };
                Json.stringify(
                  obj([
                    ("success", bool(true)),
                    ("id", int(wsId)),
                    ("name", str(name)),
                    ("adminChannelId", str(channelId)),
                    ("message", str("Workspace '" # name # "' created with ID " # Nat.toText(wsId) # " and admin channel " # channelId)),
                  ]),
                  null,
                );
              };
            };
          };
          case _ {
            Helpers.buildErrorResponse("Missing required fields: name and channelId");
          };
        };
      };
    };
  };
};
