/// Event Queue Model
/// Persistent queue for storing normalized events before processing
///
/// Features:
///   - FIFO queue backed by mo:core/Queue
///   - Deduplication via bounded set of recent event IDs
///   - Persistent state that survives upgrades
///   - Queue size observability

import Queue "mo:core/Queue";
import Set "mo:core/Set";
import Text "mo:core/Text";
import NormalizedEventTypes "../events/types/normalized-event-types";

module {

  // ============================================
  // Constants
  // ============================================

  /// Maximum number of recent event IDs to track for deduplication
  /// After this, old entries are not explicitly removed but the set is bounded
  /// by the natural churn of events
  let MAX_DEDUP_ENTRIES : Nat = 1000;

  // ============================================
  // State Types
  // ============================================

  /// Complete event queue state
  public type EventQueueState = {
    queue : Queue.Queue<NormalizedEventTypes.Event>; // Pending events (FIFO)
    var dedupSet : Set.Set<Text>; // Recent event idempotency keys for dedup
  };

  // ============================================
  // Initialization
  // ============================================

  /// Create an empty event queue state
  public func empty() : EventQueueState {
    {
      queue = Queue.empty<NormalizedEventTypes.Event>();
      var dedupSet = Set.empty<Text>();
    };
  };

  // ============================================
  // Queue Operations
  // ============================================

  /// Enqueue a new event, rejecting duplicates
  ///
  /// @param state - The event queue state
  /// @param event - The event to enqueue
  /// @returns #ok if enqueued, #duplicate if the event was already seen
  public func enqueue(state : EventQueueState, event : NormalizedEventTypes.Event) : {
    #ok;
    #duplicate;
  } {
    // Check for duplicate
    if (Set.contains(state.dedupSet, Text.compare, event.idempotencyKey)) {
      return #duplicate;
    };

    // Prune dedup set if it's getting too large
    if (Set.size(state.dedupSet) >= MAX_DEDUP_ENTRIES) {
      // Reset the set — we accept a small window of potential re-processing
      // rather than building a complex eviction scheme.
      // In practice, Slack retries happen within seconds, not across 1000+ events.
      state.dedupSet := Set.empty<Text>();
    };

    // Record idempotency key and enqueue
    Set.add(state.dedupSet, Text.compare, event.idempotencyKey);
    Queue.pushBack(state.queue, event);
    #ok;
  };

  /// Dequeue the next pending event
  ///
  /// @param state - The event queue state
  /// @returns The next event, or null if queue is empty
  public func dequeue(state : EventQueueState) : ?NormalizedEventTypes.Event {
    Queue.popFront(state.queue);
  };

  /// Peek at the next pending event without removing it
  ///
  /// @param state - The event queue state
  /// @returns The next event, or null if queue is empty
  public func peek(state : EventQueueState) : ?NormalizedEventTypes.Event {
    Queue.peekFront(state.queue);
  };

  /// Get the number of pending events in the queue
  ///
  /// @param state - The event queue state
  /// @returns Number of pending events
  public func size(state : EventQueueState) : Nat {
    Queue.size(state.queue);
  };

  /// Check if the queue is empty
  ///
  /// @param state - The event queue state
  /// @returns true if no pending events
  public func isEmpty(state : EventQueueState) : Bool {
    Queue.isEmpty(state.queue);
  };
};
