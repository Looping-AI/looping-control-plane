# mo:core Principal module

Detailed reference for `mo:core/Principal`, preserving the exact wording, cautions, and examples from the upstream docs.

## Import

```motoko name=import
import Principal "mo:core/Principal";

```

## Overview

- Principals identify users and canisters on the Internet Computer; textual form looks like `un4fu-tqaaa-aaaab-qadjq-cai`.
- Shared functions access the caller via `msg.caller : Principal` and then use this module for conversions, hashing, and comparisons.

## Creation and serialization

````motoko
/// Get the `Principal` identifier of an actor.
///
/// Example:
/// ```motoko include=import no-repl
/// persistent actor MyCanister {
///   func getPrincipal() : Principal {
///     let principal = Principal.fromActor(MyCanister);
///   }
/// }
/// ```
public func fromActor(a : actor {}) : Principal = Prim.principalOfActor a;

/// Compute the Ledger account identifier of a principal. Optionally specify a sub-account.
///
/// Example:
/// ```motoko include=import no-validate
/// let principal = Principal.fromText("un4fu-tqaaa-aaaab-qadjq-cai");
/// let subAccount : Blob = "\4A\8D\3F\2B\6E\01\C8\7D\9E\03\B4\56\7C\F8\9A\01\D2\34\56\78\9A\BC\DE\F0\12\34\56\78\9A\BC\DE\F0";
/// let account = Principal.toLedgerAccount(principal, ?subAccount);
/// assert account == "\8C\5C\20\C6\15\3F\7F\51\E2\0D\0F\0F\B5\08\51\5B\47\65\63\A9\62\B4\A9\91\5F\4F\02\70\8A\ED\4F\82";
/// ```
public func toLedgerAccount(self : Principal, subAccount : ?Blob) : Blob;

/// Convert a `Principal` to its `Blob` (bytes) representation.
///
/// Example:
/// ```motoko include=import
/// let principal = Principal.fromText("un4fu-tqaaa-aaaab-qadjq-cai");
/// let blob = Principal.toBlob(principal);
/// assert blob == "\00\00\00\00\00\30\00\D3\01\01";
/// ```
public func toBlob(self : Principal) : Blob = Prim.blobOfPrincipal self;

/// Converts a `Blob` (bytes) representation of a `Principal` to a `Principal` value.
///
/// Example:
/// ```motoko include=import
/// let blob = "\00\00\00\00\00\30\00\D3\01\01" : Blob;
/// let principal = Principal.fromBlob(blob);
/// assert Principal.toText(principal) == "un4fu-tqaaa-aaaab-qadjq-cai";
/// ```
public func fromBlob(self : Blob) : Principal = Prim.principalOfBlob self;

/// Converts a `Principal` to its `Text` representation.
///
/// Example:
/// ```motoko include=import
/// let principal = Principal.fromText("un4fu-tqaaa-aaaab-qadjq-cai");
/// assert Principal.toText(principal) == "un4fu-tqaaa-aaaab-qadjq-cai";
/// ```
public func toText(self : Principal) : Text = debug_show (self);

/// Converts a `Text` representation of a `Principal` to a `Principal` value.
///
/// Example:
/// ```motoko include=import
/// let principal = Principal.fromText("un4fu-tqaaa-aaaab-qadjq-cai");
/// assert Principal.toText(principal) == "un4fu-tqaaa-aaaab-qadjq-cai";
/// ```
public func fromText(t : Text) : Principal = fromActor(actor (t));

````

## Special principals

````motoko
private let anonymousBlob : Blob = "\04";

/// Constructs and returns the anonymous principal.
public func anonymous() : Principal = Prim.principalOfBlob(anonymousBlob);

/// Checks if the given principal represents an anonymous user.
///
/// Example:
/// ```motoko include=import
/// let principal = Principal.fromText("un4fu-tqaaa-aaaab-qadjq-cai");
/// assert not Principal.isAnonymous(principal);
/// ```
public func isAnonymous(self : Principal) : Bool = Prim.blobOfPrincipal self == anonymousBlob;

````

## Classification helpers

````motoko
/// Checks if the given principal is a canister.
///
/// The last byte for opaque principal ids must be 0x01
/// https://internetcomputer.org/docs/current/references/ic-interface-spec#principal
///
/// Example:
/// ```motoko include=import
/// let principal = Principal.fromText("un4fu-tqaaa-aaaab-qadjq-cai");
/// assert Principal.isCanister(principal);
/// ```
public func isCanister(self : Principal) : Bool;

/// Checks if the given principal is a self authenticating principal.
/// Most of the time, this is a user principal.
///
/// The last byte for user principal ids must be 0x02
/// https://internetcomputer.org/docs/current/references/ic-interface-spec#principal
///
/// Example:
/// ```motoko include=import
/// let principal = Principal.fromText("6rgy7-3uukz-jrj2k-crt3v-u2wjm-dmn3t-p26d6-ndilt-3gusv-75ybk-jae");
/// assert Principal.isSelfAuthenticating(principal);
/// ```
public func isSelfAuthenticating(self : Principal) : Bool;

/// Checks if the given principal is a reserved principal.
///
/// The last byte for reserved principal ids must be 0x7f
/// https://internetcomputer.org/docs/current/references/ic-interface-spec#principal
///
/// Example:
/// ```motoko include=import
/// let principal = Principal.fromText("un4fu-tqaaa-aaaab-qadjq-cai");
/// assert not Principal.isReserved(principal);
/// ```
public func isReserved(self : Principal) : Bool;

/// Checks if the given principal can control this canister.
///
/// Example:
/// ```motoko include=import
/// let principal = Principal.fromText("un4fu-tqaaa-aaaab-qadjq-cai");
/// assert not Principal.isController(principal);
/// ```
public func isController(self : Principal) : Bool = Prim.isController self;

````

## Hashing and ordering

````motoko
/// Hashes the given principal by hashing its `Blob` representation.
///
/// Example:
/// ```motoko include=import
/// let principal = Principal.fromText("un4fu-tqaaa-aaaab-qadjq-cai");
/// assert Principal.hash(principal) == 2_742_573_646;
/// ```
public func hash(self : Principal) : Types.Hash = Blob.hash(Prim.blobOfPrincipal(self));

/// General purpose comparison function for `Principal`. Returns the `Order` (
/// either `#less`, `#equal`, or `#greater`) of comparing `principal1` with
/// `principal2`.
///
/// Example:
/// ```motoko include=import
/// let principal1 = Principal.fromText("un4fu-tqaaa-aaaab-qadjq-cai");
/// let principal2 = Principal.fromText("un4fu-tqaaa-aaaab-qadjq-cai");
/// assert Principal.compare(principal1, principal2) == #equal;
/// ```
public func compare(self : Principal, other : Principal) : {
  #less;
  #equal;
  #greater;
};

````

## Convenience comparison functions

````motoko
/// Equality function for Principal types.
/// This is equivalent to `principal1 == principal2`.
///
/// Example:
/// ```motoko include=import
/// let principal1 = Principal.anonymous();
/// let principal2 = Principal.fromBlob("\04");
/// assert Principal.equal(principal1, principal2);
/// ```
public func equal(self : Principal, other : Principal) : Bool { self == other };

/// Inequality function for Principal types.
/// This is equivalent to `principal1 != principal2`.
public func notEqual(self : Principal, other : Principal) : Bool {
  self != other;
};

/// "Less than" function for Principal types.
/// This is equivalent to `principal1 < principal2`.
public func less(self : Principal, other : Principal) : Bool { self < other };

/// "Less than or equal to" function for Principal types.
/// This is equivalent to `principal1 <= principal2`.
public func lessOrEqual(self : Principal, other : Principal) : Bool {
  self <= other;
};

/// "Greater than" function for Principal types.
/// This is equivalent to `principal1 > principal2`.
public func greater(self : Principal, other : Principal) : Bool { self > other };

/// "Greater than or equal to" function for Principal types.
/// This is equivalent to `principal1 >= principal2`.
public func greaterOrEqual(self : Principal, other : Principal) : Bool {
  self >= other;
};

````

---

This file mirrors `src/Principal.mo` so AI tooling has immediate access to the canonical examples.
