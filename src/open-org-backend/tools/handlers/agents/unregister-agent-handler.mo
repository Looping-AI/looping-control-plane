import Json "mo:json";
import { str; obj; bool } "mo:json";
import Int "mo:core/Int";
import AgentModel "../../../models/agent-model";
import SlackAuthMiddleware "../../../middleware/slack-auth-middleware";
import Helpers "../handler-helpers";

module {
  public func handle(
    state : AgentModel.AgentRegistryState,
    uac : SlackAuthMiddleware.UserAuthContext,
    args : Text,
  ) : async Text {
    switch (SlackAuthMiddleware.authorize(uac, [#IsPrimaryOwner, #IsOrgAdmin])) {
      case (#err(msg)) {
        return Helpers.buildErrorResponse("Unauthorized: " # msg);
      };
      case (#ok(())) {};
    };

    switch (Json.parse(args)) {
      case (#err(e)) {
        Helpers.buildErrorResponse("Failed to parse arguments: " # debug_show e);
      };
      case (#ok(json)) {
        let id = switch (Json.get(json, "id")) {
          case (?#number(#int n)) {
            if (n >= 0) { Int.abs(n) } else {
              return Helpers.buildErrorResponse("id must be a non-negative integer");
            };
          };
          case _ {
            return Helpers.buildErrorResponse("Missing required field: id");
          };
        };

        switch (AgentModel.unregisterById(id, state)) {
          case (#err(msg)) { Helpers.buildErrorResponse(msg) };
          case (#ok(_)) {
            Json.stringify(
              obj([
                ("success", bool(true)),
                ("message", str("Agent unregistered successfully")),
              ]),
              null,
            );
          };
        };
      };
    };
  };
};
