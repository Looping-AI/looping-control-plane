import Json "mo:json";
import { str; obj; int; bool } "mo:json";
import Int "mo:core/Int";
import Nat "mo:core/Nat";
import ValueStreamModel "../../../models/value-stream-model";
import Helpers "../handler-helpers";

module {
  private func statusToText(status : ValueStreamModel.ValueStreamStatus) : Text {
    switch (status) {
      case (#draft) { "draft" };
      case (#active) { "active" };
      case (#paused) { "paused" };
      case (#archived) { "archived" };
    };
  };

  public func handle(
    workspaceId : Nat,
    valueStreamsMap : ValueStreamModel.ValueStreamsMap,
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
            switch (ValueStreamModel.getValueStream(valueStreamsMap, workspaceId, vsId)) {
              case (#err(msg)) { Helpers.buildErrorResponse(msg) };
              case (#ok(vs)) {
                let planJson : Json.Json = switch (vs.plan) {
                  case (null) { #null_ };
                  case (?p) {
                    obj([
                      ("summary", str(p.summary)),
                      ("currentState", str(p.currentState)),
                      ("targetState", str(p.targetState)),
                      ("steps", str(p.steps)),
                      ("risks", str(p.risks)),
                      ("resources", str(p.resources)),
                      ("createdAt", int(p.createdAt)),
                      ("updatedAt", int(p.updatedAt)),
                    ]);
                  };
                };
                Json.stringify(
                  obj([
                    ("success", bool(true)),
                    ("id", int(vs.id)),
                    ("name", str(vs.name)),
                    ("problem", str(vs.problem)),
                    ("goal", str(vs.goal)),
                    ("status", str(statusToText(vs.status))),
                    ("plan", planJson),
                    ("createdAt", int(vs.createdAt)),
                    ("updatedAt", int(vs.updatedAt)),
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
