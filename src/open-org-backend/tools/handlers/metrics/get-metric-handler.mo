import Json "mo:json";
import { str; obj; int; bool } "mo:json";
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
          case (?#number(#int n)) { if (n >= 0) { ?Int.abs(n) } else { null } };
          case _ { null };
        };
        switch (metricIdOpt) {
          case (?metricId) {
            switch (MetricModel.getMetric(registryState, metricId)) {
              case (null) { Helpers.buildErrorResponse("Metric not found.") };
              case (?m) {
                Json.stringify(
                  obj([
                    ("success", bool(true)),
                    ("id", int(m.id)),
                    ("name", str(m.name)),
                    ("description", str(m.description)),
                    ("unit", str(m.unit)),
                    ("retentionDays", int(m.retentionDays)),
                  ]),
                  null,
                );
              };
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
