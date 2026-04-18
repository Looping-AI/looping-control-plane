/// Run Store Model
/// Persistent 3-map store tracking the lifecycle of execution runs.
/// Follows the same pattern as EventStoreModel in control-plane-core.
///
/// Maps: running (enqueued/in-progress) → completed → failed
/// Keyed by envelopeId.

import Map "mo:core/Map";
import Text "mo:core/Text";
import Iter "mo:core/Iter";
import Time "mo:core/Time";
import Int "mo:core/Int";
import List "mo:core/List";
import RunTypes "../runner/run-types";
import Constants "../constants";

module {

  // ============================================
  // State Types
  // ============================================

  public type RunStoreState = {
    running : Map.Map<Text, RunTypes.RunRecord>;
    completed : Map.Map<Text, RunTypes.RunRecord>;
    failed : Map.Map<Text, RunTypes.RunRecord>;
  };

  // ============================================
  // Initialization
  // ============================================

  public func empty() : RunStoreState {
    {
      running = Map.empty<Text, RunTypes.RunRecord>();
      completed = Map.empty<Text, RunTypes.RunRecord>();
      failed = Map.empty<Text, RunTypes.RunRecord>();
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
    Map.add(state.running, Text.compare, id, record);
    #ok;
  };

  public func isDuplicate(state : RunStoreState, envelopeId : Text) : Bool {
    Map.containsKey(state.running, Text.compare, envelopeId) or Map.containsKey(state.completed, Text.compare, envelopeId) or Map.containsKey(state.failed, Text.compare, envelopeId);
  };

  // ============================================
  // Lifecycle Operations
  // ============================================

  /// Claim a run for processing — sets claimedAt timestamp.
  /// Returns the record if found in running, null otherwise.
  public func claim(state : RunStoreState, envelopeId : Text) : ?RunTypes.RunRecord {
    switch (Map.get(state.running, Text.compare, envelopeId)) {
      case (null) { null };
      case (?record) {
        let claimed : RunTypes.RunRecord = {
          record with
          claimedAt = ?Time.now();
        };
        Map.add(state.running, Text.compare, envelopeId, claimed);
        ?claimed;
      };
    };
  };

  /// Get a run record from the running map (without claiming).
  public func getRunning(state : RunStoreState, envelopeId : Text) : ?RunTypes.RunRecord {
    Map.get(state.running, Text.compare, envelopeId);
  };

  /// Mark a run as successfully completed.
  /// Moves from running → completed with outcome data.
  public func markCompleted(
    state : RunStoreState,
    envelopeId : Text,
    status : { #completed; #roundLimitReached },
    stats : {
      durationNs : Int;
      llmCalls : Nat;
      toolCalls : Nat;
      inputTokens : Nat;
      outputTokens : Nat;
      model : Text;
      rounds : Nat;
    },
    steps : [RunTypes.RunStep],
  ) {
    switch (Map.get(state.running, Text.compare, envelopeId)) {
      case (null) {};
      case (?record) {
        let done : RunTypes.RunRecord = {
          record with
          completedAt = ?Time.now();
          status = ?status;
          stats = ?stats;
          steps;
        };
        Map.remove(state.running, Text.compare, envelopeId);
        Map.add(state.completed, Text.compare, envelopeId, done);
      };
    };
  };

  /// Mark a run as failed.
  /// Moves from running → failed with error and whatever steps were collected.
  public func markFailed(
    state : RunStoreState,
    envelopeId : Text,
    error : Text,
    steps : [RunTypes.RunStep],
  ) {
    switch (Map.get(state.running, Text.compare, envelopeId)) {
      case (null) {};
      case (?record) {
        let errored : RunTypes.RunRecord = {
          record with
          failedAt = ?Time.now();
          failedError = error;
          status = ?(#failed(error));
          steps;
        };
        Map.remove(state.running, Text.compare, envelopeId);
        Map.add(state.failed, Text.compare, envelopeId, errored);
      };
    };
  };

  // ============================================
  // Lookups & Observability
  // ============================================

  /// Get a run record by envelopeId from any map.
  public func get(state : RunStoreState, envelopeId : Text) : ?RunTypes.RunRecord {
    switch (Map.get(state.running, Text.compare, envelopeId)) {
      case (?r) { ?r };
      case (null) {
        switch (Map.get(state.completed, Text.compare, envelopeId)) {
          case (?r) { ?r };
          case (null) { Map.get(state.failed, Text.compare, envelopeId) };
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
    let keysToRemove = List.empty<Text>();
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
    List.forEach<Text>(
      keysToRemove,
      func(id) { Map.remove(state.completed, Text.compare, id) },
    );
    List.size(keysToRemove);
  };

  /// Purge failed runs older than 30 days. Returns count purged.
  public func purgeOldFailed(state : RunStoreState) : Nat {
    let threshold = Int.fromNat(Constants.FAILED_RUN_RETENTION_NS);
    let now = Time.now();
    let keysToRemove = List.empty<Text>();
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
    List.forEach<Text>(
      keysToRemove,
      func(id) { Map.remove(state.failed, Text.compare, id) },
    );
    List.size(keysToRemove);
  };

  /// Move runs sitting in running for more than 1 hour to failed.
  /// Catches trapped or hung executions. Returns moved envelope IDs.
  public func failStaleRunning(state : RunStoreState) : [Text] {
    let threshold = Int.fromNat(Constants.STALE_RUN_THRESHOLD_NS);
    let now = Time.now();
    let staleIds = List.empty<Text>();
    for ((id, record) in Map.entries(state.running)) {
      if (now - record.enqueuedAt > threshold) {
        List.add(staleIds, id);
      };
    };
    List.forEach<Text>(
      staleIds,
      func(id) {
        switch (Map.get(state.running, Text.compare, id)) {
          case (null) {};
          case (?record) {
            let errored : RunTypes.RunRecord = {
              record with
              failedAt = ?now;
              failedError = "Run was not completed within 1 hour of being enqueued (possible trap).";
              status = ?(#failed("Run was not completed within 1 hour of being enqueued (possible trap)."));
            };
            Map.remove(state.running, Text.compare, id);
            Map.add(state.failed, Text.compare, id, errored);
          };
        };
      },
    );
    List.toArray(staleIds);
  };

};
