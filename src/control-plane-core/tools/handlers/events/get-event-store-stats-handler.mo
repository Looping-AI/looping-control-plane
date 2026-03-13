import Json "mo:json";
import { obj; bool; int } "mo:json";
import EventStoreModel "../../../models/event-store-model";
import SlackAuthMiddleware "../../../middleware/slack-auth-middleware";
import Helpers "../handler-helpers";

module {
  /// Return event queue statistics (unprocessed, processed, failed counts).
  ///
  /// JSON args: {} (no arguments)
  ///
  /// Authorization: requires #IsPrimaryOwner or #IsOrgAdmin.
  public func handle(
    state : EventStoreModel.EventStoreState,
    uac : SlackAuthMiddleware.UserAuthContext,
    _args : Text,
  ) : async Text {
    switch (SlackAuthMiddleware.authorize(uac, [#IsPrimaryOwner, #IsOrgAdmin])) {
      case (#err(msg)) {
        Helpers.buildErrorResponse("Unauthorized: " # msg);
      };
      case (#ok(())) {
        let stats = EventStoreModel.sizes(state);
        Json.stringify(
          obj([
            ("success", bool(true)),
            ("unprocessedEvents", int(stats.unprocessed)),
            ("processedEvents", int(stats.processed)),
            ("failedEvents", int(stats.failed)),
          ]),
          null,
        );
      };
    };
  };
};
