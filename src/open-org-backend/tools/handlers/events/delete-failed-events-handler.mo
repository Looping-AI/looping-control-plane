import Json "mo:json";
import { obj; bool; int } "mo:json";
import EventStoreModel "../../../models/event-store-model";
import SlackAuthMiddleware "../../../middleware/slack-auth-middleware";
import Helpers "../handler-helpers";

module {
  /// Delete failed event(s).
  ///
  /// JSON args: { eventId?: string }
  ///   - omitting eventId deletes ALL failed events
  ///   - providing eventId deletes only that one event
  ///
  /// Authorization: requires #IsPrimaryOwner or #IsOrgAdmin.
  public func handle(
    state : EventStoreModel.EventStoreState,
    uac : SlackAuthMiddleware.UserAuthContext,
    args : Text,
  ) : async Text {
    switch (SlackAuthMiddleware.authorize(uac, [#IsPrimaryOwner, #IsOrgAdmin])) {
      case (#err(msg)) {
        Helpers.buildErrorResponse("Unauthorized: " # msg);
      };
      case (#ok(())) {
        switch (Json.parse(args)) {
          case (#err(e)) {
            Helpers.buildErrorResponse("Failed to parse arguments: " # debug_show e);
          };
          case (#ok(json)) {
            let eventIdOpt : ?Text = switch (Json.get(json, "eventId")) {
              case (?#string(s)) { ?s };
              case _ { null };
            };
            let deleted = EventStoreModel.deleteFailed(state, eventIdOpt);
            Json.stringify(
              obj([
                ("success", bool(true)),
                ("deleted", int(deleted)),
              ]),
              null,
            );
          };
        };
      };
    };
  };
};
