import Types "./types";

module {
  // Environment - important for dependency management (it can be local, test, staging, production)
  public let ENVIRONMENT : Types.Environment = #local;

  // 30 days in nanoseconds (30 * 24 * 60 * 60 * 1_000_000_000)
  public let THIRTY_DAYS_NS : Nat = 2_592_000_000_000_000;

  // 7 days in nanoseconds (7 * 24 * 60 * 60 * 1_000_000_000)
  // Used for periodic cleanup of processed events map
  public let SEVEN_DAYS_NS : Nat = 604_800_000_000_000;

  // 1 hour in nanoseconds (60 * 60 * 1_000_000_000)
  // Used to detect unprocessed events that were never picked up
  public let ONE_HOUR_NS : Nat = 3_600_000_000_000;

  // Log raw Slack event payloads for development/debugging
  // Set it to true for dev/staging to output raw JSON via `dfx canister logs`
  // Useful for creating new test stubs and debugging event parsing
  public let LOG_SLACK_EVENTS : Bool = true;

  // 1 year in nanoseconds (365 * 24 * 60 * 60 * 1_000_000_000)
  // Retention period for the access change log in SlackUserModel
  public let ACCESS_LOG_RETENTION_NS : Nat = 31_536_000_000_000_000;

  // Admin talk configuration
  public let ADMIN_TALK_PROVIDER : Types.LlmProvider = #groq;
  public let ADMIN_TALK_SECRET : Types.SecretId = #groqApiKey;
  public let ADMIN_TALK_MODEL : Text = "openai/gpt-oss-120b";

  // Conversation retention
  // Messages/groups older than this are dropped by the Sunday prune timer.
  // 30 days in seconds (30 * 24 * 3600)
  public let CONVERSATION_RETENTION_SECS : Nat = 2_592_000;

  // Agent routing round control
  // Absolute ceiling on the number of LLM rounds any session may run.
  public let MAX_AGENT_ROUNDS : Nat = 10;
};
