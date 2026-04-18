/// Engine Constants
/// Retention periods and thresholds for the internal engine's run store.

module {

  // 7 days in nanoseconds (7 * 24 * 60 * 60 * 1_000_000_000)
  // Completed runs older than this are purged by the cleanup timer.
  public let COMPLETED_RUN_RETENTION_NS : Nat = 604_800_000_000_000;

  // 30 days in nanoseconds (30 * 24 * 60 * 60 * 1_000_000_000)
  // Failed runs older than this are purged by the cleanup timer.
  public let FAILED_RUN_RETENTION_NS : Nat = 2_592_000_000_000_000;

  // 1 hour in nanoseconds (60 * 60 * 1_000_000_000)
  // Running entries older than this are assumed to have trapped and moved to failed.
  public let STALE_RUN_THRESHOLD_NS : Nat = 3_600_000_000_000;

};
