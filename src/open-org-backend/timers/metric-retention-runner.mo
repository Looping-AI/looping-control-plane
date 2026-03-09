/// Metric Retention Cleanup Runner
/// Purges metric datapoints older than each metric's configured retention period.
/// Scheduled to run every 30 days.

import MetricModel "../models/metric-model";

module {
  public func run(
    datapoints : MetricModel.MetricDatapointsStore,
    registry : MetricModel.MetricsRegistryState,
  ) : { #ok : MetricModel.MetricDatapointsStore; #err : Text } {
    #ok(MetricModel.purgeOldDatapoints(datapoints, registry));
  };
};
