# mo:core Cycles module

Detailed reference for `mo:core/Cycles`, preserving the exact wording, cautions, and examples from the upstream docs.

## Import

```motoko name=import
import Cycles "mo:core/Cycles";

```

## Overview

- Cycles measure computation on the Internet Computer; every call consumes and transfers cycles.
- `balance()` reflects the actor’s cycle wallet but changes between calls as resources are used.
- Attach cycles to expressions using `(with cycles = <amount>) <exp>`; the amount must not exceed `2 ** 128`.
- If a call’s requested cycles exceed the caller’s balance, evaluation traps before the call is issued.
- Transferring cycles to a local async function just moves cycles within the same canister.

## Examples

````motoko
/// Example for use on the ICP:
/// ```motoko no-repl
/// import Cycles "mo:core/Cycles";
///
/// persistent actor {
///   public func main() : async () {
///     let initialBalance = Cycles.balance();
///     await (with cycles = 15_000_000) operation(); // accepts 10_000_000 cycles
///     assert Cycles.refunded() == 5_000_000;
///     assert Cycles.balance() < initialBalance; // decreased by around 10_000_000
///   };
///
///   func operation() : async () {
///     let initialBalance = Cycles.balance();
///     let initialAvailable = Cycles.available();
///     let obtained = Cycles.accept<system>(10_000_000);
///     assert obtained == 10_000_000;
///     assert Cycles.balance() == initialBalance + 10_000_000;
///     assert Cycles.available() == initialAvailable - 10_000_000;
///   }
/// }
/// ```

````

## Cycle balance helpers

````motoko
/// Returns the actor's current balance of cycles as `amount`.
///
/// Example for use on the ICP:
/// ```motoko no-repl
/// import Cycles "mo:core/Cycles";
///
/// persistent actor {
///   public func main() : async() {
///     let balance = Cycles.balance();
///     assert balance > 0;
///   }
/// }
/// ```
public let balance : () -> (amount : Nat) = Prim.cyclesBalance;

/// Returns the currently available `amount` of cycles.
/// The amount available is the amount received in the current call,
/// minus the cumulative amount `accept`ed by this call.
/// On exit from the current shared function or async expression via `return` or `throw`,
/// any remaining available amount is automatically refunded to the caller/context.
///
/// Example for use on the ICP:
/// ```motoko no-repl
/// import Cycles "mo:core/Cycles";
///
/// persistent actor {
///   public func main() : async() {
///     let available = Cycles.available();
///     assert available >= 0;
///   }
/// }
/// ```
public let available : () -> (amount : Nat) = Prim.cyclesAvailable;

````

## Accepting, refunding, and burning cycles

````motoko
/// Transfers up to `amount` from `available()` to `balance()`.
/// Returns the amount actually transferred, which may be less than
/// requested, for example, if less is available, or if canister balance limits are reached.
///
/// Example for use on the ICP (for simplicity, only transferring cycles to itself):
/// ```motoko no-repl
/// import Cycles "mo:core/Cycles";
///
/// persistent actor {
///   public func main() : async() {
///     await (with cycles = 15_000_000) operation(); // accepts 10_000_000 cycles
///   };
///
///   func operation() : async() {
///     let obtained = Cycles.accept<system>(10_000_000);
///     assert obtained == 10_000_000;
///   }
/// }
/// ```
public let accept : <system>(amount : Nat) -> (accepted : Nat) = Prim.cyclesAccept;

/// Reports `amount` of cycles refunded in the last `await` of the current
/// context, or zero if no await has occurred yet.
/// Calling `refunded()` is solely informational and does not affect `balance()`.
/// Instead, refunds are automatically added to the current balance,
/// whether or not `refunded` is used to observe them.
///
/// Example for use on the ICP (for simplicity, only transferring cycles to itself):
/// ```motoko no-repl
/// import Cycles "mo:core/Cycles";
///
/// persistent actor {
///   func operation() : async() {
///     ignore Cycles.accept<system>(10_000_000);
///   };
///
///   public func main() : async() {
///     await (with cycles = 15_000_000) operation(); // accepts 10_000_000 cycles
///     assert Cycles.refunded() == 5_000_000;
///   }
/// }
/// ```
public let refunded : () -> (amount : Nat) = Prim.cyclesRefunded;

/// Attempts to burn `amount` of cycles, deducting `burned` from the canister's
/// cycle balance. The burned cycles are irrevocably lost and not available to any
/// other principal either.
///
/// Example for use on the IC:
/// ```motoko no-repl
/// import Cycles "mo:core/Cycles";
///
/// persistent actor {
///   public func main() : async() {
///     let burnt = Cycles.burn<system>(10_000_000);
///     assert burnt == 10_000_000;
///   }
/// }
/// ```
public let burn : <system>(amount : Nat) -> (burned : Nat) = Prim.cyclesBurn;

````

---

This file mirrors `src/Cycles.mo` so AI tooling has immediate access to the canonical examples.
