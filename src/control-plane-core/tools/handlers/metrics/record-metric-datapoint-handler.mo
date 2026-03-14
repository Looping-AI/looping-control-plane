import Json "mo:json";
import { str; obj; int; bool } "mo:json";
import Float "mo:core/Float";
import Int "mo:core/Int";
import Nat "mo:core/Nat";
import Time "mo:core/Time";
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
        let valueOpt : ?Float = switch (Json.get(json, "value")) {
          case (?#number(#float f)) { ?f };
          case (?#number(#int n)) { ?Float.fromInt(n) };
          case _ { null };
        };
        switch (metricIdOpt, valueOpt) {
          case (?metricId, ?value) {
            let sourceType = switch (Json.get(json, "sourceType")) {
              case (?#string(s)) { s };
              case _ { "manual" };
            };
            let sourceLabel = switch (Json.get(json, "sourceLabel")) {
              case (?#string(s)) { s };
              case _ { "assistant" };
            };
            let source = MetricParsers.parseMetricSource(sourceType, sourceLabel);
            let result = MetricModel.recordDatapoint(
              datapoints,
              registryState,
              metricId,
              value,
              source,
              Time.now(),
            );
            switch (result) {
              case (#ok(())) {
                Json.stringify(
                  obj([
                    ("success", bool(true)),
                    ("metricId", int(metricId)),
                    ("action", str("datapoint_recorded")),
                    ("message", str("Datapoint recorded for metric " # Nat.toText(metricId))),
                  ]),
                  null,
                );
              };
              case (#err(msg)) { Helpers.buildErrorResponse(msg) };
            };
          };
          case _ {
            Helpers.buildErrorResponse("Missing required fields: metricId, value");
          };
        };
      };
    };
  };
};
