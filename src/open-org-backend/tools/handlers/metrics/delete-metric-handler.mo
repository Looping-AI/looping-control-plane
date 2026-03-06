import Json "mo:json";
import { str; obj; int; bool } "mo:json";
import Int "mo:core/Int";
import Nat "mo:core/Nat";
import MetricModel "../../../models/metric-model";
import Helpers "../handler-helpers";

module {
  public func handle(
    registryState : MetricModel.MetricsRegistryState,
    datapoints : MetricModel.MetricDatapointsStore,
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
            if (MetricModel.unregisterMetric(registryState, datapoints, metricId)) {
              Json.stringify(
                obj([
                  ("success", bool(true)),
                  ("metricId", int(metricId)),
                  ("action", str("metric_deleted")),
                  ("message", str("Metric " # Nat.toText(metricId) # " and all its datapoints have been deleted")),
                ]),
                null,
              );
            } else {
              Helpers.buildErrorResponse("Metric not found.");
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
