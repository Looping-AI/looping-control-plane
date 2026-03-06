import Json "mo:json";
import { str; obj; int; bool; arr } "mo:json";
import Nat "mo:core/Nat";
import Int "mo:core/Int";
import Array "mo:core/Array";
import Map "mo:core/Map";
import ObjectiveModel "../../../models/objective-model";
import Helpers "../handler-helpers";

module {
  private func perceivedImpactToText(impact : ObjectiveModel.PerceivedImpact) : Text {
    switch (impact) {
      case (#negative) { "negative" };
      case (#none) { "none" };
      case (#low) { "low" };
      case (#medium) { "medium" };
      case (#high) { "high" };
      case (#unclear) { "unclear" };
    };
  };

  private func authorToText(author : ObjectiveModel.ObjectiveCommentAuthor) : Text {
    switch (author) {
      case (#principal(_)) { "user" };
      case (#assistant(name)) { name };
      case (#task(name)) { name };
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
            switch (ObjectiveModel.getImpactReviews(fullObjectivesMap, workspaceId, valueStreamId, objectiveId)) {
              case (#err(msg)) { Helpers.buildErrorResponse(msg) };
              case (#ok(reviews)) {
                let reviewsJson = arr(
                  Array.map<ObjectiveModel.ImpactReview, Json.Json>(
                    reviews,
                    func(r) {
                      let commentField : Json.Json = switch (r.comment) {
                        case (null) { #null_ };
                        case (?c) { str(c) };
                      };
                      obj([
                        ("timestamp", int(r.timestamp)),
                        ("perceivedImpact", str(perceivedImpactToText(r.perceivedImpact))),
                        ("comment", commentField),
                        ("author", str(authorToText(r.author))),
                      ]);
                    },
                  )
                );
                Json.stringify(
                  obj([
                    ("success", bool(true)),
                    ("objectiveId", int(objectiveId)),
                    ("count", int(reviews.size())),
                    ("reviews", reviewsJson),
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
