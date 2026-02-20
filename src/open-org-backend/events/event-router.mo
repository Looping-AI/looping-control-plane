/// Event Router
/// Timer-driven processor that claims a single event by ID and dispatches it
///
/// Strategy: "one timer per event"
///   - When an event is enqueued, a Timer.setTimer(#seconds 0) is scheduled
///   - The timer callback claims the event by ID and routes to the handler
///   - On success: event moves to processed map with processingLog
///   - On failure: event moves to failed map with error message
///
/// Each event runs independently, leveraging ICP's native concurrency.

import Error "mo:core/Error";
import EventStoreModel "../models/event-store-model";
import NormalizedEventTypes "./types/normalized-event-types";
import EventProcessingContextTypes "./types/event-processing-context";
import MessageHandler "./handlers/message-handler";
import ThreadEventHandler "./handlers/thread-event-handler";
import BotMessageHandler "./handlers/bot-message-handler";
import MessageEditedHandler "./handlers/message-edited-handler";
import MessageDeletedHandler "./handlers/message-deleted-handler";
import Logger "../utilities/logger";

module {

  /// Re-exported so callers that already import EventRouter (e.g. main.mo)
  /// can use EventRouter.EventProcessingContext without an extra import.
  public type EventProcessingContext = EventProcessingContextTypes.EventProcessingContext;

  // ============================================
  // Single Event Processing
  // ============================================

  /// Process a single event by its ID.
  /// Claims the event, routes it to the appropriate handler, then marks it
  /// as processed (with processingLog) or failed (with error message).
  ///
  /// @param state  - The event store state
  /// @param eventId - The event ID to process
  /// @param ctx    - Actor-level state threaded through for handler use
  public func processSingleEvent(state : EventStoreModel.EventStoreState, eventId : Text, ctx : EventProcessingContext) : async () {
    // Claim the event (sets claimedAt)
    let event = switch (EventStoreModel.claim(state, eventId)) {
      case (null) {
        Logger.log(#warn, ?"EventRouter", "Event not found in unprocessed: " # eventId);
        return;
      };
      case (?e) { e };
    };

    Logger.log(#info, ?"EventRouter", "Processing event: " # eventId);

    // Route to handler and capture result
    let handlerResult : NormalizedEventTypes.HandlerResult = try {
      switch (event.payload) {
        case (#message(msg)) {
          await MessageHandler.handle(event.workspaceId, msg, ctx);
        };
        case (#threadEvent(thread)) {
          await ThreadEventHandler.handle(event.workspaceId, thread, ctx);
        };
        case (#botMessage(bot)) {
          await BotMessageHandler.handle(event.workspaceId, bot, ctx);
        };
        case (#messageEdited(edited)) {
          await MessageEditedHandler.handle(event.workspaceId, edited, ctx);
        };
        case (#messageDeleted(deleted)) {
          await MessageDeletedHandler.handle(event.workspaceId, deleted, ctx);
        };
      };
    } catch (e) {
      #err("Unexpected error: " # Error.message(e));
    };

    // Mark processed or failed based on handler result
    switch (handlerResult) {
      case (#ok(steps)) {
        EventStoreModel.markProcessed(state, eventId, steps);
        Logger.log(#info, ?"EventRouter", "Event processed successfully: " # eventId);
      };
      case (#err(error)) {
        EventStoreModel.markFailed(state, eventId, error);
        Logger.log(#error, ?"EventRouter", "Event processing failed: " # eventId # " | error: " # error);
      };
    };
  };
};
