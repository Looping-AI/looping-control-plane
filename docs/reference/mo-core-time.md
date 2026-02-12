# mo:core Time module

Detailed reference for `mo:core/Time`, preserving the exact wording, cautions, and examples from the upstream docs.

## Import

```motoko name=import
import Time "mo:core/Time";

```

## Overview

- System time utilities; timers require `moc` builds without `-no-timer`.
- Time is measured as nanoseconds since 1970-01-01; monotonic within a canister, even across upgrades.
- Timer resolution roughly matches block rate, so choose durations above that granularity.

## Example usage

````motoko
/// ```motoko
/// import Int = "mo:core/Int";
/// import Time = "mo:core/Time";
///
/// persistent actor {
///   var lastTime = Time.now();
///
///   public func greet(name : Text) : async Text {
///     let now = Time.now();
///     let elapsedSeconds = (now - lastTime) / 1000_000_000;
///     lastTime := now;
///     return "Hello, " # name # "!" #
///       " I was last called " # Int.toText(elapsedSeconds) # " seconds ago";
///    };
/// };
/// ```

````

## API

```motoko
/// System time is represent as nanoseconds since 1970-01-01.
public type Time = Types.Time;

/// Quantity of time expressed in `#days`, `#hours`, `#minutes`, `#seconds`, `#milliseconds`, or `#nanoseconds`.
public type Duration = Types.Duration;

/// Current system time given as nanoseconds since 1970-01-01.
/// Guarantees:
/// * monotonically increasing per canister, even across upgrades.
/// * constant within a single entry-point invocation.
/// System times of different canisters are unrelated.
public let now : () -> Time = func() : Int = Prim.nat64ToNat(Prim.time());

public type TimerId = Nat;

public func toNanoseconds(duration : Duration) : Nat {
  switch duration {
    case (#days n) n * 86_400_000_000_000;
    case (#hours n) n * 3_600_000_000_000;
    case (#minutes n) n * 60_000_000_000;
    case (#seconds n) n * 1_000_000_000;
    case (#milliseconds n) n * 1_000_000;
    case (#nanoseconds n) n;
  };
};

```

---

This file mirrors `src/Time.mo` so AI tooling has immediate access to the canonical examples.
