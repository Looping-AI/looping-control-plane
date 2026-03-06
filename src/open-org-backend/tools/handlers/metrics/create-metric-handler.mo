import Json "mo:json";
import { str; obj; int; bool } "mo:json";
import Nat "mo:core/Nat";
import Int "mo:core/Int";
import Time "mo:core/Time";
import Principal "mo:core/Principal";
import MetricModel "../../../models/metric-model";
import Helpers "../handler-helpers";

module {
  public func handle(
    registryState : MetricModel.MetricsRegistryState,
    args : Text,
  ) : async Text {
    switch (Json.parse(args)) {
      case (#err(error)) {
        Helpers.buildErrorResponse("Failed to parse arguments: " # debug_show error);
      };
      case (#ok(json)) {
        let nameOpt = switch (Json.get(json, "name")) {
          case (?#string(s)) { ?s };
          case (_) { null };
        };
        let descriptionOpt = switch (Json.get(json, "description")) {
          case (?#string(s)) { ?s };
          case (_) { null };
        };
        let unitOpt = switch (Json.get(json, "unit")) {
          case (?#string(s)) { ?s };
          case (_) { null };
        };
        let retentionDaysOpt = switch (Json.get(json, "retentionDays")) {
          case (?#number(#int n)) {
            if (n >= 0) { ?Int.abs(n) } else { null };
          };
          case _ { null };
        };

        switch (nameOpt, descriptionOpt, unitOpt, retentionDaysOpt) {
          case (?name, ?description, ?unit, ?retentionDays) {
            let input : MetricModel.MetricRegistrationInput = {
              name;
              description;
              unit;
              retentionDays;
            };

            let caller = Principal.fromText("2vxsx-fae");
            let result = MetricModel.registerMetric(
              registryState,
              input,
              caller,
              Time.now(),
            );

            switch (result) {
              case (#ok(metricId)) {
                Json.stringify(
                  obj([
                    ("success", bool(true)),
                    ("metricId", int(metricId)),
                    ("action", str("metric_created")),
                    ("message", str("Metric '" # name # "' created successfully with ID " # Nat.toText(metricId))),
                  ]),
                  null,
                );
              };
              case (#err(msg)) { Helpers.buildErrorResponse(msg) };
            };
          };
          case _ {
            Helpers.buildErrorResponse("Missing required fields: name, description, unit, retentionDays");
          };
        };
      };
    };
  };
};
