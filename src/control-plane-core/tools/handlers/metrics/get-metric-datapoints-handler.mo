import Json "mo:json";
import { str; obj; int; bool; arr } "mo:json";
import Int "mo:core/Int";
import Array "mo:core/Array";
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
          case (?#number(#int n)) {
            if (n >= 0) { ?Int.abs(n) } else { null };
          };
          case _ { null };
        };

        switch (metricIdOpt) {
          case (?metricId) {
            switch (MetricModel.getMetric(registryState, metricId)) {
              case (null) { Helpers.buildErrorResponse("Metric not found") };
              case (?metric) {
                let sinceNanos = switch (Json.get(json, "since")) {
                  case (?#string(_isoString)) {
                    // TODO: implement proper ISO string parsing
                    null;
                  };
                  case (_) { null };
                };

                let allDatapoints = MetricModel.getDatapoints(datapoints, metricId, sinceNanos);

                let limitOpt = switch (Json.get(json, "limit")) {
                  case (?#number(#int n)) {
                    if (n >= 0) { ?Int.abs(n) } else { null };
                  };
                  case _ { null };
                };

                let limitedDatapoints = switch (limitOpt) {
                  case (?limit) {
                    if (allDatapoints.size() <= limit) {
                      allDatapoints;
                    } else {
                      Array.tabulate<MetricModel.MetricDatapoint>(
                        limit,
                        func(i : Nat) : MetricModel.MetricDatapoint {
                          allDatapoints[i];
                        },
                      );
                    };
                  };
                  case (null) { allDatapoints };
                };

                let datapointsJson = arr(
                  Array.map<MetricModel.MetricDatapoint, Json.Json>(
                    limitedDatapoints,
                    func(dp : MetricModel.MetricDatapoint) : Json.Json {
                      let sourceText = switch (dp.source) {
                        case (#manual(s)) { "manual: " # s };
                        case (#integration(s)) { "integration: " # s };
                        case (#evaluator(s)) { "evaluator: " # s };
                        case (#other(s)) { "other: " # s };
                      };
                      obj([
                        ("timestamp", int(dp.timestamp)),
                        ("value", #number(#float(dp.value))),
                        ("source", str(sourceText)),
                      ]);
                    },
                  )
                );

                Json.stringify(
                  obj([
                    ("success", bool(true)),
                    ("metricId", int(metricId)),
                    ("metricName", str(metric.name)),
                    ("unit", str(metric.unit)),
                    ("count", int(limitedDatapoints.size())),
                    ("datapoints", datapointsJson),
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
