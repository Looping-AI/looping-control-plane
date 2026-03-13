import Json "mo:json";
import { str; obj; int; bool; arr } "mo:json";
import Nat "mo:core/Nat";
import Int "mo:core/Int";
import Float "mo:core/Float";
import Array "mo:core/Array";
import Map "mo:core/Map";
import ObjectiveModel "../../../models/objective-model";
import Helpers "../handler-helpers";

module {
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
            switch (ObjectiveModel.getHistoryArray(fullObjectivesMap, workspaceId, valueStreamId, objectiveId)) {
              case (#err(msg)) { Helpers.buildErrorResponse(msg) };
              case (#ok(history)) {
                let historyJson = arr(
                  Array.map<ObjectiveModel.ObjectiveDatapoint, Json.Json>(
                    history,
                    func(dp) {
                      let valueField : Json.Json = switch (dp.value) {
                        case (null) { #null_ };
                        case (?v) { #number(#float(v)) };
                      };
                      let warningField : Json.Json = switch (dp.valueWarning) {
                        case (null) { #null_ };
                        case (?w) { str(w) };
                      };
                      let commentsJson = arr(
                        Array.map<ObjectiveModel.ObjectiveDatapointComment, Json.Json>(
                          dp.comments,
                          func(c) {
                            obj([
                              ("timestamp", int(c.timestamp)),
                              ("author", str(authorToText(c.author))),
                              ("message", str(c.message)),
                            ]);
                          },
                        )
                      );
                      obj([
                        ("timestamp", int(dp.timestamp)),
                        ("value", valueField),
                        ("valueWarning", warningField),
                        ("commentCount", int(dp.comments.size())),
                        ("comments", commentsJson),
                      ]);
                    },
                  )
                );
                Json.stringify(
                  obj([
                    ("success", bool(true)),
                    ("objectiveId", int(objectiveId)),
                    ("count", int(history.size())),
                    ("history", historyJson),
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
