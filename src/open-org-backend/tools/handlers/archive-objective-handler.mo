import Json "mo:json";
import { str; obj; bool } "mo:json";
import Nat "mo:core/Nat";
import Int "mo:core/Int";
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

        switch (valueStreamIdOpt, objectiveIdOpt) {
          case (?valueStreamId, ?objectiveId) {
            let fullObjectivesMap = Map.fromArray<Nat, ObjectiveModel.WorkspaceObjectivesMap>(
              [(workspaceId, workspaceObjectivesMap)],
              Nat.compare,
            );

            let result = ObjectiveModel.archiveObjective(
              fullObjectivesMap,
              workspaceId,
              valueStreamId,
              objectiveId,
            );

            switch (result) {
              case (#ok(())) {
                Json.stringify(
                  obj([
                    ("success", bool(true)),
                    ("message", str("Objective archived successfully")),
                  ]),
                  null,
                );
              };
              case (#err(error)) { Helpers.buildErrorResponse(error) };
            };
          };
          case _ {
            Helpers.buildErrorResponse("Missing required fields: valueStreamId and objectiveId are required");
          };
        };
      };
    };
  };
};
