# mo:core Set module

Reference for `mo:core/Set`, mirroring the official doc comments and examples for imperative (mutable) sets.

## Import

```motoko name=import
import Set "mo:core/Set";

```

## Overview

````motoko
/// Imperative (mutable) sets based on order/comparison of elements.
/// A set is a collection of elements without duplicates.
/// The set data structure type is stable and can be used for orthogonal persistence.
///
/// Example:
/// ```motoko
/// import Set "mo:core/Set";
/// import Nat "mo:core/Nat";
///
/// persistent actor {
///   let set = Set.fromIter([3, 1, 2, 3].vals(), Nat.compare);
///   assert Set.size(set) == 3;
///   assert not Set.contains(set, Nat.compare, 4);
///   let diff = Set.difference(set, set, Nat.compare);
///   assert Set.isEmpty(diff);
/// }
/// ```
///
/// These sets are implemented as B-trees with order 32, a balanced search tree of ordered elements.
///
/// Performance:
/// * Runtime: `O(log(n))` worst case cost per insertion, removal, and retrieval operation.
/// * Space: `O(n)` for storing the entire tree,
/// where `n` denotes the number of elements stored in the set.

````

## Type

```motoko
public type Set<T> = Types.Set.Set<T>

```

## Creating sets

````motoko
/// Create a new empty mutable set.
///
/// Example:
/// ```motoko include=import
/// import Nat "mo:core/Nat";
///
/// let set = Set.empty<Nat>();
/// assert Set.size(set) == 0;
/// ```
///
/// Runtime: `O(1)`.
/// Space: `O(1)`.
public func empty<T>() : Set<T>

/// Create a new mutable set with a single element.
///
/// Example:
/// ```motoko include=import
/// let cities = Set.singleton<Text>("Zurich");
/// assert Set.size(cities) == 1;
/// ```
///
/// Runtime: `O(1)`.
/// Space: `O(1)`.
public func singleton<T>(element : T) : Set<T>

/// Create a mutable set from an array, ignoring duplicate elements.
///
/// Runtime: `O(n * log(n))`.
/// Space: `O(n)`.
public func fromArray<T>(array : [T], compare : (implicit : (T, T) -> Order.Order)) : Set<T>

/// Create a mutable set from an iterator, ignoring duplicate elements.
///
/// Runtime: `O(n * log(n))`.
/// Space: `O(n)`.
public func fromIter<T>(iter : Types.Iter<T>, compare : (implicit : (T, T) -> Order.Order)) : Set<T>

/// Convert an iterator directly to a set (same as `fromIter`).
///
/// Runtime: `O(n * log(n))`.
/// Space: `O(n)`.
public func toSet<T>(self : Types.Iter<T>, compare : (implicit : (T, T) -> Order.Order)) : Set<T>

/// Create a copy of the mutable set.
///
/// Example:
/// ```motoko include=import
/// import Nat "mo:core/Nat";
///
/// let originalSet = Set.fromIter([1, 2, 3].values(), Nat.compare);
/// let clonedSet = Set.clone(originalSet);
/// Set.add(originalSet, Nat.compare, 4);
/// assert Set.size(clonedSet) == 3;
/// assert Set.size(originalSet) == 4;
/// ```
///
/// Runtime: `O(n)`.
/// Space: `O(n)`.
/// where `n` denotes the number of elements stored in the set.
public func clone<T>(self : Set<T>) : Set<T>

/// Remove all the elements from the set.
///
/// Example:
/// ```motoko include=import
/// import Text "mo:core/Text";
///
/// let cities = Set.empty<Text>();
/// Set.add(cities, Text.compare, "Zurich");
/// Set.add(cities, Text.compare, "San Francisco");
/// Set.add(cities, Text.compare, "London");
/// assert Set.size(cities) == 3;
///
/// Set.clear(cities);
/// assert Set.size(cities) == 0;
/// ```
///
/// Runtime: `O(1)`.
/// Space: `O(1)`.
public func clear<T>(self : Set<T>);

````

## Querying sets

````motoko
/// Determines whether a set is empty.
///
/// Example:
/// ```motoko include=import
/// import Nat "mo:core/Nat";
///
/// let set = Set.empty<Nat>();
/// Set.add(set, Nat.compare, 1);
/// Set.add(set, Nat.compare, 2);
/// Set.add(set, Nat.compare, 3);
///
/// assert not Set.isEmpty(set);
/// Set.clear(set);
/// assert Set.isEmpty(set);
/// ```
///
/// Runtime: `O(1)`.
/// Space: `O(1)`.
public func isEmpty<T>(self : Set<T>) : Bool

/// Return the number of elements in a set.
///
/// Example:
/// ```motoko include=import
/// import Nat "mo:core/Nat";
///
/// let set = Set.empty<Nat>();
/// Set.add(set, Nat.compare, 1);
/// Set.add(set, Nat.compare, 2);
/// Set.add(set, Nat.compare, 3);
///
/// assert Set.size(set) == 3;
/// ```
///
/// Runtime: `O(1)`.
/// Space: `O(1)`.
public func size<T>(self : Set<T>) : Nat

/// Tests whether the set contains the provided element.
///
/// Example:
/// ```motoko include=import
/// import Nat "mo:core/Nat";
///
/// let set = Set.empty<Nat>();
/// Set.add(set, Nat.compare, 1);
/// Set.add(set, Nat.compare, 2);
/// Set.add(set, Nat.compare, 3);
///
/// assert Set.contains(set, Nat.compare, 1);
/// assert not Set.contains(set, Nat.compare, 4);
/// ```
///
/// Runtime: `O(log(n))`.
/// Space: `O(1)`.
/// where `n` denotes the number of elements stored in the set and
/// assuming that the `compare` function implements an `O(1)` comparison.
public func contains<T>(self : Set<T>, compare : (implicit : (T, T) -> Order.Order), element : T) : Bool;

````

## Modifying sets

````motoko
/// Add a new element to a set.
/// No effect if the element already exists in the set.
///
/// Example:
/// ```motoko include=import
/// import Nat "mo:core/Nat";
/// import Iter "mo:core/Iter";
///
/// let set = Set.empty<Nat>();
/// Set.add(set, Nat.compare, 2);
/// Set.add(set, Nat.compare, 1);
/// Set.add(set, Nat.compare, 2);
/// assert Iter.toArray(Set.values(set)) == [1, 2];
/// ```
///
/// Runtime: `O(log(n))`.
/// Space: `O(log(n))`.
/// where `n` denotes the number of elements stored in the set and
/// assuming that the `compare` function implements an `O(1)` comparison.
public func add<T>(self : Set<T>, compare : (implicit : (T, T) -> Order.Order), element : T)

/// Insert a new element in the set.
/// Returns true if the element is new, false if the element was already contained in the set.
///
/// Example:
/// ```motoko include=import
/// import Nat "mo:core/Nat";
/// import Iter "mo:core/Iter";
///
/// let set = Set.empty<Nat>();
/// assert Set.insert(set, Nat.compare, 2);
/// assert Set.insert(set, Nat.compare, 1);
/// assert not Set.insert(set, Nat.compare, 2);
/// assert Iter.toArray(Set.values(set)) == [1, 2];
/// ```
///
/// Runtime: `O(log(n))`.
/// Space: `O(log(n))`.
/// where `n` denotes the number of elements stored in the set and
/// assuming that the `compare` function implements an `O(1)` comparison.
/// @deprecated M0235
public func insert<T>(self : Set<T>, compare : (implicit : (T, T) -> Order.Order), element : T) : Bool

/// Remove an element from the set (no-op if absent).
///
/// Runtime: `O(log(n))`.
/// Space: `O(log(n))`.
public func remove<T>(self : Set<T>, compare : (implicit : (T, T) -> Order.Order), element : T) : ()

/// Remove an element and return `true` if it was present.
///
/// Runtime: `O(log(n))`.
/// Space: `O(log(n))`.
/// @deprecated M0235
public func delete<T>(self : Set<T>, compare : (implicit : (T, T) -> Order.Order), element : T) : Bool;

````

## Accessing set extremes

```motoko
/// Return the maximum element (by order) or `null` if the set is empty.
///
/// Runtime: `O(log(n))`.
/// Space: `O(1)`.
public func max<T>(self : Set<T>) : ?T

/// Return the minimum element (by order) or `null` if the set is empty.
///
/// Runtime: `O(log(n))`.
/// Space: `O(1)`.
public func min<T>(self : Set<T>) : ?T;

```

## Converting to arrays

```motoko
/// Return all elements in ascending order as an array.
///
/// Runtime: `O(n)`.
/// Space: `O(n)`.
public func toArray<T>(self : Set<T>) : [T];

```

## Iteration

```motoko
/// Iterator over elements in ascending order.
///
/// Runtime: `O(log(n))` to create the iterator.
/// Space: `O(log(n))` retained memory.
public func values<T>(self : Set<T>) : Types.Iter<T>

/// Iterator over elements in ascending order starting from `element`.
///
/// Runtime: `O(log(n))` to create the iterator.
/// Space: `O(log(n))` retained memory.
public func valuesFrom<T>(
  self : Set<T>,
  compare : (implicit : (T, T) -> Order.Order),
  element : T,
) : Types.Iter<T>

/// Iterator over elements in descending order.
///
/// Runtime: `O(log(n))` to create the iterator.
/// Space: `O(log(n))` retained memory.
public func reverseValues<T>(self : Set<T>) : Types.Iter<T>

/// Iterator over elements in descending order starting from `element`.
///
/// Runtime: `O(log(n))` to create the iterator.
/// Space: `O(log(n))` retained memory.
public func reverseValuesFrom<T>(
  self : Set<T>,
  compare : (implicit : (T, T) -> Order.Order),
  element : T,
) : Types.Iter<T>

/// Apply an operation to each element in ascending order.
///
/// Runtime: `O(n)`.
/// Space: `O(log(n))` retained memory.
public func forEach<T>(self : Set<T>, operation : T -> ());

```

## Set operations

````motoko
/// Return `true` if `self` is a subset of `other`.
///
/// Example:
/// ```motoko include=import
/// import Nat "mo:core/Nat";
///
/// let set1 = Set.fromIter([1, 2].values(), Nat.compare);
/// let set2 = Set.fromIter([1, 2, 3].values(), Nat.compare);
/// assert Set.isSubset(set1, set2, Nat.compare);
/// assert not Set.isSubset(set2, set1, Nat.compare);
/// ```
///
/// Runtime: `O(m * log(n))`.
/// Space: `O(1)`.
/// where `m` is the size of `self` and `n` is the size of `other`.
public func isSubset<T>(self : Set<T>, other : Set<T>, compare : (implicit : (T, T) -> Order.Order)) : Bool

/// Return a new set that is the union of `self` and `other`.
///
/// Example:
/// ```motoko include=import
/// import Nat "mo:core/Nat";
/// import Iter "mo:core/Iter";
///
/// let set1 = Set.fromIter([1, 2].values(), Nat.compare);
/// let set2 = Set.fromIter([2, 3].values(), Nat.compare);
/// let unionSet = Set.union(set1, set2, Nat.compare);
/// assert Iter.toArray(Set.values(unionSet)) == [1, 2, 3];
/// ```
///
/// Runtime: `O((m + n) * log(m + n))`.
/// Space: `O(m + n)`.
public func union<T>(self : Set<T>, other : Set<T>, compare : (implicit : (T, T) -> Order.Order)) : Set<T>

/// Return a new set that is the intersection of `self` and `other`.
///
/// Example:
/// ```motoko include=import
/// import Nat "mo:core/Nat";
/// import Iter "mo:core/Iter";
///
/// let set1 = Set.fromIter([1, 2, 3].values(), Nat.compare);
/// let set2 = Set.fromIter([2, 3, 4].values(), Nat.compare);
/// let intersectSet = Set.intersection(set1, set2, Nat.compare);
/// assert Iter.toArray(Set.values(intersectSet)) == [2, 3];
/// ```
///
/// Runtime: `O(m * log(n))`.
/// Space: `O(min(m, n))`.
public func intersection<T>(self : Set<T>, other : Set<T>, compare : (implicit : (T, T) -> Order.Order)) : Set<T>

/// Return a new set that is the difference `self` minus `other`.
///
/// Example:
/// ```motoko include=import
/// import Nat "mo:core/Nat";
/// import Iter "mo:core/Iter";
///
/// let set1 = Set.fromIter([1, 2, 3].values(), Nat.compare);
/// let set2 = Set.fromIter([2, 3, 4].values(), Nat.compare);
/// let diffSet = Set.difference(set1, set2, Nat.compare);
/// assert Iter.toArray(Set.values(diffSet)) == [1];
/// ```
///
/// Runtime: `O(m * log(n))`.
/// Space: `O(m)`.
public func difference<T>(self : Set<T>, other : Set<T>, compare : (implicit : (T, T) -> Order.Order)) : Set<T>;

````

## Bulk updates

```motoko
/// Add all elements from `iter` to `self` (in-place union).
///
/// Runtime: `O(k * log(n))`.
/// Space: `O(k * log(n))`.
/// where `k` is the number of elements in the iterator.
public func addAll<T>(self : Set<T>, compare : (implicit : (T, T) -> Order.Order), iter : Types.Iter<T>)

/// Delete all values in `iter` from `self`, returning `true` if size changed.
///
/// Runtime: `O(k * log(n))`.
/// Space: `O(k * log(n))`.
/// @deprecated M0235
public func deleteAll<T>(self : Set<T>, compare : (implicit : (T, T) -> Order.Order), iter : Types.Iter<T>) : Bool

/// Insert all values in `iter` into `self`, returning `true` if size changed.
///
/// Runtime: `O(k * log(n))`.
/// Space: `O(k * log(n))`.
/// @deprecated M0235
public func insertAll<T>(self : Set<T>, compare : (implicit : (T, T) -> Order.Order), iter : Types.Iter<T>) : Bool

/// Retain only elements satisfying `predicate` (in-place filter). Returns `true` if size changed.
///
/// Runtime: `O(n)`.
/// Space: `O(log(n))`.
public func retainAll<T>(self : Set<T>, compare : (implicit : (T, T) -> Order.Order), predicate : T -> Bool) : Bool;

```

## Higher-order operations

````motoko
/// Return a new set containing only elements for which `criterion` returns `true`.
///
/// Example:
/// ```motoko include=import
/// import Nat "mo:core/Nat";
/// import Iter "mo:core/Iter";
///
/// let set = Set.fromIter([1, 2, 3, 4, 5].values(), Nat.compare);
/// let evens = Set.filter(set, Nat.compare, func(x) { x % 2 == 0 });
/// assert Iter.toArray(Set.values(evens)) == [2, 4];
/// ```
///
/// Runtime: `O(n)`.
/// Space: `O(n)`.
public func filter<T>(self : Set<T>, compare : (implicit : (T, T) -> Order.Order), criterion : T -> Bool) : Set<T>

/// Map elements into a new set of type `T2` using `project`.
///
/// Example:
/// ```motoko include=import
/// import Nat "mo:core/Nat";
/// import Iter "mo:core/Iter";
///
/// let set = Set.fromIter([1, 2, 3].values(), Nat.compare);
/// let doubled = Set.map(set, Nat.compare, func(x : Nat) : Nat { x * 2 });
/// assert Iter.toArray(Set.values(doubled)) == [2, 4, 6];
/// ```
///
/// Runtime: `O(n * log(n))`.
/// Space: `O(n)`.
public func map<T1, T2>(self : Set<T1>, compare : (implicit : (T2, T2) -> Order.Order), project : T1 -> T2) : Set<T2>

/// Map and filter in one pass: keep only `?value` results.
///
/// Runtime: `O(n * log(n))`.
/// Space: `O(n)`.
public func filterMap<T1, T2>(self : Set<T1>, compare : (implicit : (T2, T2) -> Order.Order), project : T1 -> ?T2) : Set<T2>

/// Fold from left (ascending order) over all elements.
///
/// Example:
/// ```motoko include=import
/// import Nat "mo:core/Nat";
///
/// let set = Set.fromIter([1, 2, 3].values(), Nat.compare);
/// let sum = Set.foldLeft(set, 0, func(acc, x) { acc + x });
/// assert sum == 6;
/// ```
///
/// Runtime: `O(n)`.
/// Space: `O(log(n))`.
public func foldLeft<T, A>(
  self : Set<T>,
  base : A,
  combine : (A, T) -> A,
) : A

/// Fold from right (descending order) over all elements.
///
/// Runtime: `O(n)`.
/// Space: `O(log(n))`.
public func foldRight<T, A>(
  self : Set<T>,
  base : A,
  combine : (T, A) -> A,
) : A

/// Construct the union of all sets produced by an iterator of sets.
///
/// Runtime: `O(n * log(n))` where `n` is the total number of elements across all sets.
/// Space: `O(n)`.
public func join<T>(setIterator : Types.Iter<Set<T>>, compare : (implicit : (T, T) -> Order.Order)) : Set<T>

/// Flatten a set of sets into the union of all element sets.
///
/// Runtime: `O(n * log(n))` where `n` is the total number of elements across all sets.
/// Space: `O(n)`.
public func flatten<T>(self : Set<Set<T>>, compare : (implicit : (T, T) -> Order.Order)) : Set<T>

/// Return `true` if all elements satisfy `predicate`.
///
/// Example:
/// ```motoko include=import
/// import Nat "mo:core/Nat";
///
/// let set = Set.fromIter([2, 4, 6].values(), Nat.compare);
/// assert Set.all(set, func(x) { x % 2 == 0 });
/// ```
///
/// Runtime: `O(n)` worst case.
/// Space: `O(log(n))`.
public func all<T>(self : Set<T>, predicate : T -> Bool) : Bool

/// Return `true` if any element satisfies `predicate`.
///
/// Example:
/// ```motoko include=import
/// import Nat "mo:core/Nat";
///
/// let set = Set.fromIter([1, 2, 3].values(), Nat.compare);
/// assert Set.any(set, func(x) { x % 2 == 0 });
/// ```
///
/// Runtime: `O(n)` worst case.
/// Space: `O(log(n))`.
public func any<T>(self : Set<T>, predicate : T -> Bool) : Bool;

````

## Comparisons and conversions

````motoko
/// Test whether two imperative sets are equal.
/// Both sets have to be constructed by the same comparison function.
///
/// Example:
/// ```motoko include=import
/// import Nat "mo:core/Nat";
///
/// let set1 = Set.fromIter([1, 2].values(), Nat.compare);
/// let set2 = Set.fromIter([2, 1].values(), Nat.compare);
/// let set3 = Set.fromIter([2, 1, 0].values(), Nat.compare);
/// assert Set.equal(set1, set2, Nat.compare);
/// assert not Set.equal(set1, set3, Nat.compare);
/// ```
///
/// Runtime: `O(n)`.
/// Space: `O(1)`.
public func equal<T>(self : Set<T>, other : Set<T>, compare : (implicit : (T, T) -> Types.Order)) : Bool

/// Lexicographically compare two sets by their ordered elements.
///
/// Runtime: `O(n)` worst case.
/// Space: `O(1)`.
public func compare<T>(self : Set<T>, other : Set<T>, compare : (implicit : (T, T) -> Order.Order)) : Order.Order

/// Generate a textual representation of the set for debugging.
///
/// Runtime: `O(n)`.
/// Space: `O(n)`.
public func toText<T>(self : Set<T>, toText : (implicit : T -> Text)) : Text

/// Convert the mutable set to an immutable, purely functional set.
///
/// Example:
/// ```motoko include=import
/// import PureSet "mo:core/pure/Set";
/// import Nat "mo:core/Nat";
/// import Iter "mo:core/Iter";
///
/// let set = Set.fromIter<Nat>([0, 2, 1].values(), Nat.compare);
/// let pureSet = Set.toPure(set, Nat.compare);
/// assert Iter.toArray(PureSet.values(pureSet)) == Iter.toArray(Set.values(set));
/// ```
///
/// Runtime: `O(n * log(n))`.
/// Space: `O(n)` retained memory plus garbage, see the note below.
/// where `n` denotes the number of elements stored in the set and
/// assuming that the `compare` function implements an `O(1)` comparison.
///
/// Note: Creates `O(n * log(n))` temporary objects that will be collected as garbage.
/// @deprecated M0235
public func toPure<T>(self : Set<T>, compare : (implicit : (T, T) -> Order.Order)) : PureSet.Set<T>

/// Convert an immutable, purely functional set to a mutable set.
///
/// Example:
/// ```motoko include=import
/// import PureSet "mo:core/pure/Set";
/// import Nat "mo:core/Nat";
/// import Iter "mo:core/Iter";
///
/// let pureSet = PureSet.fromIter([3, 1, 2].values(), Nat.compare);
/// let set = Set.fromPure(pureSet, Nat.compare);
/// assert Iter.toArray(Set.values(set)) == Iter.toArray(PureSet.values(pureSet));
/// ```
///
/// Runtime: `O(n * log(n))`.
/// Space: `O(n)`.
/// where `n` denotes the number of elements stored in the set and
/// assuming that the `compare` function implements an `O(1)` comparison.
/// @deprecated M0235
public func fromPure<T>(set : PureSet.Set<T>, compare : (implicit : (T, T) -> Order.Order)) : Set<T>

/// Internal sanity check; traps if the internal structure is invalid.
/// @deprecated M0235
public func assertValid<T>(self : Set<T>, compare : (implicit : (T, T) -> Order.Order));

````

---

This file mirrors `src/Set.mo` so AI tooling has immediate access to the canonical examples.
