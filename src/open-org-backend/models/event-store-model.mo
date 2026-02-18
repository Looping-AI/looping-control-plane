/// Event Store Model
/// Persistent event store using three maps: unprocessed, processed, failed
///
/// Features:
///   - Per-event timer dispatch (no batching)
///   - Deduplication by checking all three maps
///   - Lifecycle tracking via timestamps (enqueued, claimed, processed, failed)
///   - Admin observability for failed events
///   - Periodic cleanup of processed events

import Map "mo:core/Map";
import Text "mo:core/Text";
import Iter "mo:core/Iter";
import Time "mo:core/Time";
import Int "mo:core/Int";
import List "mo:core/List";
import NormalizedEventTypes "../events/types/normalized-event-types";
import Constants "../constants";

module {

  // ============================================
  // State Types
  // ============================================

  /// Complete event store state — three maps keyed by eventId
  public type EventStoreState = {
    unprocessed : Map.Map<Text, NormalizedEventTypes.Event>; // Awaiting or in-progress
    processed : Map.Map<Text, NormalizedEventTypes.Event>; // Successfully completed
    failed : Map.Map<Text, NormalizedEventTypes.Event>; // Failed with error
  };

  // ============================================
  // Initialization
  // ============================================

  /// Create an empty event store state
  public func empty() : EventStoreState {
    {
      unprocessed = Map.empty<Text, NormalizedEventTypes.Event>();
      processed = Map.empty<Text, NormalizedEventTypes.Event>();
      failed = Map.empty<Text, NormalizedEventTypes.Event>();
    };
  };

  // ============================================
  // Enqueue & Dedup
  // ============================================

  /// Enqueue a new event, rejecting duplicates.
  /// Dedup checks all three maps (unprocessed, processed, failed).
  /// Sets enqueuedAt to current time. The caller is responsible for scheduling the timer.
  ///
  /// @param state - The event store state
  /// @param event - The event to enqueue (must have eventId set)
  /// @returns #ok if enqueued, #duplicate if eventId exists in any map
  public func enqueue(state : EventStoreState, event : NormalizedEventTypes.Event) : {
    #ok;
    #duplicate;
  } {
    let eventId = event.eventId;

    // Check for duplicate across all three maps
    if (isDuplicate(state, eventId)) {
      return #duplicate;
    };

    // Stamp enqueuedAt and insert into unprocessed
    let stamped : NormalizedEventTypes.Event = {
      event with
      enqueuedAt = Time.now();
    };
    Map.add(state.unprocessed, Text.compare, eventId, stamped);
    #ok;
  };

  /// Check if an eventId exists in any of the three maps
  public func isDuplicate(state : EventStoreState, eventId : Text) : Bool {
    Map.containsKey(state.unprocessed, Text.compare, eventId) or Map.containsKey(state.processed, Text.compare, eventId) or Map.containsKey(state.failed, Text.compare, eventId);
  };

  // ============================================
  // Lifecycle Operations
  // ============================================

  /// Claim an event for processing — sets claimedAt timestamp.
  /// Returns the event if found in unprocessed, null otherwise.
  ///
  /// @param state - The event store state
  /// @param eventId - The event ID to claim
  /// @returns The claimed event or null if not found
  public func claim(state : EventStoreState, eventId : Text) : ?NormalizedEventTypes.Event {
    switch (Map.get(state.unprocessed, Text.compare, eventId)) {
      case (null) { null };
      case (?event) {
        let claimed : NormalizedEventTypes.Event = {
          event with
          claimedAt = ?Time.now();
        };
        Map.add(state.unprocessed, Text.compare, eventId, claimed);
        ?claimed;
      };
    };
  };

  /// Mark an event as successfully processed.
  /// Moves from unprocessed → processed with processedAt timestamp and processing log.
  ///
  /// @param state - The event store state
  /// @param eventId - The event ID to mark as processed
  /// @param steps - The processing steps taken by the handler
  public func markProcessed(state : EventStoreState, eventId : Text, steps : [NormalizedEventTypes.ProcessingStep]) {
    switch (Map.get(state.unprocessed, Text.compare, eventId)) {
      case (null) {}; // Already removed or not found — no-op
      case (?event) {
        let completed : NormalizedEventTypes.Event = {
          event with
          processedAt = ?Time.now();
          processingLog = steps;
        };
        Map.remove(state.unprocessed, Text.compare, eventId);
        Map.add(state.processed, Text.compare, eventId, completed);
      };
    };
  };

  /// Mark an event as failed.
  /// Moves from unprocessed → failed with failedAt timestamp and error message.
  ///
  /// @param state - The event store state
  /// @param eventId - The event ID to mark as failed
  /// @param error - The error message
  public func markFailed(state : EventStoreState, eventId : Text, error : Text) {
    switch (Map.get(state.unprocessed, Text.compare, eventId)) {
      case (null) {}; // Already removed or not found — no-op
      case (?event) {
        let errored : NormalizedEventTypes.Event = {
          event with
          failedAt = ?Time.now();
          failedError = error;
        };
        Map.remove(state.unprocessed, Text.compare, eventId);
        Map.add(state.failed, Text.compare, eventId, errored);
      };
    };
  };

  // ============================================
  // Lookups & Observability
  // ============================================

  /// Get an event by ID from any map
  public func get(state : EventStoreState, eventId : Text) : ?NormalizedEventTypes.Event {
    switch (Map.get(state.unprocessed, Text.compare, eventId)) {
      case (?event) { ?event };
      case (null) {
        switch (Map.get(state.processed, Text.compare, eventId)) {
          case (?event) { ?event };
          case (null) { Map.get(state.failed, Text.compare, eventId) };
        };
      };
    };
  };

  /// Get sizes of all three maps
  public func sizes(state : EventStoreState) : {
    unprocessed : Nat;
    processed : Nat;
    failed : Nat;
  } {
    {
      unprocessed = Map.size(state.unprocessed);
      processed = Map.size(state.processed);
      failed = Map.size(state.failed);
    };
  };

  // ============================================
  // Failed Events — Admin Operations
  // ============================================

  /// List all failed events as an array
  public func listFailed(state : EventStoreState) : [NormalizedEventTypes.Event] {
    let entries = Map.values(state.failed);
    Iter.toArray(entries);
  };

  /// Delete failed event(s).
  /// If eventId is null, deletes ALL failed events.
  /// If eventId is provided, deletes only that one.
  /// Returns the number of events deleted.
  public func deleteFailed(state : EventStoreState, eventId : ?Text) : Nat {
    switch (eventId) {
      case (null) {
        // Delete all failed events
        let count = Map.size(state.failed);
        Map.clear(state.failed);
        count;
      };
      case (?id) {
        if (Map.containsKey(state.failed, Text.compare, id)) {
          Map.remove(state.failed, Text.compare, id);
          1;
        } else {
          0;
        };
      };
    };
  };

  // ============================================
  // Cleanup — Processed Events
  // ============================================

  /// Purge processed events older than 7 days (called by periodic timer)
  /// Returns the number of events purged
  public func purgeProcessed(state : EventStoreState) : Nat {
    let sevenDaysInNanos = Int.fromNat(Constants.SEVEN_DAYS_NS);
    let now = Time.now();

    // Collect keys to remove without modifying the map during iteration
    var keysToRemove = List.empty<Text>();
    for ((eventId, event) in Map.entries(state.processed)) {
      switch (event.processedAt) {
        case (null) {};
        case (?processedTime) {
          if (now - processedTime > sevenDaysInNanos) {
            List.add(keysToRemove, eventId);
          };
        };
      };
    };

    // Now remove the collected keys
    List.forEach<Text>(
      keysToRemove,
      func(eventId) {
        Map.remove(state.processed, Text.compare, eventId);
      },
    );

    List.size(keysToRemove);
  };

  // ============================================
  // Cleanup — Stale Unprocessed Events
  // ============================================

  /// Move unprocessed events that have been sitting for more than 1 hour to failed.
  /// These are events whose timer was never triggered (e.g. due to a canister restart).
  /// Returns the list of event IDs that were moved to failed.
  public func failStaleUnprocessed(state : EventStoreState) : [Text] {
    let oneHourInNanos = Int.fromNat(Constants.ONE_HOUR_NS);
    let now = Time.now();

    var staleIds = List.empty<Text>();
    for ((eventId, event) in Map.entries(state.unprocessed)) {
      if (now - event.enqueuedAt > oneHourInNanos) {
        List.add(staleIds, eventId);
      };
    };

    // Move each stale event from unprocessed → failed
    List.forEach<Text>(
      staleIds,
      func(eventId) {
        switch (Map.get(state.unprocessed, Text.compare, eventId)) {
          case (null) {};
          case (?event) {
            let errored : NormalizedEventTypes.Event = {
              event with
              failedAt = ?now;
              failedError = "Event was not picked up within 1 hour of being enqueued.";
            };
            Map.remove(state.unprocessed, Text.compare, eventId);
            Map.add(state.failed, Text.compare, eventId, errored);
          };
        };
      },
    );

    List.toArray(staleIds);
  };

  // ============================================
  // Cleanup — Old Failed Events
  // ============================================

  /// Purge failed events whose failedAt timestamp is older than 30 days.
  /// Returns the number of events deleted.
  public func purgeOldFailed(state : EventStoreState) : Nat {
    let thirtyDaysInNanos = Int.fromNat(Constants.THIRTY_DAYS_NS);
    let now = Time.now();

    var keysToRemove = List.empty<Text>();
    for ((eventId, event) in Map.entries(state.failed)) {
      switch (event.failedAt) {
        case (null) {};
        case (?failedTime) {
          if (now - failedTime > thirtyDaysInNanos) {
            List.add(keysToRemove, eventId);
          };
        };
      };
    };

    List.forEach<Text>(
      keysToRemove,
      func(eventId) {
        Map.remove(state.failed, Text.compare, eventId);
      },
    );

    List.size(keysToRemove);
  };
};
