/// Event Router
/// Timer-driven processor that claims a single event by ID and dispatches it
///
/// Strategy: "one timer per event"
///   - When an event is enqueued, a Timer.setTimer(#seconds 0) is scheduled
///   - The timer callback claims the event by ID and routes to the handler
///   - On success: event moves to processed map
///   - On failure: event moves to failed map with error message
///
/// Each event runs independently, leveraging ICP's native concurrency.

import EventStoreModel "../models/event-store-model";
import Logger "../utilities/logger";

module {

  // ============================================
  // Single Event Processing
  // ============================================

  /// Process a single event by its ID.
  /// Claims the event, routes it to the appropriate handler, then marks it
  /// as processed or failed.
  ///
  /// @param state - The event store state
  /// @param eventId - The event ID to process
  public func processSingleEvent(state : EventStoreModel.EventStoreState, eventId : Text) {
    // Claim the event (sets claimed_at)
    let event = switch (EventStoreModel.claim(state, eventId)) {
      case (null) {
        Logger.log(#warn, ?"EventRouter", "Event not found in unprocessed: " # eventId);
        return;
      };
      case (?e) { e };
    };

    Logger.log(#info, ?"EventRouter", "Processing event: " # eventId);

    // Route to handler
    // NOTE: When handlers become async (LLM calls, Slack API), this function
    // must become async and wrap the routing in try/catch, using
    // EventStoreModel.markFailed on error.
    switch (event.payload) {
      case (#app_mention(mention)) {
        handleAppMention(event.workspaceId, mention);
      };
      case (#message(msg)) {
        handleMessage(event.workspaceId, msg);
      };
    };

    // Success — move to processed
    EventStoreModel.markProcessed(state, eventId);
    Logger.log(#info, ?"EventRouter", "Event processed successfully: " # eventId);
  };

  // ============================================
  // Event Handlers (stubs — will be async in the future)
  // ============================================

  /// Handle an app_mention event
  /// TODO: Once SlackWrapper is implemented, post LLM response back to Slack via chat.postMessage
  func handleAppMention(
    workspaceId : Nat,
    mention : {
      user : Text;
      text : Text;
      channel : Text;
      ts : Text;
      thread_ts : ?Text;
    },
  ) {
    Logger.log(
      #info,
      ?"EventRouter",
      "app_mention in workspace " # debug_show (workspaceId) #
      " | channel: " # mention.channel #
      " | user: " # mention.user #
      " | text: " # mention.text,
    );

    // TODO: Route to workspace admin talk or conversation orchestrator
    // TODO: Post response back to Slack via SlackWrapper.postMessage
    // For now, just log the event
  };

  /// Handle a message event
  /// TODO: Once SlackWrapper is implemented, post LLM response back to Slack via chat.postMessage
  func handleMessage(
    workspaceId : Nat,
    msg : {
      user : Text;
      text : Text;
      channel : Text;
      ts : Text;
      thread_ts : ?Text;
    },
  ) {
    Logger.log(
      #info,
      ?"EventRouter",
      "message in workspace " # debug_show (workspaceId) #
      " | channel: " # msg.channel #
      " | user: " # msg.user #
      " | text: " # msg.text,
    );

    // TODO: Check if message is in a tracked thread (where the bot was mentioned)
    // TODO: If in tracked thread, continue conversation
    // TODO: Post response back to Slack via SlackWrapper.postMessage
    // For now, just log the event
  };
};
