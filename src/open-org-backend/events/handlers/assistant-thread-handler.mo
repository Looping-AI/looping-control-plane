/// Assistant Thread Handler
/// Handles the full lifecycle of assistant threads, covering:
///   - Thread opened  (assistant_thread_started)
///   - Thread closed  (assistant_thread_context_changed / thread dismissed)
///
/// Responsibilities (to be implemented):
///   - Handle thread open: initialize conversation context
///   - Handle thread close: clean up / persist conversation state

import Time "mo:core/Time";
import NormalizedEventTypes "../types/normalized-event-types";
import EventProcessingContextTypes "../types/event-processing-context";
import Logger "../../utilities/logger";

module {

  public func handle(
    workspaceId : Nat,
    thread : {
      eventType : {
        #threadStarted;
        #threadContextChanged;
        #threadMetadataUpdated;
      };
      userId : Text; // assistant_thread.user_id
      channelId : Text; // assistant_thread.channel_id (the DM channel)
      threadTs : Text; // assistant_thread.thread_ts
      eventTs : Text; // event.event_ts
      context : NormalizedEventTypes.AssistantThreadContext;
    },
    _ctx : EventProcessingContextTypes.EventProcessingContext,
  ) : async NormalizedEventTypes.HandlerResult {
    Logger.log(
      #info,
      ?"AssistantThreadHandler",
      "assistant_thread event in workspace " # debug_show (workspaceId) #
      " | eventType: " # debug_show (thread.eventType) #
      " | channelId: " # thread.channelId #
      " | userId: " # thread.userId #
      " | threadTs: " # thread.threadTs,
    );

    // TODO: Handle #threadStarted — initialise conversation context
    // TODO: Handle #threadContextChanged — update conversation context with new channel
    // TODO: Handle #threadMetadataUpdated — update stored thread title/metadata
    // TODO: Handle assistant_thread.action_token — process and respond to action requests

    #ok([
      {
        action = "log_event";
        result = #ok;
        timestamp = Time.now();
      },
    ]);
  };
};
