import Json "mo:json";
import { str; obj; int; bool; arr } "mo:json";
import Array "mo:core/Array";
import Nat "mo:core/Nat";
import ValueStreamModel "../../../models/value-stream-model";
import Helpers "../handler-helpers";
import ValueStreamParsers "../parsers/value-stream-parsers";

module {
  public func handle(
    workspaceId : Nat,
    valueStreamsMap : ValueStreamModel.ValueStreamsMap,
    _args : Text,
  ) : async Text {
    switch (ValueStreamModel.listValueStreams(valueStreamsMap, workspaceId)) {
      case (#err(msg)) { Helpers.buildErrorResponse(msg) };
      case (#ok(streams)) {
        let streamsJson = arr(
          Array.map<ValueStreamModel.ValueStream, Json.Json>(
            streams,
            func(vs) {
              obj([
                ("id", int(vs.id)),
                ("name", str(vs.name)),
                ("problem", str(vs.problem)),
                ("goal", str(vs.goal)),
                ("status", str(ValueStreamParsers.statusToText(vs.status))),
                ("hasPlan", bool(vs.plan != null)),
                ("createdAt", int(vs.createdAt)),
                ("updatedAt", int(vs.updatedAt)),
              ]);
            },
          )
        );
        Json.stringify(
          obj([
            ("success", bool(true)),
            ("count", int(streams.size())),
            ("valueStreams", streamsJson),
          ]),
          null,
        );
      };
    };
  };
};
