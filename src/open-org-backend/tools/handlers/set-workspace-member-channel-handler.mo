import Json "mo:json";
import { str; obj; bool } "mo:json";
import Nat "mo:core/Nat";
import Int "mo:core/Int";
import WorkspaceModel "../../models/workspace-model";
import SlackAuthMiddleware "../../middleware/slack-auth-middleware";
import SlackWrapper "../../wrappers/slack-wrapper";
import Helpers "./handler-helpers";

module {
  public func handle(
    state : WorkspaceModel.WorkspacesState,
    uac : SlackAuthMiddleware.UserAuthContext,
    botToken : Text,
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
            // Authorization: org owners/admins or workspace admin of the target workspace
            switch (SlackAuthMiddleware.authorize(uac, [#IsPrimaryOwner, #IsOrgAdmin, #IsWorkspaceAdmin(wsId)])) {
              case (#err(msg)) {
                return Helpers.buildErrorResponse("Unauthorized: " # msg);
              };
              case (#ok(())) {};
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

            switch (WorkspaceModel.setMemberChannel(state, wsId, channelId)) {
              case (#err(msg)) { Helpers.buildErrorResponse(msg) };
              case (#ok(())) {
                Json.stringify(
                  obj([
                    ("success", bool(true)),
                    ("message", str("Member channel set to " # channelId # " for workspace " # Nat.toText(wsId))),
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
