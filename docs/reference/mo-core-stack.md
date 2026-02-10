# mo:core Stack module

Detailed reference for `mo:core/Stack`, preserving the exact wording, cautions, and examples from the upstream docs.

## Import

```motoko name=import
import Stack "mo:core/Stack";

```

## Overview

- Mutable LIFO stack backed by a singly-linked list (`pure/List`).
- Push/pop/peek in `O(1)`; `O(n)` operations when scanning or cloning.
- Deprecated helpers convert to/from pure lists (`Stack.toPure`, `Stack.fromPure`).

## Pure conversions and array helpers

```motoko
/// Convert a mutable stack to an immutable, purely functional list.
/// @deprecated M0235
public func toPure<T>(self : Stack<T>) : PureList.List<T>;

public func toArray<T>(self : Stack<T>) : [T];
public func toVarArray<T>(self : Stack<T>) : [var T];

/// Convert an immutable, purely functional list to a mutable stack.
/// @deprecated M0235
public func fromPure<T>(list : PureList.List<T>) : Stack<T>;

public func fromVarArray<T>(array : [var T]) : Stack<T>;
public func fromArray<T>(array : [T]) : Stack<T>;
public func fromIter<T>(iter : Iter.Iter<T>) : Stack<T>;

```

## Construction

```motoko
/// Create a new empty mutable stack.
public func empty<T>() : Stack<T>;

/// Creates a new stack with `size` elements via `generator` (index 0 becomes bottom).
public func tabulate<T>(size : Nat, generator : Nat -> T) : Stack<T>;

/// Creates a new stack containing a single element.
public func singleton<T>(element : T) : Stack<T>;

/// Removes all elements from the stack.
public func clear<T>(self : Stack<T>);

/// Creates a deep copy of the stack with the same elements in the same order.
public func clone<T>(self : Stack<T>) : Stack<T>;

```

## Inspection helpers

```motoko
public func isEmpty<T>(self : Stack<T>) : Bool;
public func size<T>(self : Stack<T>) : Nat;
public func contains<T>(self : Stack<T>, equal : (implicit : (T, T) -> Bool), element : T) : Bool;
public func reverseValues<T>(self : Stack<T>) : Iter.Iter<T>;

/// Returns the element at a given depth (0 = top).
public func get<T>(self : Stack<T>, position : Nat) : ?T;

/// Returns the index of the first element satisfying the predicate.
public func find<T>(self : Stack<T>, predicate : T -> Bool) : ?Nat;

/// Returns true if any element satisfies the predicate.
public func any<T>(self : Stack<T>, predicate : T -> Bool) : Bool;

/// Returns true if all elements satisfy the predicate.
public func all<T>(self : Stack<T>, predicate : T -> Bool) : Bool;

/// Counts how many elements satisfy the predicate.
public func count<T>(self : Stack<T>, predicate : T -> Bool) : Nat;

/// Returns the minimum/maximum according to `compare`.
public func min<T>(self : Stack<T>, compare : (implicit : (T, T) -> Order.Order)) : ?T;
public func max<T>(self : Stack<T>, compare : (implicit : (T, T) -> Order.Order)) : ?T;

```

## Core operations

```motoko
public func push<T>(self : Stack<T>, value : T);
public func peek<T>(self : Stack<T>) : ?T;
public func pop<T>(self : Stack<T>) : ?T;

```

## Iteration and transformation

```motoko
public func values<T>(self : Stack<T>) : Iter.Iter<T>;
public func reverse<T>(self : Stack<T>);
public func map<T, R>(self : Stack<T>, mapFn : T -> R) : Stack<R>;
public func mapInPlace<T>(self : Stack<T>, update : T -> T);
public func filter<T>(self : Stack<T>, predicate : T -> Bool) : Stack<T>;
public func filterInPlace<T>(self : Stack<T>, predicate : T -> Bool);
public func partition<T>(self : Stack<T>, predicate : T -> Bool) : (Stack<T>, Stack<T>);
public func foldLeft<T, R>(self : Stack<T>, init : R, combine : (R, T) -> R) : R;
public func foldRight<T, R>(self : Stack<T>, init : R, combine : (T, R) -> R) : R;
public func foreach<T>(self : Stack<T>, f : T -> ());

```

---

This file mirrors `src/Stack.mo` so AI tooling has immediate access to the canonical examples.
