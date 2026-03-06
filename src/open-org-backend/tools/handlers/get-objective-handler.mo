import Json "mo:json";
import { str; obj; int; bool; arr } "mo:json";
import Nat "mo:core/Nat";
import Int "mo:core/Int";
import Float "mo:core/Float";
import Array "mo:core/Array";
import Map "mo:core/Map";
import ObjectiveModel "../../models/objective-model";
import Helpers "./handler-helpers";

module {
  private func objectiveTypeToText(t : ObjectiveModel.ObjectiveType) : Text {
    switch (t) {
      case (#target) { "target" };
      case (#contributing) { "contributing" };
      case (#prerequisite) { "prerequisite" };
      case (#guardrail) { "guardrail" };
    };
  };

  private func statusToText(s : ObjectiveModel.ObjectiveStatus) : Text {
    switch (s) {
      case (#active) { "active" };
      case (#paused) { "paused" };
      case (#archived) { "archived" };
    };
  };

  private func targetToJson(target : ObjectiveModel.ObjectiveTarget) : Json.Json {
    switch (target) {
      case (#percentage({ target = t })) {
        obj([
          ("type", str("percentage")),
          ("value", #number(#float(t))),
        ]);
      };
      case (#count({ target = t; direction })) {
        let dir = switch (direction) {
          case (#increase) { "increase" };
          case (#decrease) { "decrease" };
        };
        obj([
          ("type", str("count")),
          ("value", #number(#float(t))),
          ("direction", str(dir)),
        ]);
      };
      case (#threshold({ min; max })) {
        let minField : Json.Json = switch (min) {
          case (null) { #null_ };
          case (?v) { #number(#float(v)) };
        };
        let maxField : Json.Json = switch (max) {
          case (null) { #null_ };
          case (?v) { #number(#float(v)) };
        };
        obj([
          ("type", str("threshold")),
          ("min", minField),
          ("max", maxField),
        ]);
      };
      case (#boolean(b)) {
        obj([
          ("type", str("boolean")),
          ("value", bool(b)),
        ]);
      };
    };
  };

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
            switch (ObjectiveModel.getObjective(fullObjectivesMap, workspaceId, valueStreamId, objectiveId)) {
              case (#err(msg)) { Helpers.buildErrorResponse(msg) };
              case (#ok(o)) {
                let descField : Json.Json = switch (o.description) {
                  case (null) { #null_ };
                  case (?d) { str(d) };
                };
                let targetDateField : Json.Json = switch (o.targetDate) {
                  case (null) { #null_ };
                  case (?d) { int(d) };
                };
                let currentField : Json.Json = switch (o.current) {
                  case (null) { #null_ };
                  case (?v) { #number(#float(v)) };
                };
                let metricIdsJson = arr(
                  Array.map<Nat, Json.Json>(o.metricIds, func(id) { int(id) })
                );
                let statusText = statusToText(o.status);
                let typeText = objectiveTypeToText(o.objectiveType);
                Json.stringify(
                  obj([
                    ("success", bool(true)),
                    ("id", int(o.id)),
                    ("name", str(o.name)),
                    ("description", descField),
                    ("objectiveType", str(typeText)),
                    ("metricIds", metricIdsJson),
                    ("computation", str(o.computation)),
                    ("target", targetToJson(o.target)),
                    ("targetDate", targetDateField),
                    ("current", currentField),
                    ("status", str(statusText)),
                    ("createdAt", int(o.createdAt)),
                    ("updatedAt", int(o.updatedAt)),
                  ]),
                  null,
                );
              };
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
