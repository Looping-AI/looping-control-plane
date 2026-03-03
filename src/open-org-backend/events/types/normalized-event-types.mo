/// Normalized Event Types
/// Internal event types that are source-agnostic
///
/// These types represent the normalized form that the rest of the system works with.
/// This separation from raw Slack types means adding a new integration later
/// (email, GitHub webhooks, etc.) only requires a new adapter, not changes to
/// the queue or router.

import Types "../../types";

module {

  // ============================================
  // Normalized Internal Event Types
  // ============================================

  /// Source integration that originated the event
  public type EventSource = {
    #slack;
    // Future: #email, #github, etc.
  };

  // ============================================
  // Processing Step — handler observability
  // ============================================

  /// Re-exported from Types so event handlers can use this alias directly.
  /// The canonical definition lives in types.mo so orchestrators and other
  /// non-event modules can also emit steps without a cross-layer import.
  public type ProcessingStep = Types.ProcessingStep;

  /// Context payload for assistant thread events.
  /// The shape differs by lifecycle event type:
  ///   #started          — initial thread open; carries the force_search hint
  ///   #contextChanged   — user navigated to a new channel while the thread was open
  ///   #metadataUpdated  — Slack updated thread title/metadata after the first message
  public type AssistantThreadContext = {
    #started : {
      forceSearch : Bool; // Slack hint: favour search results when true
    };
    #contextChanged : {
      channelId : ?Text; // Channel the user is now viewing
      teamId : ?Text; // Workspace of that channel
      enterpriseId : ?Text; // Enterprise Grid org (null for standard workspaces)
    };
    #metadataUpdated : {
      title : ?Text; // Updated thread title set by Slack
      text : Text; // Current text content of the thread root message
    };
  };

  /// Return type for all handlers — standardized contract between router and handlers.
  /// #ok returns the processing steps taken (even if individual steps failed).
  /// #err means a fatal/unrecoverable error that should mark the event as failed.
  public type HandlerResult = {
    #ok : [ProcessingStep];
    #err : Text;
  };

  /// Normalized event payload — what the router/handlers work with
  public type EventPayload = {
    #message : {
      user : Text; // Who sent the message (or bot user ID for bot messages)
      text : Text; // Message text
      channel : Text; // Channel ID
      ts : Text; // Message timestamp
      threadTs : ?Text; // Thread timestamp
      isBotMessage : Bool; // true when posted by our own bot
      agentMetadata : ?Types.AgentMessageMetadata; // Present on own-bot replies; null on user messages
    };
    #assistantThreadEvent : {
      eventType : {
        #threadStarted;
        #threadContextChanged;
        #threadMetadataUpdated;
      }; // Which lifecycle event
      userId : Text; // assistant_thread.user_id — the Slack user who owns the thread
      channelId : Text; // assistant_thread.channel_id — the DM channel hosting the thread
      threadTs : Text; // assistant_thread.thread_ts — uniquely identifies the thread
      eventTs : Text; // event.event_ts
      context : AssistantThreadContext; // Event-specific context data
    };
    #messageEdited : {
      channel : Text; // Channel ID
      messageTs : Text; // ts of the original message that was edited
      threadTs : ?Text; // thread_ts if the message is in a thread; null for top-level
      newText : Text; // Current text after the edit
      editedBy : ?Text; // Who edited (may differ from original author)
    };
    #messageDeleted : {
      channel : Text; // Channel ID
      deletedTs : Text; // ts of the message that was deleted
    };
    #memberJoinedChannel : {
      userId : Text; // Slack user ID who joined
      channelId : Text; // Channel ID
      channelType : Text; // e.g. "C" for public channel
      teamId : Text; // Workspace team ID
      eventTs : Text;
    };
    #memberLeftChannel : {
      userId : Text; // Slack user ID who left
      channelId : Text; // Channel ID
      channelType : Text; // e.g. "C" for public channel
      teamId : Text; // Workspace team ID
      eventTs : Text;
    };
    #teamJoin : {
      userId : Text; // Slack user ID of the new member
      displayName : Text; // Username / handle
      realName : ?Text; // Real / display name from profile (may be absent)
      isPrimaryOwner : Bool;
      isOrgAdmin : Bool;
      eventTs : Text;
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
    enqueuedAt : Int; // Time.now() when enqueued
    claimedAt : ?Int; // null = unclaimed, ?timestamp = processing started
    processedAt : ?Int; // null = not done, ?timestamp = completed successfully
    failedAt : ?Int; // null = not failed, ?timestamp = processing failed
    failedError : Text; // empty string by default, error message on failure
    processingLog : [ProcessingStep]; // Steps taken by the handler during processing
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
