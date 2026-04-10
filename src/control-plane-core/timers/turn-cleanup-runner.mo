/// Turn Cleanup Runner
/// Hard-deletes turns (and their traces) older than the retention window
/// (90 days), including any orphaned stale `#running` turns (e.g. from
/// crashed workers). Scheduled to run every 7 days alongside the conversation
/// prune timer.

import Int "mo:core/Int";
import Time "mo:core/Time";

import SessionModel "../models/session-model";
import Constants "../constants";

module {
  public func run(stores : SessionModel.SessionStores) : {
    #ok : Nat;
    #err : Text;
  } {
    let cutoffNs : Int = Time.now() - Int.fromNat(Constants.TURN_CLEANUP_RETENTION_NS);
    let deleted = SessionModel.deleteTurnsOlderThan(stores, cutoffNs);
    #ok(deleted);
  };
};
