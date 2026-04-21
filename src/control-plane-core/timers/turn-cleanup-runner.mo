/// Turn Cleanup Runner
/// Hard-deletes turns (and their traces) older than the retention window
/// (90 days), including any orphaned stale `#running` turns (e.g. from
/// crashed workers). After deleting turns, removes the corresponding
/// execution envelope records so no orphans are left behind.
/// Scheduled to run every 7 days alongside the channel-history prune timer.

import Int "mo:core/Int";
import Time "mo:core/Time";

import SessionModel "../models/session-model";
import ExecutionEnvelopeModel "../models/execution-envelope-model";
import Constants "../constants";

module {
  public func run(
    stores : SessionModel.SessionStores,
    envelopeState : ExecutionEnvelopeModel.EnvelopeState,
  ) : {
    #ok : Nat;
    #err : Text;
  } {
    let cutoffNs : Int = Time.now() - Int.fromNat(Constants.TURN_CLEANUP_RETENTION_NS);
    let deletedTurnIds = SessionModel.deleteTurnsOlderThan(stores, cutoffNs);
    ignore ExecutionEnvelopeModel.deleteByTurnIds(envelopeState, deletedTurnIds);
    #ok(deletedTurnIds.size());
  };
};
