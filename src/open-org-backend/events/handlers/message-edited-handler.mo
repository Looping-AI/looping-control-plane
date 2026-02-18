/// Message Edited Handler
/// Handles message edit events (message_changed).
///
/// Future responsibilities:
///   - If the edited message was a prompt, consider re-processing
///   - Update conversation history with new text
///   - Optionally notify the LLM of the edit

import Time "mo:core/Time";
import NormalizedEventTypes "../types/normalized-event-types";
import Logger "../../utilities/logger";

module {

  public func handle(
    workspaceId : Nat,
    edited : {
      channel : Text;
      messageTs : Text;
      newText : Text;
      editedBy : ?Text;
    },
  ) : async NormalizedEventTypes.HandlerResult {
    Logger.log(
      #info,
      ?"MessageEditedHandler",
      "message_edited in workspace " # debug_show (workspaceId) #
      " | channel: " # edited.channel #
      " | messageTs: " # edited.messageTs #
      " | newText: " # edited.newText,
    );

    // TODO: If the edited message was a prompt, consider re-processing
    // TODO: Update conversation history with new text

    #ok([
      {
        action = "log_event";
        result = #ok;
        timestamp = Time.now();
      },
    ]);
  };
};
