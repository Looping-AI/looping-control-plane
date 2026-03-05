import Json "mo:json";
import { str; obj; bool } "mo:json";
import Nat "mo:core/Nat";
import Int "mo:core/Int";
import Float "mo:core/Float";
import Time "mo:core/Time";
import Principal "mo:core/Principal";
import Map "mo:core/Map";
import ObjectiveModel "../../models/objective-model";
import Helpers "./handler-helpers";

module {
  public func handle(
    workspaceId : Nat,
    workspaceObjectivesMap : ObjectiveModel.WorkspaceObjectivesMap,
    args : Text,
  ) : async Text {
    switch (Json.parse(args)) {
      case (#err(error)) {
        Helpers.buildErrorResponse("Failed to parse arguments: " # debug_show error);
      };
      case (#ok(json)) {
        let valueStreamIdOpt = switch (Json.get(json, "valueStreamId")) {
          case (?#number(#int n)) {
            if (n >= 0) { ?Int.abs(n) } else { null };
          };
          case _ { null };
        };
        let objectiveIdOpt = switch (Json.get(json, "objectiveId")) {
          case (?#number(#int n)) {
            if (n >= 0) { ?Int.abs(n) } else { null };
          };
          case _ { null };
        };
        let valueOpt = switch (Json.get(json, "value")) {
          case (?#number(#float f)) { ?f };
          case (?#number(#int i)) { ?Float.fromInt(i) };
          case _ { null };
        };

        switch (valueStreamIdOpt, objectiveIdOpt, valueOpt) {
          case (?valueStreamId, ?objectiveId, ?value) {
            let timestamp = switch (Json.get(json, "timestamp")) {
              case (?#number(#int n)) { n };
              case _ { Time.now() };
            };

            let valueWarning = switch (Json.get(json, "valueWarning")) {
              case (?#string(s)) { ?s };
              case _ { null };
            };

            let comments : [ObjectiveModel.ObjectiveDatapointComment] = switch (Json.get(json, "comment")) {
              case (?#string(commentText)) {
                let author = switch (Json.get(json, "commentAuthor")) {
                  case (?#string("user")) {
                    #principal(Principal.fromText("2vxsx-fae"));
                  };
                  case (?#string(name)) { #assistant(name) };
                  case _ { #assistant("assistant") };
                };
                [{
                  timestamp = Time.now();
                  author;
                  message = commentText;
                }];
              };
              case _ { [] };
            };

            let datapoint : ObjectiveModel.ObjectiveDatapoint = {
              timestamp;
              value = ?value;
              valueWarning;
              comments;
            };

            let fullObjectivesMap = Map.fromArray<Nat, ObjectiveModel.WorkspaceObjectivesMap>(
              [(workspaceId, workspaceObjectivesMap)],
              Nat.compare,
            );

            let result = ObjectiveModel.recordObjectiveDatapoint(
              fullObjectivesMap,
              workspaceId,
              valueStreamId,
              objectiveId,
              datapoint,
            );

            switch (result) {
              case (#ok(())) {
                Json.stringify(
                  obj([
                    ("success", bool(true)),
                    ("message", str("Datapoint recorded successfully")),
                    ("value", #number(#float(value))),
                  ]),
                  null,
                );
              };
              case (#err(error)) { Helpers.buildErrorResponse(error) };
            };
          };
          case _ {
            Helpers.buildErrorResponse("Missing required fields: valueStreamId, objectiveId, and value are required");
          };
        };
      };
    };
  };
};
