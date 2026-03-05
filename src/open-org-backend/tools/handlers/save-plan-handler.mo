import Json "mo:json";
import { str; obj; int } "mo:json";
import Nat "mo:core/Nat";
import Int "mo:core/Int";
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
        let valueStreamIdOpt = switch (Json.get(json, "valueStreamId")) {
          case (?#number(#int n)) {
            if (n >= 0) { ?Int.abs(n) } else { null };
          };
          case _ { null };
        };
        let summaryOpt = switch (Json.get(json, "summary")) {
          case (?#string(s)) { ?s };
          case (_) { null };
        };
        let currentStateOpt = switch (Json.get(json, "currentState")) {
          case (?#string(s)) { ?s };
          case (_) { null };
        };
        let targetStateOpt = switch (Json.get(json, "targetState")) {
          case (?#string(s)) { ?s };
          case (_) { null };
        };
        let stepsOpt = switch (Json.get(json, "steps")) {
          case (?#string(s)) { ?s };
          case (_) { null };
        };
        let risksOpt = switch (Json.get(json, "risks")) {
          case (?#string(s)) { ?s };
          case (_) { null };
        };
        let resourcesOpt = switch (Json.get(json, "resources")) {
          case (?#string(s)) { ?s };
          case (_) { null };
        };

        switch (valueStreamIdOpt, summaryOpt, currentStateOpt, targetStateOpt, stepsOpt, risksOpt, resourcesOpt) {
          case (?valueStreamId, ?summary, ?currentState, ?targetState, ?steps, ?risks, ?resources) {
            let planInput : ValueStreamModel.PlanInput = {
              summary;
              currentState;
              targetState;
              steps;
              risks;
              resources;
            };

            let changedBy = #assistant("workspace-admin-ai");
            let diff = "Plan created/updated via save_plan tool";

            let result = ValueStreamModel.setPlan(
              valueStreamsMap,
              workspaceId,
              valueStreamId,
              planInput,
              changedBy,
              diff,
            );

            switch (result) {
              case (#ok(())) {
                Json.stringify(
                  obj([
                    ("success", #bool(true)),
                    ("valueStreamId", int(valueStreamId)),
                    ("action", str("plan_saved")),
                  ]),
                  null,
                );
              };
              case (#err(msg)) { Helpers.buildErrorResponse(msg) };
            };
          };
          case _ {
            Helpers.buildErrorResponse("Missing required fields. All fields are required: valueStreamId, summary, currentState, targetState, steps, risks, resources");
          };
        };
      };
    };
  };
};
