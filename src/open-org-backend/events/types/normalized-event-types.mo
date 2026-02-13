/// Normalized Event Types
/// Internal event types that are source-agnostic
///
/// These types represent the normalized form that the rest of the system works with.
/// This separation from raw Slack types means adding a new integration later
/// (email, GitHub webhooks, etc.) only requires a new adapter, not changes to
/// the queue or router.

module {

  // ============================================
  // Normalized Internal Event Types
  // ============================================

  /// Source integration that originated the event
  public type EventSource = {
    #slack;
    // Future: #email, #github, etc.
  };

  /// Normalized event payload — what the router/handlers work with
  public type EventPayload = {
    #app_mention : {
      user : Text; // Who mentioned the bot
      text : Text; // Full message text
      channel : Text; // Channel ID
      ts : Text; // Message timestamp
      thread_ts : ?Text; // Thread timestamp (if in a thread)
    };
    #message : {
      user : Text; // Who sent the message
      text : Text; // Message text
      channel : Text; // Channel ID
      ts : Text; // Message timestamp
      thread_ts : ?Text; // Thread timestamp
    };
  };

  /// Normalized event — single type the queue and router use
  public type Event = {
    source : EventSource; // Which integration sent this
    workspaceId : Nat; // Internal workspace ID
    idempotencyKey : Text; // Unique key for deduplication (Slack's event_id)
    timestamp : Nat; // Unix timestamp of the event
    payload : EventPayload; // The actual event data
  };
};
