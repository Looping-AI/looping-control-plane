/// Message Edited Handler
/// Handles message edit events (message_changed).
///
/// Updates the stored ConversationMessage in place so the LLM’s context
/// window reflects the current text on subsequent turns.

import Time "mo:core/Time";
import NormalizedEventTypes "../types/normalized-event-types";
import EventProcessingContextTypes "../types/event-processing-context";
import ConversationModel "../../models/conversation-model";
import Logger "../../utilities/logger";

module {

  public func handle(
    edited : {
      channel : Text;
      messageTs : Text;
      threadTs : ?Text;
      newText : Text;
      editedBy : ?Text;
    },
    ctx : EventProcessingContextTypes.EventProcessingContext,
  ) : async NormalizedEventTypes.HandlerResult {
    Logger.log(
      #info,
      ?"MessageEditedHandler",
      "message_edited | channel: " # edited.channel #
      " | messageTs: " # edited.messageTs #
      " | newText: " # edited.newText,
    );

    // rootTs is derived from thread_ts (if set) or from the message ts itself
    let rootTs = switch (edited.threadTs) {
      case (?ts) { ts };
      case (null) { edited.messageTs };
    };

    let updated = ConversationModel.updateMessageText(
      ctx.conversationStore,
      edited.channel,
      rootTs,
      edited.messageTs,
      edited.newText,
    );

    if (not updated) {
      Logger.log(
        #info,
        ?"MessageEditedHandler",
        "Message not found in conversation store " #
        "| channel: " # edited.channel # " | messageTs: " # edited.messageTs,
      );
    };

    #ok([
      {
        action = "update_conversation";
        result = if (updated) #ok else #err("message not found");
        timestamp = Time.now();
      },
    ]);
  };
};
