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
    eventId : Text; // Canonical ID: source prefix + idempotencyKey (e.g. "slack_Ev0123")
    timestamp : Nat; // Unix timestamp of the event
    payload : EventPayload; // The actual event data

    // Lifecycle timestamps
    enqueued_at : Int; // Time.now() when enqueued
    claimed_at : ?Int; // null = unclaimed, ?timestamp = processing started
    processed_at : ?Int; // null = not done, ?timestamp = completed successfully
    failed_at : ?Int; // null = not failed, ?timestamp = processing failed
    failed_error : Text; // empty string by default, error message on failure
  };

  /// Convert an EventSource variant to its string prefix for eventId construction
  public func sourcePrefix(source : EventSource) : Text {
    switch (source) {
      case (#slack) { "slack" };
    };
  };

  /// Build a canonical eventId from source and idempotencyKey
  /// Format: "{sourcePrefix}_{idempotencyKey}"
  /// Example: "slack_Ev0123ABCDEF"
  public func buildEventId(source : EventSource, idempotencyKey : Text) : Text {
    sourcePrefix(source) # "_" # idempotencyKey;
  };
};
