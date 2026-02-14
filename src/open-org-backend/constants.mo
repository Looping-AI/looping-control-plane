import Types "./types";

module {
  // Environment - important for dependency management (it can be local, test, staging, production)
  public let ENVIRONMENT : Types.Environment = #local;

  // 30 days in nanoseconds (30 * 24 * 60 * 60 * 1_000_000_000)
  public let THIRTY_DAYS_NS : Nat = 2_592_000_000_000_000;

  // 7 days in nanoseconds (7 * 24 * 60 * 60 * 1_000_000_000)
  // Used for periodic cleanup of processed events map
  public let SEVEN_DAYS_NS : Nat = 604_800_000_000_000;

  // Log raw Slack event payloads for development/debugging
  // Set it to true for dev/staging to output raw JSON via `dfx canister logs`
  // Useful for creating new test stubs and debugging event parsing
  public let LOG_SLACK_EVENTS : Bool = false;

  // Admin talk configuration
  public let ADMIN_TALK_PROVIDER : Types.LlmProvider = #groq;
  public let ADMIN_TALK_SECRET : Types.SecretId = #groqApiKey;
  public let ADMIN_TALK_MODEL : Text = "openai/gpt-oss-120b";
};
