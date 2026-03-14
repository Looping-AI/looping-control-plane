import Json "mo:json";
import { str; obj; int; bool } "mo:json";
import Int "mo:core/Int";
import Nat "mo:core/Nat";
import Map "mo:core/Map";
import ValueStreamModel "../../../models/value-stream-model";
import ObjectiveModel "../../../models/objective-model";
import Helpers "../handler-helpers";

module {
  public func handle(
    workspaceId : Nat,
    valueStreamsMap : ValueStreamModel.ValueStreamsMap,
    workspaceObjectivesMap : ObjectiveModel.WorkspaceObjectivesMap,
    args : Text,
  ) : async Text {
    switch (Json.parse(args)) {
      case (#err(error)) {
        Helpers.buildErrorResponse("Failed to parse arguments: " # debug_show error);
      };
      case (#ok(json)) {
        let vsIdOpt = switch (Json.get(json, "valueStreamId")) {
          case (?#number(#int n)) { if (n >= 0) { ?Int.abs(n) } else { null } };
          case _ { null };
        };
        switch (vsIdOpt) {
          case (?vsId) {
            switch (ValueStreamModel.deleteValueStream(valueStreamsMap, workspaceId, vsId)) {
              case (#err(msg)) { Helpers.buildErrorResponse(msg) };
              case (#ok(())) {
                // Clean up objectives for this value stream
                Map.remove(workspaceObjectivesMap, Nat.compare, vsId);
                Json.stringify(
                  obj([
                    ("success", bool(true)),
                    ("valueStreamId", int(vsId)),
                    ("action", str("value_stream_deleted")),
                    ("message", str("Value stream " # Nat.toText(vsId) # " and its objectives have been deleted")),
                  ]),
                  null,
                );
              };
            };
          };
          case (null) {
            Helpers.buildErrorResponse("Missing required field: valueStreamId");
          };
        };
      };
    };
  };
};
