import Json "mo:json";
import { str; obj; bool } "mo:json";
import Nat "mo:core/Nat";
import Int "mo:core/Int";
import Time "mo:core/Time";
import Map "mo:core/Map";
import ObjectiveModel "../../../models/objective-model";
import Helpers "../handler-helpers";

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
        let perceivedImpactOpt = switch (Json.get(json, "perceivedImpact")) {
          case (?#string("negative")) { ?#negative };
          case (?#string("none")) { ?#none };
          case (?#string("low")) { ?#low };
          case (?#string("medium")) { ?#medium };
          case (?#string("high")) { ?#high };
          case (?#string("unclear")) { ?#unclear };
          case _ { null };
        };

        switch (valueStreamIdOpt, objectiveIdOpt, perceivedImpactOpt) {
          case (?valueStreamId, ?objectiveId, ?perceivedImpact) {
            let comment = switch (Json.get(json, "comment")) {
              case (?#string(s)) { ?s };
              case _ { null };
            };

            let author = switch (Json.get(json, "author")) {
              case (?#string(name)) { #assistant(name) };
              case _ { #assistant("assistant") };
            };

            let review : ObjectiveModel.ImpactReview = {
              timestamp = Time.now();
              author;
              perceivedImpact;
              comment;
            };

            let fullObjectivesMap = Map.fromArray<Nat, ObjectiveModel.WorkspaceObjectivesMap>(
              [(workspaceId, workspaceObjectivesMap)],
              Nat.compare,
            );

            let result = ObjectiveModel.addImpactReview(
              fullObjectivesMap,
              workspaceId,
              valueStreamId,
              objectiveId,
              review,
            );

            switch (result) {
              case (#ok(())) {
                Json.stringify(
                  obj([
                    ("success", bool(true)),
                    ("message", str("Impact review added successfully")),
                  ]),
                  null,
                );
              };
              case (#err(error)) { Helpers.buildErrorResponse(error) };
            };
          };
          case _ {
            Helpers.buildErrorResponse("Missing required fields: valueStreamId, objectiveId, and perceivedImpact are required");
          };
        };
      };
    };
  };
};
