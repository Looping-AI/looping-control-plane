import Json "mo:json";
import { str; obj; int; bool } "mo:json";
import Nat "mo:core/Nat";
import Int "mo:core/Int";
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
        let metricIdOpt = switch (Json.get(json, "metricId")) {
          case (?#number(#int n)) {
            if (n >= 0) { ?Int.abs(n) } else { null };
          };
          case _ { null };
        };

        switch (metricIdOpt) {
          case (?metricId) {
            let name = switch (Json.get(json, "name")) {
              case (?#string(s)) { ?s };
              case (_) { null };
            };
            let description = switch (Json.get(json, "description")) {
              case (?#string(s)) { ?s };
              case (_) { null };
            };
            let unit = switch (Json.get(json, "unit")) {
              case (?#string(s)) { ?s };
              case (_) { null };
            };
            let retentionDays = switch (Json.get(json, "retentionDays")) {
              case (?#number(#int n)) {
                if (n >= 0) { ?Int.abs(n) } else { null };
              };
              case _ { null };
            };

            let result = MetricModel.updateMetric(
              registryState,
              metricId,
              name,
              description,
              unit,
              retentionDays,
            );

            switch (result) {
              case (#ok(())) {
                Json.stringify(
                  obj([
                    ("success", bool(true)),
                    ("metricId", int(metricId)),
                    ("action", str("metric_updated")),
                    ("message", str("Metric " # Nat.toText(metricId) # " updated successfully")),
                  ]),
                  null,
                );
              };
              case (#err(msg)) { Helpers.buildErrorResponse(msg) };
            };
          };
          case (null) {
            Helpers.buildErrorResponse("Missing required field: metricId");
          };
        };
      };
    };
  };
};
