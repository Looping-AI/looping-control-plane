import Json "mo:json";
import { str; obj; int; bool } "mo:json";
import Int "mo:core/Int";
import MetricModel "../../../models/metric-model";
import Helpers "../handler-helpers";
import MetricParsers "../parsers/metric-parsers";

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
            switch (MetricModel.getMetric(registryState, metricId)) {
              case (null) { Helpers.buildErrorResponse("Metric not found.") };
              case (?metric) {
                switch (MetricModel.getLatestDatapoint(datapoints, metricId)) {
                  case (null) {
                    Json.stringify(
                      obj([
                        ("success", bool(true)),
                        ("metricId", int(metricId)),
                        ("metricName", str(metric.name)),
                        ("datapoint", #null_),
                      ]),
                      null,
                    );
                  };
                  case (?dp) {
                    let sourceText = MetricParsers.metricSourceToText(dp.source);
                    Json.stringify(
                      obj([
                        ("success", bool(true)),
                        ("metricId", int(metricId)),
                        ("metricName", str(metric.name)),
                        ("timestamp", int(dp.timestamp)),
                        ("value", #number(#float(dp.value))),
                        ("source", str(sourceText)),
                      ]),
                      null,
                    );
                  };
                };
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
