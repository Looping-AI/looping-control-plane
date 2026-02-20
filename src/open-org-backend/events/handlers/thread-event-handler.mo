/// Thread Event Handler
/// Handles thread_broadcast and assistant_app_thread events.
///
/// Future responsibilities:
///   - Track thread for conversation context
///   - Continue conversation in thread via LLM
///   - Post response back to Slack thread via SlackWrapper.postMessage

import Time "mo:core/Time";
import NormalizedEventTypes "../types/normalized-event-types";
import EventProcessingContextTypes "../types/event-processing-context";
import Logger "../../utilities/logger";

module {

  public func handle(
    workspaceId : Nat,
    thread : {
      user : Text;
      text : Text;
      channel : Text;
      ts : Text;
      threadTs : Text;
    },
    _ctx : EventProcessingContextTypes.EventProcessingContext,
  ) : async NormalizedEventTypes.HandlerResult {
    Logger.log(
      #info,
      ?"ThreadEventHandler",
      "thread_event in workspace " # debug_show (workspaceId) #
      " | channel: " # thread.channel #
      " | user: " # thread.user #
      " | threadTs: " # thread.threadTs #
      " | text: " # thread.text,
    );

    // TODO: Track thread for conversation context
    // TODO: Continue conversation via LLM
    // TODO: Post response back to Slack thread

    #ok([
      {
        action = "log_event";
        result = #ok;
        timestamp = Time.now();
      },
    ]);
  };
};
