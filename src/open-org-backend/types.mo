module {
  /// Environment configuration for the bot-agent application
  /// Determines which Schnorr key to use for key derivation and other environment-specific behavior
  public type Environment = {
    #local;
    #test;
    #staging;
    #production;
  };

  /// LLM Provider
  public type LlmProvider = {
    #openai;
    #groq;
  };

  /// Secret identifier for encrypted-at-rest secrets
  /// Each variant represents a distinct secret that can be stored per workspace
  public type SecretId = {
    #groqApiKey;
    #openaiApiKey;
    #slackSigningSecret;
    #slackBotToken;
  };

  // ============================================
  // HTTP Types (for webhooks and incoming requests)
  // ============================================

  public type HeaderField = (Text, Text);

  public type HttpRequest = {
    method : Text;
    url : Text;
    headers : [HeaderField];
    body : Blob;
    certificate_version : ?Nat16;
  };

  public type HttpUpdateRequest = {
    method : Text;
    url : Text;
    headers : [HeaderField];
    body : Blob;
  };

  public type HttpResponse = {
    status_code : Nat16;
    headers : [HeaderField];
    body : Blob;
    upgrade : ?Bool;
  };

  // ============================================
  // Processing Step — handler observability
  // ============================================

  /// A single step taken by a handler during event processing.
  /// Provides observability into what actions were attempted and their outcomes.
  /// Defined here (rather than in events/types/) so orchestrators and other
  /// non-event modules can also emit and return steps without a cross-layer import.
  public type ProcessingStep = {
    action : Text; // e.g. "llm_call", "post_to_slack", "update_conversation"
    result : { #ok; #err : Text };
    timestamp : Int; // Time.now() when this step completed
  };
};
