/// Round Context Store
///
/// Maps Slack thread timestamps to their most recent `UserAuthContext`.
///
/// When a user sends the first message in a thread, the handler builds a fresh
/// `UserAuthContext` (roundCount = 0) and saves it here under the thread's root
/// timestamp.  When the bot subsequently posts a reply that includes a
/// `::agentname` reference, causing Slack to re-deliver the event, the handler
/// looks up the thread's stored context, inherits it, and increments `roundCount`
/// before routing to the next agent.
///
/// Key   : Slack thread-root timestamp (`threadTs` as Text).
///         For top-level messages that have no parent thread, the message's own
///         `ts` is used so that bot replies — which will carry `threadTs = ts` —
///         can still find the session.
///
/// Value : `UserAuthContext` holding identity + round-control fields.
///
/// Storage is mutated in-place (the Map is passed by reference through the
/// EventProcessingContext).  Retention clean-up is left for Phase 1.6 when the
/// full session model is introduced.

import Map "mo:core/Map";
import Text "mo:core/Text";
import SlackAuthMiddleware "../middleware/slack-auth-middleware";

module {

  /// Re-export for convenience so callers only need one import.
  public type UserAuthContext = SlackAuthMiddleware.UserAuthContext;

  /// The mutable store: a Text-keyed map of `UserAuthContext` values.
  public type RoundContextStoreState = Map.Map<Text, UserAuthContext>;

  // ============================================
  // Constructor
  // ============================================

  /// Create a new, empty round context store.
  public func empty() : RoundContextStoreState {
    Map.empty<Text, UserAuthContext>();
  };

  // ============================================
  // Mutations
  // ============================================

  /// Save (or overwrite) the `UserAuthContext` for a thread.
  ///
  /// Idempotent: calling twice with the same `threadTs` replaces the previous
  /// entry.  Used on every event so the store always holds the *latest* round
  /// state for each thread.
  public func save(
    store : RoundContextStoreState,
    threadTs : Text,
    ctx : UserAuthContext,
  ) {
    Map.add(store, Text.compare, threadTs, ctx);
  };

  // ============================================
  // Queries
  // ============================================

  /// Look up the `UserAuthContext` for a thread.
  ///
  /// Returns `null` when no session has been recorded for `threadTs` — the
  /// caller should treat this as "no active session; skip processing".
  public func lookup(
    store : RoundContextStoreState,
    threadTs : Text,
  ) : ?UserAuthContext {
    Map.get(store, Text.compare, threadTs);
  };

};
