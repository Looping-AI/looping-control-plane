/// Approval Timer
///
/// One-shot timer helpers for per-turn approval TTL enforcement.
///
/// `arm<system>` schedules a callback to fire at a specific nanosecond deadline.
/// If the deadline has already passed, the timer fires on the next block boundary.
///
/// `cancel` wraps `Timer.cancelTimer` — cancelling an already-fired or unknown
/// timer ID is a no-op (safe to call without a race guard).
///
/// `<system>` capability note: `arm` requires `<system>` because it calls
/// `Timer.setTimer<system>`. Callers must propagate this capability explicitly,
/// or store the `arm` call inside a closure created in an actor body (where
/// `<system>` is always available) and thread that closure through context.

import Timer "mo:core/Timer";
import Time "mo:core/Time";
import Int "mo:core/Int";

module {

  /// Schedule a one-shot callback to fire at `expiresAtNs` (nanoseconds since epoch).
  /// If `expiresAtNs` is already in the past, the timer fires on the next block.
  /// Returns the `TimerId` needed to cancel the timer before it fires.
  public func arm<system>(expiresAtNs : Int, callback : () -> async ()) : Timer.TimerId {
    let now = Time.now();
    let delayNs : Nat = if (expiresAtNs > now) {
      Int.toNat(expiresAtNs - now);
    } else {
      0;
    };
    Timer.setTimer<system>(#nanoseconds(delayNs), callback);
  };

  /// Cancel a pending approval timer. Safe to call even if the timer has already
  /// fired or the ID is unrecognised (both are no-ops per `Timer.cancelTimer`).
  public func cancel(timerId : Timer.TimerId) : () {
    Timer.cancelTimer(timerId);
  };

};
