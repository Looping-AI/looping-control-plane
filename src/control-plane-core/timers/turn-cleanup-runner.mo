/// Turn Cleanup Runner
/// Runs three independent GC passes on every weekly tick:
///   1. Traces older than 30 days (greedy early-exit per agent)
///   2. Envelope records older than 30 days (full scan by createdAtNs)
///   3. Turns older than 90 days (greedy early-exit per agent)
/// Keeping separate retention windows bounds heap usage while preserving
/// turn metadata for the full 90-day window.

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
    let now = Time.now();
    let traceCutoffNs : Int = now - Int.fromNat(Constants.TRACE_CLEANUP_RETENTION_NS);
    let envelopeCutoffNs : Int = now - Int.fromNat(Constants.ENVELOPE_CLEANUP_RETENTION_NS);
    let turnCutoffNs : Int = now - Int.fromNat(Constants.TURN_CLEANUP_RETENTION_NS);

    ignore SessionModel.deleteTracesOlderThan(stores, traceCutoffNs);
    ignore ExecutionEnvelopeModel.deleteEnvelopesOlderThan(envelopeState, envelopeCutoffNs);
    let deletedTurnIds = SessionModel.deleteTurnsOlderThan(stores, turnCutoffNs);
    #ok(deletedTurnIds.size());
  };
};
