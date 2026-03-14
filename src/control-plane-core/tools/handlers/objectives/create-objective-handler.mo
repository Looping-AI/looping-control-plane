import Json "mo:json";
import { str; obj; int; bool } "mo:json";
import Nat "mo:core/Nat";
import Int "mo:core/Int";
import Map "mo:core/Map";
import ObjectiveModel "../../../models/objective-model";
import Helpers "../handler-helpers";
import ObjectiveParsers "../parsers/objective-parsers";

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
        let nameOpt = switch (Json.get(json, "name")) {
          case (?#string(s)) { ?s };
          case _ { null };
        };
        let descriptionOpt = switch (Json.get(json, "description")) {
          case (?#string(s)) { ?s };
          case _ { null };
        };
        let objectiveTypeOpt = switch (Json.get(json, "objectiveType")) {
          case (?#string(s)) { ObjectiveParsers.parseObjectiveType(s) };
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
        let targetTypeOpt = switch (Json.get(json, "targetType")) {
          case (?#string(s)) { ?s };
          case _ { null };
        };
        let targetDateOpt = switch (Json.get(json, "targetDate")) {
          case (?#number(#int n)) { ?n };
          case _ { null };
        };

        switch (valueStreamIdOpt, nameOpt, objectiveTypeOpt, metricIdsOpt, computationOpt, targetTypeOpt) {
          case (?valueStreamId, ?name, ?objectiveType, ?metricIds, ?computation, ?targetType) {
            let targetOpt = ObjectiveParsers.parseObjectiveTarget(json, targetType);

            switch (targetOpt) {
              case (?target) {
                let input : ObjectiveModel.ObjectiveInput = {
                  name;
                  description = descriptionOpt;
                  objectiveType;
                  metricIds;
                  computation;
                  target;
                  targetDate = targetDateOpt;
                };

                let fullObjectivesMap = Map.fromArray<Nat, ObjectiveModel.WorkspaceObjectivesMap>(
                  [(workspaceId, workspaceObjectivesMap)],
                  Nat.compare,
                );
                ObjectiveModel.initValueStreamObjectives(fullObjectivesMap, workspaceId, valueStreamId);

                let result = ObjectiveModel.addObjective(
                  fullObjectivesMap,
                  workspaceId,
                  valueStreamId,
                  input,
                );

                switch (result) {
                  case (#ok(objectiveId)) {
                    Json.stringify(
                      obj([
                        ("success", bool(true)),
                        ("objectiveId", int(objectiveId)),
                        ("message", str("Objective created successfully")),
                      ]),
                      null,
                    );
                  };
                  case (#err(error)) { Helpers.buildErrorResponse(error) };
                };
              };
              case (null) {
                Helpers.buildErrorResponse("Invalid target configuration for targetType: " # targetType);
              };
            };
          };
          case _ {
            Helpers.buildErrorResponse("Missing required fields: valueStreamId, name, objectiveType, metricIds, computation, and targetType are required");
          };
        };
      };
    };
  };
};
