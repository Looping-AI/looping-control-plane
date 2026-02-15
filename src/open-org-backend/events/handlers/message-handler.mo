/// Message Handler
/// Handles standard user messages, me_messages, and app_mentions.
///
/// Future responsibilities:
///   - Check if message is in a tracked thread (where the bot was mentioned)
///   - If in tracked thread, continue conversation via LLM
///   - Post response back to Slack via SlackWrapper.postMessage

import Time "mo:core/Time";
import NormalizedEventTypes "../types/normalized-event-types";
import Logger "../../utilities/logger";

module {

  public func handle(
    workspaceId : Nat,
    msg : {
      user : Text;
      text : Text;
      channel : Text;
      ts : Text;
      threadTs : ?Text;
    },
  ) : async NormalizedEventTypes.HandlerResult {
    Logger.log(
      #info,
      ?"MessageHandler",
      "message in workspace " # debug_show (workspaceId) #
      " | channel: " # msg.channel #
      " | user: " # msg.user #
      " | text: " # msg.text,
    );

    // TODO: Check if message is in a tracked thread (where the bot was mentioned)
    // TODO: If in tracked thread, continue conversation
    // TODO: Post response back to Slack via SlackWrapper.postMessage

    #ok([
      {
        action = "log_event";
        result = #ok;
        timestamp = Time.now();
      },
    ]);
  };
};
