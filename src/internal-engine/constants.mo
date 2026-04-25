/// Engine Constants
/// Retention periods and thresholds for the internal engine's run store.

module {

  // 7 days in nanoseconds (7 * 24 * 60 * 60 * 1_000_000_000)
  // Completed runs older than this are purged by the cleanup timer.
  public let COMPLETED_RUN_RETENTION_NS : Nat = 604_800_000_000_000;

  // 30 days in nanoseconds (30 * 24 * 60 * 60 * 1_000_000_000)
  // Failed runs older than this are purged by the cleanup timer.
  public let FAILED_RUN_RETENTION_NS : Nat = 2_592_000_000_000_000;

  // Default OpenRouter model used when the envelope does not supply a "model" key.
  public let DEFAULT_LLM_MODEL : Text = "openai/gpt-oss-120b";

};
