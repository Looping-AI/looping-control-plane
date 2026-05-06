/// Run Store Model
/// Persistent 3-map store tracking the lifecycle of workflow runs.
/// Follows the same pattern as EventStoreModel in control-plane-core.
///
/// Maps: running (enqueued/in-progress) → completed → failed
/// Keyed by envelopeId.

import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Text "mo:core/Text";
import Iter "mo:core/Iter";
import Time "mo:core/Time";
import Int "mo:core/Int";
import Float "mo:core/Float";
import List "mo:core/List";
import RunTypes "../runner/run-types";
import Constants "../constants";

module {

  // ============================================
  // State Types
  // ============================================

  public type RunStoreState = {
    running : Map.Map<Nat, RunTypes.RunRecord>;
    completed : Map.Map<Nat, RunTypes.RunRecord>;
    failed : Map.Map<Nat, RunTypes.RunRecord>;
  };

  // ============================================
  // Initialization
  // ============================================

  public func empty() : RunStoreState {
    {
      running = Map.empty<Nat, RunTypes.RunRecord>();
      completed = Map.empty<Nat, RunTypes.RunRecord>();
      failed = Map.empty<Nat, RunTypes.RunRecord>();
    };
  };

  // ============================================
  // Enqueue & Dedup
  // ============================================

  /// Enqueue a new run record. Rejects duplicates across all three maps.
  public func enqueue(state : RunStoreState, record : RunTypes.RunRecord) : {
    #ok;
    #duplicate;
  } {
    let id = record.envelopeId;
    if (isDuplicate(state, id)) { return #duplicate };
    Map.add(state.running, Nat.compare, id, record);
    #ok;
  };

  public func isDuplicate(state : RunStoreState, envelopeId : Nat) : Bool {
    Map.containsKey(state.running, Nat.compare, envelopeId) or Map.containsKey(state.completed, Nat.compare, envelopeId) or Map.containsKey(state.failed, Nat.compare, envelopeId);
  };

  // ============================================
  // Lifecycle Operations
  // ============================================

  /// Claim a run for processing — sets claimedAt timestamp.
  /// Returns the record if found in running, null otherwise.
  public func claim(state : RunStoreState, envelopeId : Nat) : ?RunTypes.RunRecord {
    switch (Map.get(state.running, Nat.compare, envelopeId)) {
      case (null) { null };
      case (?record) {
        let claimed : RunTypes.RunRecord = {
          record with
          claimedAt = ?Time.now();
        };
        Map.add(state.running, Nat.compare, envelopeId, claimed);
        ?claimed;
      };
    };
  };

  /// Get a run record from the running map (without claiming).
  public func getRunning(state : RunStoreState, envelopeId : Nat) : ?RunTypes.RunRecord {
    Map.get(state.running, Nat.compare, envelopeId);
  };

  /// Mark a run as successfully completed.
  /// Moves from running → completed with outcome data.
  public func markCompleted(
    state : RunStoreState,
    envelopeId : Nat,
    status : { #completed; #roundLimitReached },
    stats : {
      durationNs : ?Int;
      llmCalls : ?Nat;
      toolCalls : ?Nat;
      inputTokens : ?Nat;
      outputTokens : ?Nat;
      model : ?Text;
      rounds : ?Nat;
      estimatedDollarCost : ?Float;
    },
    steps : [RunTypes.RunStep],
  ) {
    switch (Map.get(state.running, Nat.compare, envelopeId)) {
      case (null) {};
      case (?record) {
        let done : RunTypes.RunRecord = {
          record with
          completedAt = ?Time.now();
          status = ?status;
          stats = ?stats;
          steps;
        };
        Map.remove(state.running, Nat.compare, envelopeId);
        Map.add(state.completed, Nat.compare, envelopeId, done);
      };
    };
  };

  /// Mark a run as failed.
  /// Moves from running → failed with error and whatever steps were collected.
  public func markFailed(
    state : RunStoreState,
    envelopeId : Nat,
    error : Text,
    steps : [RunTypes.RunStep],
  ) {
    switch (Map.get(state.running, Nat.compare, envelopeId)) {
      case (null) {};
      case (?record) {
        let errored : RunTypes.RunRecord = {
          record with
          failedAt = ?Time.now();
          failedError = error;
          status = ?(#failed(error));
          steps;
        };
        Map.remove(state.running, Nat.compare, envelopeId);
        Map.add(state.failed, Nat.compare, envelopeId, errored);
      };
    };
  };

  /// Store the result of the final emitComplete call on a closed run record.
  /// Searches completed then failed — the run will have been moved before emit is attempted.
  /// No-op if the envelopeId is not found in either map.
  public func setEmitResult(
    state : RunStoreState,
    envelopeId : Nat,
    result : { #ok; #err : Text },
  ) {
    switch (Map.get(state.completed, Nat.compare, envelopeId)) {
      case (?record) {
        Map.add(state.completed, Nat.compare, envelopeId, { record with coreEmitResult = ?result });
      };
      case (null) {
        switch (Map.get(state.failed, Nat.compare, envelopeId)) {
          case (?record) {
            Map.add(state.failed, Nat.compare, envelopeId, { record with coreEmitResult = ?result });
          };
          case (null) {};
        };
      };
    };
  };

  // ============================================
  // Lookups & Observability
  // ============================================

  /// Get a run record by envelopeId from any map.
  public func get(state : RunStoreState, envelopeId : Nat) : ?RunTypes.RunRecord {
    switch (Map.get(state.running, Nat.compare, envelopeId)) {
      case (?r) { ?r };
      case (null) {
        switch (Map.get(state.completed, Nat.compare, envelopeId)) {
          case (?r) { ?r };
          case (null) { Map.get(state.failed, Nat.compare, envelopeId) };
        };
      };
    };
  };

  /// Get counts across all three maps.
  public func sizes(state : RunStoreState) : {
    running : Nat;
    completed : Nat;
    failed : Nat;
  } {
    {
      running = Map.size(state.running);
      completed = Map.size(state.completed);
      failed = Map.size(state.failed);
    };
  };

  /// List all failed runs as an array.
  public func listFailed(state : RunStoreState) : [RunTypes.RunRecord] {
    Iter.toArray(Map.values(state.failed));
  };

  // ============================================
  // Cleanup
  // ============================================

  /// Purge completed runs older than 7 days. Returns count purged.
  public func purgeCompleted(state : RunStoreState) : Nat {
    let threshold = Int.fromNat(Constants.COMPLETED_RUN_RETENTION_NS);
    let now = Time.now();
    let keysToRemove = List.empty<Nat>();
    for ((id, record) in Map.entries(state.completed)) {
      switch (record.completedAt) {
        case (null) {};
        case (?t) {
          if (now - t > threshold) {
            List.add(keysToRemove, id);
          };
        };
      };
    };
    List.forEach<Nat>(
      keysToRemove,
      func(id) { Map.remove(state.completed, Nat.compare, id) },
    );
    List.size(keysToRemove);
  };

  /// Purge failed runs older than 30 days. Returns count purged.
  public func purgeOldFailed(state : RunStoreState) : Nat {
    let threshold = Int.fromNat(Constants.FAILED_RUN_RETENTION_NS);
    let now = Time.now();
    let keysToRemove = List.empty<Nat>();
    for ((id, record) in Map.entries(state.failed)) {
      switch (record.failedAt) {
        case (null) {};
        case (?t) {
          if (now - t > threshold) {
            List.add(keysToRemove, id);
          };
        };
      };
    };
    List.forEach<Nat>(
      keysToRemove,
      func(id) { Map.remove(state.failed, Nat.compare, id) },
    );
    List.size(keysToRemove);
  };

};
