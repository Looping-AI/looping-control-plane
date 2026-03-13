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
        let historyIndexOpt = switch (Json.get(json, "historyIndex")) {
          case (?#number(#int n)) {
            if (n >= 0) { ?Int.abs(n) } else { null };
          };
          case _ { null };
        };
        let messageOpt = switch (Json.get(json, "message")) {
          case (?#string(s)) { ?s };
          case _ { null };
        };

        switch (valueStreamIdOpt, objectiveIdOpt, historyIndexOpt, messageOpt) {
          case (?valueStreamId, ?objectiveId, ?historyIndex, ?message) {
            let author : ObjectiveModel.ObjectiveCommentAuthor = switch (Json.get(json, "author")) {
              case (?#string(name)) { #assistant(name) };
              case _ { #assistant("assistant") };
            };

            let comment : ObjectiveModel.ObjectiveDatapointComment = {
              timestamp = Time.now();
              author;
              message;
            };

            let fullObjectivesMap = Map.fromArray<Nat, ObjectiveModel.WorkspaceObjectivesMap>(
              [(workspaceId, workspaceObjectivesMap)],
              Nat.compare,
            );

            let result = ObjectiveModel.addCommentToHistoryDatapoint(
              fullObjectivesMap,
              workspaceId,
              valueStreamId,
              objectiveId,
              historyIndex,
              comment,
            );

            switch (result) {
              case (#ok(())) {
                Json.stringify(
                  obj([
                    ("success", bool(true)),
                    ("message", str("Comment added successfully")),
                  ]),
                  null,
                );
              };
              case (#err(error)) { Helpers.buildErrorResponse(error) };
            };
          };
          case _ {
            Helpers.buildErrorResponse("Missing required fields: valueStreamId, objectiveId, historyIndex, and message are required");
          };
        };
      };
    };
  };
};
