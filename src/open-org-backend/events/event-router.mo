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
    // Claim the event (sets claimedAt)
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
      case (#message(msg)) {
        handleMessage(event.workspaceId, msg);
      };
      case (#threadEvent(thread)) {
        handleThreadEvent(event.workspaceId, thread);
      };
      case (#botMessage(bot)) {
        handleBotMessage(event.workspaceId, bot);
      };
      case (#messageEdited(edited)) {
        handleMessageEdited(event.workspaceId, edited);
      };
      case (#messageDeleted(deleted)) {
        handleMessageDeleted(event.workspaceId, deleted);
      };
    };

    // Success — move to processed
    EventStoreModel.markProcessed(state, eventId);
    Logger.log(#info, ?"EventRouter", "Event processed successfully: " # eventId);
  };

  // ============================================
  // Event Handlers (stubs — will be async in the future)
  // ============================================

  /// Handle a message event (standard user message, me_message, or app_mention)
  /// TODO: Once SlackWrapper is implemented, post LLM response back to Slack via chat.postMessage
  func handleMessage(
    workspaceId : Nat,
    msg : {
      user : Text;
      text : Text;
      channel : Text;
      ts : Text;
      threadTs : ?Text;
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
  };

  /// Handle a thread event (thread_broadcast or assistant_app_thread)
  func handleThreadEvent(
    workspaceId : Nat,
    thread : {
      user : Text;
      text : Text;
      channel : Text;
      ts : Text;
      threadTs : Text;
    },
  ) {
    Logger.log(
      #info,
      ?"EventRouter",
      "thread_event in workspace " # debug_show (workspaceId) #
      " | channel: " # thread.channel #
      " | user: " # thread.user #
      " | threadTs: " # thread.threadTs #
      " | text: " # thread.text,
    );

    // TODO: Track thread for conversation context
  };

  /// Handle a bot message from another integration
  func handleBotMessage(
    workspaceId : Nat,
    bot : {
      botId : Text;
      text : Text;
      channel : Text;
      ts : Text;
      username : ?Text;
    },
  ) {
    let name = switch (bot.username) {
      case (?u) { u };
      case (null) { bot.botId };
    };
    Logger.log(
      #info,
      ?"EventRouter",
      "bot_message in workspace " # debug_show (workspaceId) #
      " | channel: " # bot.channel #
      " | bot: " # name #
      " | text: " # bot.text,
    );

    // TODO: Decide per-bot how to handle (e.g., respond to certain integrations)
  };

  /// Handle a message edit event
  func handleMessageEdited(
    workspaceId : Nat,
    edited : {
      channel : Text;
      messageTs : Text;
      newText : Text;
      editedBy : ?Text;
    },
  ) {
    Logger.log(
      #info,
      ?"EventRouter",
      "message_edited in workspace " # debug_show (workspaceId) #
      " | channel: " # edited.channel #
      " | messageTs: " # edited.messageTs #
      " | newText: " # edited.newText,
    );

    // TODO: If the edited message was a prompt, consider re-processing
  };

  /// Handle a message deletion event
  func handleMessageDeleted(
    workspaceId : Nat,
    deleted : {
      channel : Text;
      deletedTs : Text;
    },
  ) {
    Logger.log(
      #info,
      ?"EventRouter",
      "message_deleted in workspace " # debug_show (workspaceId) #
      " | channel: " # deleted.channel #
      " | deletedTs: " # deleted.deletedTs,
    );

    // TODO: If the deleted message was a prompt, consider aborting in-flight response
    // TODO: Clean up conversation history
  };
};
