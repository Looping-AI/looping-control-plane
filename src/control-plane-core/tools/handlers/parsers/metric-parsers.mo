import MetricModel "../../../models/metric-model";

module {
  public func parseMetricSource(sourceType : Text, sourceLabel : Text) : MetricModel.MetricSource {
    switch (sourceType) {
      case ("integration") { #integration(sourceLabel) };
      case ("evaluator") { #evaluator(sourceLabel) };
      case ("other") { #other(sourceLabel) };
      case _ { #manual(sourceLabel) };
    };
  };

  public func metricSourceToText(source : MetricModel.MetricSource) : Text {
    switch (source) {
      case (#manual(s)) { "manual: " # s };
      case (#integration(s)) { "integration: " # s };
      case (#evaluator(s)) { "evaluator: " # s };
      case (#other(s)) { "other: " # s };
    };
  };
};
