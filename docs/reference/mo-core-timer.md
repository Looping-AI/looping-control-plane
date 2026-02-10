# mo:core Timer module

Detailed reference for `mo:core/Timer`, preserving the exact wording, cautions, and examples from the upstream docs.

## Import

```motoko name=import
import Timer "mo:core/Timer";

```

## Overview

- Provides one-off and recurring timers when compiling without `-no-timer`.
- Timers share resolution with block production; for frequent wake-ups prefer the heartbeat.
- Timers vanish on upgrades; store needed state and re-establish in `post_upgrade`.
- Using timers for security is discouraged; consider queue congestion and `--trap-on-call-error` behavior.

## API

````motoko
public type TimerId = Nat;

/// Installs a one-off timer that upon expiration after given duration `d`
/// executes the future `job()`.
///
/// ```motoko include=import no-repl
/// import Int "mo:core/Int";
///
/// func runIn30Minutes() : async () {
///   // ...
/// };
/// let timerId = Timer.setTimer<system>(#minutes 30, runIn30Minutes);
/// ```
public func setTimer<system>(duration : Time.Duration, job : () -> async ()) : TimerId;

/// Installs a recurring timer that upon expiration after given duration `d`
/// executes the future `job()` and reinserts itself for another expiration.
///
/// Note: A duration of 0 will only expire once.
///
/// ```motoko include=import no-repl
/// func runEvery30Minutes() : async () {
///   // ...
/// };
/// let timerId = Timer.recurringTimer<system>(#minutes 30, runEvery30Minutes);
/// ```
public func recurringTimer<system>(duration : Time.Duration, job : () -> async ()) : TimerId;

/// Cancels a still active timer with `(id : TimerId)`. For expired timers
/// and not recognized `id`s nothing happens.
///
/// ```motoko include=import no-repl
/// var counter = 0;
/// var timerId : ?Timer.TimerId = null;
/// func runFiveTimes() : async () {
///   counter += 1;
///   if (counter == 5) {
///     switch (timerId) {
///       case (?id) { Timer.cancelTimer(id) };
///       case null { assert false /* timer already cancelled */ };
///     };
///   }
/// };
/// timerId := ?Timer.recurringTimer<system>(#minutes 30, runFiveTimes);
/// ```
public let cancelTimer : TimerId -> () = cancel;

````

---

This file mirrors `src/Timer.mo` so AI tooling has immediate access to the canonical examples.
