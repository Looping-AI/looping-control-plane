import Json "mo:json";
import Int "mo:core/Int";
import Nat "mo:core/Nat";
import ValueStreamModel "../../models/value-stream-model";
import Helpers "./handler-helpers";

module {
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
        let idOpt : ?Nat = switch (Json.get(json, "id")) {
          case (?#number(#int n)) {
            if (n >= 0) { ?Int.abs(n) } else { null };
          };
          case _ { null };
        };
        let nameOpt = switch (Json.get(json, "name")) {
          case (?#string(s)) { ?s };
          case (_) { null };
        };
        let problemOpt = switch (Json.get(json, "problem")) {
          case (?#string(s)) { ?s };
          case (_) { null };
        };
        let goalOpt = switch (Json.get(json, "goal")) {
          case (?#string(s)) { ?s };
          case (_) { null };
        };
        let activateOpt = switch (Json.get(json, "activate")) {
          case (?#bool(b)) { ?b };
          case (_) { null };
        };

        switch (nameOpt, problemOpt, goalOpt) {
          case (?name, ?problem, ?goal) {
            let activate = switch (activateOpt) {
              case (?b) { b };
              case (null) { false };
            };

            switch (idOpt) {
              case (?id) {
                let status = if (activate) { ?#active } else { null };
                let result = ValueStreamModel.updateValueStream(
                  valueStreamsMap,
                  workspaceId,
                  id,
                  ?name,
                  ?problem,
                  ?goal,
                  status,
                );
                switch (result) {
                  case (#ok(())) { Helpers.buildSuccessResponse(id, "updated") };
                  case (#err(msg)) { Helpers.buildErrorResponse(msg) };
                };
              };
              case (null) {
                let result = ValueStreamModel.createValueStream(
                  valueStreamsMap,
                  workspaceId,
                  { name; problem; goal },
                );
                switch (result) {
                  case (#ok(newId)) {
                    if (activate) {
                      let _ = ValueStreamModel.updateValueStream(
                        valueStreamsMap,
                        workspaceId,
                        newId,
                        null,
                        null,
                        null,
                        ?#active,
                      );
                    };
                    Helpers.buildSuccessResponse(newId, "created");
                  };
                  case (#err(msg)) { Helpers.buildErrorResponse(msg) };
                };
              };
            };
          };
          case (_) {
            Helpers.buildErrorResponse("Missing required fields: name, problem, or goal");
          };
        };
      };
    };
  };
};
