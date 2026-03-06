import Json "mo:json";
import { str; obj; int; bool; arr } "mo:json";
import Array "mo:core/Array";
import MetricModel "../../models/metric-model";

module {
  public func handle(
    registryState : MetricModel.MetricsRegistryState,
    _args : Text,
  ) : async Text {
    let metrics = MetricModel.listMetrics(registryState);
    let metricsJson = arr(
      Array.map<MetricModel.MetricRegistration, Json.Json>(
        metrics,
        func(m) {
          obj([
            ("id", int(m.id)),
            ("name", str(m.name)),
            ("description", str(m.description)),
            ("unit", str(m.unit)),
            ("retentionDays", int(m.retentionDays)),
          ]);
        },
      )
    );
    Json.stringify(
      obj([
        ("success", bool(true)),
        ("count", int(metrics.size())),
        ("metrics", metricsJson),
      ]),
      null,
    );
  };
};
