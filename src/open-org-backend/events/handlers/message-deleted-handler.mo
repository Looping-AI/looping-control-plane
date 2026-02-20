/// Message Deleted Handler
/// Handles message deletion events (message_deleted).
///
/// Future responsibilities:
///   - If the deleted message was a prompt, consider aborting in-flight response
///   - Clean up conversation history

import Time "mo:core/Time";
import NormalizedEventTypes "../types/normalized-event-types";
import EventProcessingContextTypes "../types/event-processing-context";
import Logger "../../utilities/logger";

module {

  public func handle(
    workspaceId : Nat,
    deleted : {
      channel : Text;
      deletedTs : Text;
    },
    _ctx : EventProcessingContextTypes.EventProcessingContext,
  ) : async NormalizedEventTypes.HandlerResult {
    Logger.log(
      #info,
      ?"MessageDeletedHandler",
      "message_deleted in workspace " # debug_show (workspaceId) #
      " | channel: " # deleted.channel #
      " | deletedTs: " # deleted.deletedTs,
    );

    // TODO: If the deleted message was a prompt, consider aborting in-flight response
    // TODO: Clean up conversation history

    #ok([
      {
        action = "log_event";
        result = #ok;
        timestamp = Time.now();
      },
    ]);
  };
};
