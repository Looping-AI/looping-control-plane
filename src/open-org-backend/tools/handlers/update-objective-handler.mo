import Json "mo:json";
import { str; obj; bool } "mo:json";
import Nat "mo:core/Nat";
import Int "mo:core/Int";
import Float "mo:core/Float";
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
            let nameOpt = switch (Json.get(json, "name")) {
              case (?#string(s)) { ?s };
              case _ { null };
            };

            let descriptionOpt : ??Text = switch (Json.get(json, "clearDescription")) {
              case (?#bool(true)) { ?null };
              case _ {
                switch (Json.get(json, "description")) {
                  case (?#string(s)) { ?(?s) };
                  case _ { null };
                };
              };
            };

            let objectiveTypeOpt = switch (Json.get(json, "objectiveType")) {
              case (?#string("target")) { ?#target };
              case (?#string("contributing")) { ?#contributing };
              case (?#string("prerequisite")) { ?#prerequisite };
              case (?#string("guardrail")) { ?#guardrail };
              case _ { null };
            };

            let metricIdsOpt = switch (Json.get(json, "metricIds")) {
              case (?#array(items)) { ?Helpers.extractNatArray(items) };
              case _ { null };
            };

            let computationOpt = switch (Json.get(json, "computation")) {
              case (?#string(s)) { ?s };
              case _ { null };
            };

            let targetOpt : ?ObjectiveModel.ObjectiveTarget = switch (Json.get(json, "targetType")) {
              case (?#string("percentage")) {
                switch (Json.get(json, "targetValue")) {
                  case (?#number(#float f)) { ?#percentage({ target = f }) };
                  case (?#number(#int i)) {
                    ?#percentage({ target = Float.fromInt(i) });
                  };
                  case _ { null };
                };
              };
              case (?#string("count")) {
                let targetValueOpt = switch (Json.get(json, "targetValue")) {
                  case (?#number(#float f)) { ?f };
                  case (?#number(#int i)) { ?Float.fromInt(i) };
                  case _ { null };
                };
                let directionOpt = switch (Json.get(json, "targetDirection")) {
                  case (?#string("increase")) { ?#increase };
                  case (?#string("decrease")) { ?#decrease };
                  case _ { null };
                };
                switch (targetValueOpt, directionOpt) {
                  case (?target, ?direction) { ?#count({ target; direction }) };
                  case _ { null };
                };
              };
              case (?#string("threshold")) {
                let minOpt = switch (Json.get(json, "targetValue")) {
                  case (?#number(#float f)) { ?f };
                  case (?#number(#int i)) { ?Float.fromInt(i) };
                  case _ { null };
                };
                let maxOpt = switch (Json.get(json, "targetMax")) {
                  case (?#number(#float f)) { ?f };
                  case (?#number(#int i)) { ?Float.fromInt(i) };
                  case _ { null };
                };
                ?#threshold({ min = minOpt; max = maxOpt });
              };
              case (?#string("boolean")) {
                switch (Json.get(json, "targetBoolean")) {
                  case (?#bool(b)) { ?#boolean(b) };
                  case _ { null };
                };
              };
              case _ { null };
            };

            let targetDateOpt : ??Int = switch (Json.get(json, "clearTargetDate")) {
              case (?#bool(true)) { ?null };
              case _ {
                switch (Json.get(json, "targetDate")) {
                  case (?#number(#int n)) { ?(?n) };
                  case _ { null };
                };
              };
            };

            let statusOpt = switch (Json.get(json, "status")) {
              case (?#string("active")) { ?#active };
              case (?#string("paused")) { ?#paused };
              case (?#string("archived")) { ?#archived };
              case _ { null };
            };

            let fullObjectivesMap = Map.fromArray<Nat, ObjectiveModel.WorkspaceObjectivesMap>(
              [(workspaceId, workspaceObjectivesMap)],
              Nat.compare,
            );

            let result = ObjectiveModel.updateObjective(
              fullObjectivesMap,
              workspaceId,
              valueStreamId,
              objectiveId,
              nameOpt,
              descriptionOpt,
              objectiveTypeOpt,
              metricIdsOpt,
              computationOpt,
              targetOpt,
              targetDateOpt,
              statusOpt,
            );

            switch (result) {
              case (#ok(())) {
                Json.stringify(
                  obj([
                    ("success", bool(true)),
                    ("message", str("Objective updated successfully")),
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
