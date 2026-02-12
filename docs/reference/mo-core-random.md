# mo:core Random module

Detailed reference for `mo:core/Random`, preserving the exact wording, cautions, and examples from the upstream docs.

## Import

```motoko name=import
import Random "mo:core/Random";

```

## Overview

- Provides pseudo-random (seeded) and cryptographic randomness via the management canister’s `raw_rand`.
- Exposes synchronous `Random` generators (PRNG) and asynchronous `AsyncRandom` generators (crypto entropy).
- Many helpers are marked `@deprecated M0235` in upstream docs but remain documented verbatim.

## Direct raw entropy

```motoko
public let blob : shared () -> async Blob = rawRand;

public func bool() : async Bool;
public func nat8() : async Nat8;
public func nat64() : async Nat64;
public func nat64Range(fromInclusive : Nat64, toExclusive : Nat64) : async Nat64;
public func natRange(fromInclusive : Nat, toExclusive : Nat) : async Nat;
public func intRange(fromInclusive : Int, toExclusive : Int) : async Int;

```

## Stateful PRNG helpers (deprecated)

````motoko
/// Initializes a random number generator state. This is used
/// to create a `Random` or `AsyncRandom` instance with a specific state.
/// The state is empty, but it can be reused after upgrading the canister.
///
/// Example:
/// ```motoko
/// import Random "mo:core/Random";
///
/// persistent actor {
///   let state = Random.emptyState();
///   transient let random = Random.cryptoFromState(state);
///
///   public func main() : async () {
///     let coin = await* random.bool(); // true or false
///   }
/// }
/// ```
/// @deprecated M0235
public func emptyState() : State;

/// Initializes a pseudo-random number generator state with a 64-bit seed.
/// This is used to create a `Random` instance with a specific seed.
///
/// Example:
/// ```motoko
/// import Random "mo:core/Random";
///
/// persistent actor {
///   let state = Random.seedState(123);
///   transient let random = Random.seedFromState(state);
///
///   public func main() : async () {
///     let coin = random.bool(); // true or false
///   }
/// }
/// ```
/// @deprecated M0235
public func seedState(seed : Nat64) : SeedState;

/// Creates a pseudo-random number generator from a 64-bit seed.
/// The seed is used to initialize the PRNG state.
/// This is suitable for simulations and testing, but not for cryptographic purposes.
///
/// Example:
/// ```motoko include=import
/// let random = Random.seed(123);
/// let coin = random.bool(); // true or false
/// ```
/// @deprecated M0235
public func seed(seed : Nat64) : Random;

/// Creates a pseudo-random number generator with the given state.
/// This provides statistical randomness suitable for simulations and testing,
/// but should not be used for cryptographic purposes.
///
/// Example:
/// ```motoko
/// import Random "mo:core/Random";
///
/// persistent actor {
///   let state = Random.seedState(123);
///   transient let random = Random.seedFromState(state);
///
///   public func main() : async () {
///     let coin = random.bool(); // true or false
///   }
/// }
/// ```
/// @deprecated M0235
public func seedFromState(state : SeedState) : Random;

````

## Cryptographic RNG helpers (deprecated)

````motoko
/// Initializes a cryptographic random number generator
/// using entropy from the ICP management canister.
///
/// Example:
/// ```motoko
/// import Random "mo:core/Random";
///
/// persistent actor {
///   transient let random = Random.crypto();
///
///   public func main() : async () {
///     let coin = await* random.bool(); // true or false
///   }
/// }
/// ```
/// @deprecated M0235
public func crypto() : AsyncRandom;

/// Creates a random number generator suitable for cryptography
/// using entropy from the ICP management canister. Initializing
/// from a state makes it possible to reuse entropy after
/// upgrading the canister.
///
/// Example:
/// ```motoko
/// import Random "mo:core/Random";
///
/// persistent actor {
///   let state = Random.emptyState();
///   transient let random = Random.cryptoFromState(state);
///
///   func example() : async () {
///     let coin = await* random.bool(); // true or false
///   }
/// }
/// ```
/// @deprecated M0235
public func cryptoFromState(state : State) : AsyncRandom;

````

## Class `Random` (synchronous PRNG, deprecated)

```motoko
/// @deprecated M0235
public class Random(state : State, generator : () -> Blob) {
  /// Random choice between `true` and `false`.
  public func bool() : Bool;

  /// Random `Nat8` value in the range [0, 256).
  public func nat8() : Nat8;

  /// Random `Nat64` value in the range [0, 2^64).
  public func nat64() : Nat64;

  /// Random `Nat64` value in the range [fromInclusive, toExclusive).
  public func nat64Range(fromInclusive : Nat64, toExclusive : Nat64) : Nat64;

  /// Random `Nat` value in the range [fromInclusive, toExclusive).
  public func natRange(fromInclusive : Nat, toExclusive : Nat) : Nat;

  /// Random `Int` value in the range [fromInclusive, toExclusive).
  public func intRange(fromInclusive : Int, toExclusive : Int) : Int;
};

```

## Class `AsyncRandom` (crypto RNG, deprecated)

```motoko
/// @deprecated M0235
public class AsyncRandom(state : State, generator : () -> async* Blob) {
  /// Random choice between `true` and `false` (awaitable).
  public func bool() : async* Bool;

  /// Random `Nat8` value in the range [0, 256).
  public func nat8() : async* Nat8;

  /// Random `Nat64` value in the range [0, 2^64).
  public func nat64() : async* Nat64;

  /// Random `Nat64` value in the range [fromInclusive, toExclusive).
  public func nat64Range(fromInclusive : Nat64, toExclusive : Nat64) : async* Nat64;

  /// Random `Nat` value in the range [fromInclusive, toExclusive).
  public func natRange(fromInclusive : Nat, toExclusive : Nat) : async* Nat;

  /// Random `Int` value in the range [fromInclusive, toExclusive).
  public func intRange(fromInclusive : Int, toExclusive : Int) : async* Int;
};

```

---

This file mirrors `src/Random.mo` so AI tooling has immediate access to the canonical examples.
