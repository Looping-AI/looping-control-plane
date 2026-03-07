import Json "mo:json";
import { str; obj; bool; arr; int } "mo:json";
import Array "mo:core/Array";
import EventStoreModel "../../../models/event-store-model";
import NormalizedEventTypes "../../../events/types/normalized-event-types";
import SlackAuthMiddleware "../../../middleware/slack-auth-middleware";
import Helpers "../handler-helpers";

module {
  /// List all failed events with their error messages and metadata.
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
        let events = EventStoreModel.listFailed(state);
        let items = Array.map<NormalizedEventTypes.Event, Json.Json>(events, eventToJson);
        Json.stringify(
          obj([
            ("success", bool(true)),
            ("events", arr(items)),
          ]),
          null,
        );
      };
    };
  };

  private func eventToJson(event : NormalizedEventTypes.Event) : Json.Json {
    let failedAtJson : Json.Json = switch (event.failedAt) {
      case (null) { #null_ };
      case (?t) { int(t) };
    };
    obj([
      ("eventId", str(event.eventId)),
      ("source", str(NormalizedEventTypes.sourcePrefix(event.source))),
      ("enqueuedAt", int(event.enqueuedAt)),
      ("failedAt", failedAtJson),
      ("failedError", str(event.failedError)),
    ]);
  };
};
