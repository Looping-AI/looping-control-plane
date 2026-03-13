/// Processed Events Cleanup Runner
/// Runs every 7 days to:
///   1. Detect unprocessed events stuck for > 1h and move them to failed
///   2. Purge old processed events (> 7 days)
///   3. Purge old failed events (> 30 days)

import Array "mo:core/Array";
import Nat "mo:core/Nat";
import Text "mo:core/Text";

import EventStoreModel "../models/event-store-model";
import Logger "../utilities/logger";

module {
  public func run(eventStore : EventStoreModel.EventStoreState) : {
    #ok;
    #err : Text;
  } {
    // 1. Detect and fail stale unprocessed events (enqueuedAt > 1 hour ago)
    let staleIds = EventStoreModel.failStaleUnprocessed(eventStore);
    if (staleIds.size() > 0) {
      let idList = Array.foldLeft<Text, Text>(
        staleIds,
        "",
        func(acc, id) {
          if (acc == "") id else acc # ", " # id;
        },
      );
      Logger.log(#warn, ?"EventStore", "Failed " # Nat.toText(staleIds.size()) # " stale unprocessed event(s): " # idList);
    };

    // 2. Purge old processed events (> 7 days)
    ignore EventStoreModel.purgeProcessed(eventStore);

    // 3. Purge old failed events (> 30 days)
    ignore EventStoreModel.purgeOldFailed(eventStore);

    #ok;
  };
};
