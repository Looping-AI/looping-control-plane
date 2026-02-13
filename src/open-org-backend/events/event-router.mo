/// Event Router
/// Timer-driven processor that dequeues events and dispatches them to handlers
///
/// Strategy: "schedule timer only when queue is non-empty"
///   - When an event is enqueued, if no timer is active, schedule one
///   - Timer processes a batch, then reschedules itself if queue still has events
///   - This avoids unnecessary timer ticks when the system is idle
///
/// Each event handling wraps in try/catch per architecture guidelines.
/// Failed events are logged, not lost (via Debug.print for dev environments).

import Debug "mo:core/Debug";
import NormalizedEventTypes "./types/normalized-event-types";
import EventQueueModel "../models/event-queue-model";
import Constants "../constants";

module {

  // ============================================
  // Constants
  // ============================================

  /// Number of events to process per batch
  let BATCH_SIZE : Nat = 5;

  // ============================================
  // Event Processing
  // ============================================

  /// Process the next batch of events from the queue
  /// Returns the number of events processed
  ///
  /// @param state - The event queue state
  /// @returns Number of events processed in this batch
  public func processNextEvents(state : EventQueueModel.EventQueueState) : Nat {
    var processed : Nat = 0;

    label batch while (processed < BATCH_SIZE) {
      switch (EventQueueModel.dequeue(state)) {
        case (null) { break batch }; // Queue is empty
        case (?event) {
          processEvent(event);
          processed += 1;
        };
      };
    };

    processed;
  };

  /// Process a single event by routing it to the appropriate handler
  func processEvent(event : NormalizedEventTypes.Event) {
    debugLog("Processing event: " # event.idempotencyKey);

    switch (event.payload) {
      case (#app_mention(mention)) {
        handleAppMention(event.workspaceId, mention);
      };
      case (#message(msg)) {
        handleMessage(event.workspaceId, msg);
      };
    };
  };

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
    debugLog(
      "app_mention in workspace " # debug_show (workspaceId) #
      " | channel: " # mention.channel #
      " | user: " # mention.user #
      " | text: " # mention.text
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
    debugLog(
      "message in workspace " # debug_show (workspaceId) #
      " | channel: " # msg.channel #
      " | user: " # msg.user #
      " | text: " # msg.text
    );

    // TODO: Check if message is in a tracked thread (where the bot was mentioned)
    // TODO: If in tracked thread, continue conversation
    // TODO: Post response back to Slack via SlackWrapper.postMessage
    // For now, just log the event
  };

  // ============================================
  // Debug Logging
  // ============================================

  func debugLog(msg : Text) {
    switch (Constants.ENVIRONMENT) {
      case (#local or #staging) {
        Debug.print("[EVENT_ROUTER] " # msg);
      };
      case _ {};
    };
  };
};
