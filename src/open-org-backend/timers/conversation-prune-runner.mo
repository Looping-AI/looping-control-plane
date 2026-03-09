/// Conversation Prune Runner
/// Drops timeline entries where ALL messages are older than the retention window
/// (30 days). Preserves thread entries with any recent message (grace rule).
/// Scheduled to run every 7 days.

import Int "mo:core/Int";
import Nat "mo:core/Nat";
import Time "mo:core/Time";

import ConversationModel "../models/conversation-model";
import Constants "../constants";

module {
  public func run(store : ConversationModel.ConversationStore) : {
    #ok;
    #err : Text;
  } {
    let nowSecs : Nat = Int.abs(Time.now() / 1_000_000_000);
    let cutoffSecs : Nat = if (nowSecs > Constants.CONVERSATION_RETENTION_SECS) {
      Nat.sub(nowSecs, Constants.CONVERSATION_RETENTION_SECS);
    } else { 0 };
    ConversationModel.pruneAll(store, cutoffSecs);
    #ok;
  };
};
