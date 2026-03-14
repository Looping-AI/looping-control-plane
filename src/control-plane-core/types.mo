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
    #openRouter;
  };

  /// Secret identifier for encrypted-at-rest secrets
  /// Each variant represents a distinct secret that can be stored per workspace
  public type SecretId = {
    #openRouterApiKey;
    #openaiApiKey;
    #slackBotToken;
    #slackSigningSecret;
  };

  /// Subset of SecretId for org-critical secrets manageable only by the org owner
  /// via the storeOrgCriticalSecrets canister method
  public type OrgCriticalSecretId = {
    #openRouterApiKey;
    #slackBotToken;
    #slackSigningSecret;
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

  // ============================================
  // Agent Message Metadata
  // ============================================

  /// Metadata embedded in every agent reply.
  ///
  /// Metadata is embedded in every bot reply posted via chat.postMessage.
  /// When the reply is received back as a Slack event, the adapter parses this
  /// metadata to reconstruct the lineage and round count — no separate
  /// server-side round-context index required.

  /// The payload carried inside every agent message metadata block.
  /// Extracted as a standalone type so callers that only need lineage data
  /// (e.g. ConversationMessage) don't have to carry the outer Slack envelope.
  /// `event_payload.parent_agent`   — bare agent name that produced this reply (e.g. `"admin"`, no `::` prefix).
  /// `event_payload.parent_ts`      — ts of the message this is a reply to.
  /// `event_payload.parent_channel` — channel of that message (ts is channel-scoped;
  ///                                   both fields are needed for an unambiguous lookup).
  public type AgentMetadataPayload = {
    parent_agent : Text; // bare name of the agent that produced this reply (no "::" prefix)
    parent_ts : Text; // ts of the message that triggered this reply
    parent_channel : Text; // channel of that message (ts is channel-scoped)
  };

  /// `event_type` is always `"looping_agent_message"` — validated on receipt;
  /// any other value causes the parser to return `null` (treated as absent).
  public type AgentMessageMetadata = {
    event_type : Text;
    event_payload : AgentMetadataPayload;
  };
};
