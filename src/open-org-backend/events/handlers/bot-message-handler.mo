/// Bot Message Handler
/// Handles messages from other bot integrations.
///
/// Future responsibilities:
///   - Decide per-bot how to handle (e.g., respond to certain integrations)
///   - Optionally forward to LLM for processing
///   - Post response back to Slack if needed

import Time "mo:core/Time";
import NormalizedEventTypes "../types/normalized-event-types";
import EventProcessingContextTypes "../types/event-processing-context";
import Logger "../../utilities/logger";

module {

  public func handle(
    workspaceId : Nat,
    bot : {
      botId : Text;
      text : Text;
      channel : Text;
      ts : Text;
      username : ?Text;
    },
    _ctx : EventProcessingContextTypes.EventProcessingContext,
  ) : async NormalizedEventTypes.HandlerResult {
    let name = switch (bot.username) {
      case (?u) { u };
      case (null) { bot.botId };
    };
    Logger.log(
      #info,
      ?"BotMessageHandler",
      "bot_message in workspace " # debug_show (workspaceId) #
      " | channel: " # bot.channel #
      " | bot: " # name #
      " | text: " # bot.text,
    );

    // TODO: Decide per-bot how to handle (e.g., respond to certain integrations)

    #ok([
      {
        action = "log_event";
        result = #ok;
        timestamp = Time.now();
      },
    ]);
  };
};
