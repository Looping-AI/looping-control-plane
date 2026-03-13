/// Message Deleted Handler
/// Handles message deletion events (message_deleted).
///
/// Removes the deleted message from the conversation store.
/// The message_deleted event does not carry thread_ts, so a scan-based
/// search is used (see ConversationModel.findAndDeleteMessage).

import Time "mo:core/Time";
import NormalizedEventTypes "../types/normalized-event-types";
import EventProcessingContextTypes "../types/event-processing-context";
import ConversationModel "../../models/conversation-model";

module {

  public func handle(
    deleted : {
      channel : Text;
      deletedTs : Text;
    },
    ctx : EventProcessingContextTypes.EventProcessingContext,
  ) : async NormalizedEventTypes.HandlerResult {
    let removed = ConversationModel.findAndDeleteMessage(
      ctx.conversationStore,
      deleted.channel,
      deleted.deletedTs,
    );

    #ok([
      {
        action = "delete_message";
        result = if (removed) #ok else #err("message not found");
        timestamp = Time.now();
      },
    ]);
  };
};
