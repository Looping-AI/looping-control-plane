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

  /// LLM Provider
  public type AdminLlmProvider = {
    #groq;
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
};
