import Types "./types";

module {
  // Environment - important for dependency management (it can be local, test, staging, production)
  public let ENVIRONMENT : Types.Environment = #local;

  // 1 day in nanoseconds (24 * 60 * 60 * 1_000_000_000)
  public let ONE_DAY_NS : Nat = 86_400_000_000_000;

  // 30 days in nanoseconds (30 * 24 * 60 * 60 * 1_000_000_000)
  public let THIRTY_DAYS_NS : Nat = 2_592_000_000_000_000;

  // Admin talk configuration
  public let ADMIN_TALK_PROVIDER : Types.LlmProvider = #groq;
  public let ADMIN_TALK_MODEL : Text = "openai/gpt-oss-120b";
};
