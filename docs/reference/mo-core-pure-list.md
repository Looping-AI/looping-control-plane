# mo:core/pure List module

Reference for the purely functional list utilities in `mo:core/pure/List`, retaining the official comments/examples.

## Import

```motoko name=import
import List "mo:core/pure/List";

```

## Overview

Lists are immutable singly linked structures (`null` or `?(head, tail)`). Prepend is O(1); random access is linear.

```motoko
/// Purely-functional, singly-linked list data structure.
/// This module provides immutable lists with efficient prepend and traversal operations.

```

## Construction and inspection

````motoko
/// Create an empty list.
///
/// Example:
/// ```motoko
/// import List "mo:core/pure/List";
///
/// persistent actor {
///   assert List.empty<Nat>() == null;
/// }
/// ```
public func empty<T>() : List<T>

/// Check whether a list is empty and return true if the list is empty.
///
/// Example:
/// ```motoko
/// import List "mo:core/pure/List";
///
/// persistent actor {
///   assert List.isEmpty(null);
///   assert not List.isEmpty(?(1, null));
/// }
/// ```
public func isEmpty<T>(self : List<T>) : Bool

/// Return the length of the list.
///
/// Example:
/// ```motoko
/// import List "mo:core/pure/List";
///
/// persistent actor {
///   let list = ?(0, ?(1, null));
///   assert List.size(list) == 2;
/// }
/// ```
public func size<T>(self : List<T>) : Nat

/// Access any item in a list, zero-based.
///
/// Example:
/// ```motoko
/// import List "mo:core/pure/List";
///
/// persistent actor {
///   let list = ?(0, ?(1, null));
///   assert List.get(list, 1) == ?1;
/// }
/// ```
public func get<T>(self : List<T>, n : Nat) : ?T

/// Add `item` to the head of `list`, and return the new list.
///
/// Example:
/// ```motoko
/// import List "mo:core/pure/List";
///
/// persistent actor {
///   assert List.pushFront(null, 0) == ?(0, null);
/// }
/// ```
public func pushFront<T>(self : List<T>, item : T) : List<T>

/// Return the last element of the list, if present.
///
/// Example:
/// ```motoko
/// import List "mo:core/pure/List";
///
/// persistent actor {
///   let list = ?(0, ?(1, null));
///   assert List.last(list) == ?1;
/// }
/// ```
public func last<T>(self : List<T>) : ?T

/// Remove the head of the list, returning the optioned head and the tail of the list in a pair.
///
/// Example:
/// ```motoko
/// import List "mo:core/pure/List";
///
/// persistent actor {
///   let list = ?(0, ?(1, null));
///   assert List.popFront(list) == (?0, ?(1, null));
/// }
/// ```
public func popFront<T>(self : List<T>) : (?T, List<T>);

````

## Traversal

````motoko
/// Reverses the list.
///
/// Example:
/// ```motoko
/// import List "mo:core/pure/List";
///
/// persistent actor {
///   let list = ?(0, ?(1, ?(2, null)));
///   assert List.reverse(list) == ?(2, ?(1, ?(0, null)));
/// }
/// ```
public func reverse<T>(self : List<T>) : List<T>

/// Call the given function for its side effect, with each list element in turn.
///
/// Example:
/// ```motoko
/// import List "mo:core/pure/List";
///
/// persistent actor {
///   let list = ?(0, ?(1, ?(2, null)));
///   var sum = 0;
///   List.forEach<Nat>(list, func n = sum += n);
///   assert sum == 3;
/// }
/// ```
public func forEach<T>(self : List<T>, f : T -> ());

````

## Mapping and filtering

````motoko
/// Call the given function `f` on each list element and collect the results
/// in a new list.
///
/// Example:
/// ```motoko
/// import List "mo:core/pure/List";
/// import Nat "mo:core/Nat";
///
/// persistent actor {
///   let list = ?(0, ?(1, ?(2, null)));
///   assert List.map(list, Nat.toText) == ?("0", ?("1", ?("2", null)));
/// }
/// ```
public func map<T1, T2>(self : List<T1>, f : T1 -> T2) : List<T2>

/// Create a new list with only those elements of the original list for which
/// the given function returns true.
///
/// Example:
/// ```motoko
/// import List "mo:core/pure/List";
///
/// persistent actor {
///   let list = ?(0, ?(1, ?(2, null)));
///   assert List.filter<Nat>(list, func n = n != 1) == ?(0, ?(2, null));
/// }
/// ```
public func filter<T>(self : List<T>, f : T -> Bool) : List<T>

/// Call the given function on each list element, and collect the non-null results
/// in a new list.
///
/// Example:
/// ```motoko
/// import List "mo:core/pure/List";
///
/// persistent actor {
///   let list = ?(1, ?(2, ?(3, null)));
///   assert List.filterMap<Nat, Nat>(
///     list,
///     func n = if (n > 1) ?(n * 2) else null
///   ) == ?(4, ?(6, null));
/// }
/// ```
public func filterMap<T, R>(self : List<T>, f : T -> ?R) : List<R>

/// Maps a `Result`-returning function `f` over a `List` and returns either
/// the first error or a list of successful values.
///
/// Example:
/// ```motoko
/// import List "mo:core/pure/List";
///
/// persistent actor {
///   let list = ?(1, ?(2, ?(3, null)));
///   assert List.mapResult<Nat, Nat, Text>(
///     list,
///     func n = if (n > 0) #ok(n * 2) else #err "Some element is zero"
///   ) == #ok(?(2, ?(4, ?(6, null))));
/// }
/// ```
public func mapResult<T, R, E>(self : List<T>, f : T -> Result.Result<R, E>) : Result.Result<List<R>, E>

/// Create two new lists from the results of a given function (`f`).
///
/// Example:
/// ```motoko
/// import List "mo:core/pure/List";
///
/// persistent actor {
///   let list = ?(0, ?(1, ?(2, null)));
///   assert List.partition<Nat>(list, func n = n != 1) == (?(0, ?(2, null)), ?(1, null));
/// }
/// ```
public func partition<T>(self : List<T>, f : T -> Bool) : (List<T>, List<T>);

````

## Combining lists

````motoko
/// Append the elements from one list to another list.
///
/// Example:
/// ```motoko
/// import List "mo:core/pure/List";
///
/// persistent actor {
///   let list1 = ?(0, ?(1, ?(2, null)));
///   let list2 = ?(3, ?(4, ?(5, null)));
///   assert List.concat(list1, list2) == ?(0, ?(1, ?(2, ?(3, ?(4, ?(5, null))))));
/// }
/// ```
public func concat<T>(self : List<T>, other : List<T>) : List<T>

/// Flatten, or repeatedly concatenate, an iterator of lists as a list.
///
/// Example:
/// ```motoko
/// import List "mo:core/pure/List";
/// import Iter "mo:core/Iter";
///
/// persistent actor {
///   let lists = [ ?(0, ?(1, ?(2, null))),
///                 ?(3, ?(4, ?(5, null))) ];
///   assert List.join(lists |> Iter.fromArray(_)) == ?(0, ?(1, ?(2, ?(3, ?(4, ?(5, null))))));
/// }
/// ```
public func join<T>(iter : Iter.Iter<List<T>>) : List<T>

/// Flatten, or repeatedly concatenate, a list of lists as a list.
///
/// Example:
/// ```motoko
/// import List "mo:core/pure/List";
///
/// persistent actor {
///   let lists = ?(?(0, ?(1, ?(2, null))),
///                ?(?(3, ?(4, ?(5, null))),
///                  null));
///   assert List.flatten(lists) == ?(0, ?(1, ?(2, ?(3, ?(4, ?(5, null))))));
/// }
/// ```
public func flatten<T>(self : List<List<T>>) : List<T>;

````

## Slicing

````motoko
/// Returns the first `n` elements of the given list.
///
/// Example:
/// ```motoko
/// import List "mo:core/pure/List";
///
/// persistent actor {
///   let list = ?(0, ?(1, ?(2, null)));
///   assert List.take(list, 2) == ?(0, ?(1, null));
/// }
/// ```
public func take<T>(self : List<T>, n : Nat) : List<T>

/// Drop the first `n` elements from the given list.
///
/// Example:
/// ```motoko
/// import List "mo:core/pure/List";
///
/// persistent actor {
///   let list = ?(0, ?(1, ?(2, null)));
///   assert List.drop(list, 2) == ?(2, null);
/// }
/// ```
public func drop<T>(self : List<T>, n : Nat) : List<T>;

````

## Folding and search

````motoko
/// Collapses the elements in `list` into a single value by starting with `base`
/// and progressively combining elements into `base` with `combine`. Iteration runs
/// left to right.
///
/// Example:
/// ```motoko
/// import List "mo:core/pure/List";
/// import Nat "mo:core/Nat";
///
/// persistent actor {
///   let list = ?(1, ?(2, ?(3, null)));
///   assert List.foldLeft<Nat, Text>(
///     list,
///     "",
///     func (acc, x) = acc # Nat.toText(x)
///   ) == "123";
/// }
/// ```
public func foldLeft<T, A>(self : List<T>, base : A, combine : (A, T) -> A) : A

/// Collapses the elements in `buffer` into a single value by starting with `base`
/// and progressively combining elements into `base` with `combine`. Iteration runs
/// right to left.
///
/// Example:
/// ```motoko
/// import List "mo:core/pure/List";
/// import Nat "mo:core/Nat";
///
/// persistent actor {
///   let list = ?(1, ?(2, ?(3, null)));
///   assert List.foldRight<Nat, Text>(
///     list,
///     "",
///     func (x, acc) = Nat.toText(x) # acc
///   ) == "123";
/// }
/// ```
public func foldRight<T, A>(self : List<T>, base : A, combine : (T, A) -> A) : A

/// Return the first element for which the given predicate `f` is true,
/// if such an element exists.
///
/// Example:
/// ```motoko
/// import List "mo:core/pure/List";
///
/// persistent actor {
///   let list = ?(1, ?(2, ?(3, null)));
///   assert List.find<Nat>(list, func n = n > 1) == ?2;
/// }
/// ```
public func find<T>(self : List<T>, f : T -> Bool) : ?T;

````

(Refer to `src/pure/List.mo` for the remaining helpers like `findIndex`, `contains`, and iterator conversions—add them here as needed following the same pattern.)

---

Examples remain identical to upstream docs, keeping AI assistants aligned with the official reference.
