# mo:core Map module

Reference for `mo:core/Map`, mirroring the official doc comments and examples for imperative (mutable) key-value maps.

## Import

```motoko name=import
import Map "mo:core/Map";

```

## Overview

````motoko
/// An imperative key-value map based on order/comparison of the keys.
/// The map data structure type is stable and can be used for orthogonal persistence.
///
/// Example:
/// ```motoko
/// import Map "mo:core/Map";
/// import Nat "mo:core/Nat";
///
/// persistent actor {
///   // creation
///   let map = Map.empty<Nat, Text>();
///   // insertion
///   Map.add(map, Nat.compare, 0, "Zero");
///   // retrieval
///   assert Map.get(map, Nat.compare, 0) == ?"Zero";
///   assert Map.get(map, Nat.compare, 1) == null;
///   // removal
///   Map.remove(map, Nat.compare, 0);
///   assert Map.isEmpty(map);
/// }
/// ```
///
/// The internal implementation is a B-tree with order 32.
///
/// Performance:
/// * Runtime: `O(log(n))` worst case cost per insertion, removal, and retrieval operation.
/// * Space: `O(n)` for storing the entire map.
/// `n` denotes the number of key-value entries stored in the map.

````

## Type

```motoko
public type Map<K, V> = Types.Map<K, V>

```

## Creating maps

````motoko
/// Create a new empty mutable key-value map.
///
/// Example:
/// ```motoko include=import
/// let map = Map.empty<Nat, Text>();
/// assert Map.size(map) == 0;
/// ```
///
/// Runtime: `O(1)`.
/// Space: `O(1)`.
public func empty<K, V>() : Map<K, V>

/// Create a new mutable key-value map with a single entry.
///
/// Example:
/// ```motoko include=import
/// import Iter "mo:core/Iter";
///
/// let map = Map.singleton<Nat, Text>(0, "Zero");
/// assert Iter.toArray(Map.entries(map)) == [(0, "Zero")];
/// ```
///
/// Runtime: `O(1)`.
/// Space: `O(1)`.
public func singleton<K, V>(key : K, value : V) : Map<K, V>

/// Build a map from an iterator of `(key, value)` pairs.
///
/// Runtime: `O(n * log(n))`.
/// Space: `O(n)`.
public func fromIter<K, V>(iter : Types.Iter<(K, V)>, compare : (implicit : (K, K) -> Order.Order)) : Map<K, V>

/// Convert an iterator of entries directly to a map (same as `fromIter`).
///
/// Runtime: `O(n * log(n))`.
/// Space: `O(n)`.
public func toMap<K, V>(self : Types.Iter<(K, V)>, compare : (implicit : (K, K) -> Order.Order)) : Map<K, V>

/// Build a map from an immutable array of entries.
///
/// Runtime: `O(n * log(n))`.
/// Space: `O(n)`.
public func fromArray<K, V>(array : [(K, V)], compare : (implicit : (K, K) -> Order.Order)) : Map<K, V>

/// Build a map from a mutable array of entries.
///
/// Runtime: `O(n * log(n))`.
/// Space: `O(n)`.
public func fromVarArray<K, V>(array : [var (K, V)], compare : (implicit : (K, K) -> Order.Order)) : Map<K, V>

/// Create a copy of the mutable key-value map.
///
/// Example:
/// ```motoko include=import
/// import Nat "mo:core/Nat";
///
/// let originalMap = Map.fromIter<Nat, Text>(
///   [(1, "One"), (2, "Two"), (3, "Three")].values(), Nat.compare);
/// let clonedMap = Map.clone(originalMap);
/// Map.add(originalMap, Nat.compare, 4, "Four");
/// assert Map.size(clonedMap) == 3;
/// assert Map.size(originalMap) == 4;
/// ```
///
/// Runtime: `O(n)`.
/// Space: `O(n)`.
/// where `n` denotes the number of key-value entries stored in the map.
public func clone<K, V>(self : Map<K, V>) : Map<K, V>

/// Delete all the entries in the key-value map.
///
/// Example:
/// ```motoko include=import
/// import Nat "mo:core/Nat";
///
/// let map = Map.fromIter<Nat, Text>(
///   [(0, "Zero"), (1, "One"), (2, "Two")].values(),
///   Nat.compare);
///
/// assert Map.size(map) == 3;
///
/// Map.clear(map);
/// assert Map.size(map) == 0;
/// ```
///
/// Runtime: `O(1)`.
/// Space: `O(1)`.
public func clear<K, V>(self : Map<K, V>);

````

## Querying maps

````motoko
/// Determines whether a key-value map is empty.
///
/// Example:
/// ```motoko include=import
/// import Nat "mo:core/Nat";
///
/// let map = Map.fromIter<Nat, Text>(
///   [(0, "Zero"), (1, "One"), (2, "Two")].values(),
///   Nat.compare);
///
/// assert not Map.isEmpty(map);
/// Map.clear(map);
/// assert Map.isEmpty(map);
/// ```
///
/// Runtime: `O(1)`.
/// Space: `O(1)`.
public func isEmpty<K, V>(self : Map<K, V>) : Bool

/// Return the number of entries in a key-value map.
///
/// Example:
/// ```motoko include=import
/// import Nat "mo:core/Nat";
///
/// let map = Map.fromIter<Nat, Text>(
///   [(0, "Zero"), (1, "One"), (2, "Two")].values(),
///   Nat.compare);
///
/// assert Map.size(map) == 3;
/// Map.clear(map);
/// assert Map.size(map) == 0;
/// ```
///
/// Runtime: `O(1)`.
/// Space: `O(1)`.
public func size<K, V>(self : Map<K, V>) : Nat

/// Tests whether the map contains the provided key.
///
/// Example:
/// ```motoko include=import
/// import Nat "mo:core/Nat";
///
/// let map = Map.fromIter<Nat, Text>(
///   [(0, "Zero"), (1, "One"), (2, "Two")].values(),
///   Nat.compare);
///
/// assert Map.containsKey(map, Nat.compare, 1);
/// assert not Map.containsKey(map, Nat.compare, 3);
/// ```
///
/// Runtime: `O(log(n))`.
/// Space: `O(1)`.
/// where `n` denotes the number of key-value entries stored in the map and
/// assuming that the `compare` function implements an `O(1)` comparison.
public func containsKey<K, V>(self : Map<K, V>, compare : (implicit : (K, K) -> Order.Order), key : K) : Bool

/// Get the value associated with key in the given map if present and `null` otherwise.
///
/// Example:
/// ```motoko include=import
/// import Nat "mo:core/Nat";
///
/// let map = Map.fromIter<Nat, Text>(
///   [(0, "Zero"), (1, "One"), (2, "Two")].values(),
///   Nat.compare);
///
/// assert Map.get(map, Nat.compare, 1) == ?"One";
/// assert Map.get(map, Nat.compare, 3) == null;
/// ```
///
/// Runtime: `O(log(n))`.
/// Space: `O(1)`.
/// where `n` denotes the number of key-value entries stored in the map and
/// assuming that the `compare` function implements an `O(1)` comparison.
public func get<K, V>(self : Map<K, V>, compare : (implicit : (K, K) -> Order.Order), key : K) : ?V;

````

## Modifying maps

````motoko
/// Given `map` ordered by `compare`, add a mapping from `key` to `value` to `map`.
/// Replaces any existing entry for `key`.
///
/// Example:
/// ```motoko include=import
/// import Nat "mo:core/Nat";
/// import Iter "mo:core/Iter";
///
/// let map = Map.empty<Nat, Text>();
/// Map.add(map, Nat.compare, 0, "Zero");
/// Map.add(map, Nat.compare, 1, "One");
/// assert Iter.toArray(Map.entries(map)) == [(0, "Zero"), (1, "One")];
/// Map.add(map, Nat.compare, 0, "Nil");
/// assert Iter.toArray(Map.entries(map)) == [(0, "Nil"), (1, "One")];
/// ```
///
/// Runtime: `O(log(n))`.
/// Space: `O(log(n))`.
public func add<K, V>(self : Map<K, V>, compare : (implicit : (K, K) -> Order.Order), key : K, value : V)

/// Given `map` ordered by `compare`, insert a new mapping from `key` to `value`.
/// Replaces any existing entry under `key`.
/// Returns true if the key is new to the map, otherwise false.
///
/// Example:
/// ```motoko include=import
/// import Nat "mo:core/Nat";
/// import Iter "mo:core/Iter";
///
/// let map = Map.empty<Nat, Text>();
/// assert Map.insert(map, Nat.compare, 0, "Zero");
/// assert Map.insert(map, Nat.compare, 1, "One");
/// assert Iter.toArray(Map.entries(map)) == [(0, "Zero"), (1, "One")];
/// assert not Map.insert(map, Nat.compare, 0, "Nil");
/// assert Iter.toArray(Map.entries(map)) == [(0, "Nil"), (1, "One")]
/// ```
///
/// Runtime: `O(log(n))`.
/// Space: `O(log(n))`.
/// where `n` denotes the number of key-value entries stored in the map and
/// assuming that the `compare` function implements an `O(1)` comparison.
/// @deprecated M0235
public func insert<K, V>(self : Map<K, V>, compare : (implicit : (K, K) -> Order.Order), key : K, value : V) : Bool

/// Associate `value` with `key`, returning the previous value if any.
///
/// Runtime: `O(log(n))`.
/// Space: `O(log(n))`.
/// @deprecated M0235
public func swap<K, V>(self : Map<K, V>, compare : (implicit : (K, K) -> Order.Order), key : K, value : V) : ?V

/// Replace the value for an existing `key`, returning the previous value or `null`.
///
/// Runtime: `O(log(n))`.
/// Space: `O(log(n))`.
/// @deprecated M0235
public func replace<K, V>(self : Map<K, V>, compare : (implicit : (K, K) -> Order.Order), key : K, value : V) : ?V

/// Remove the entry for `key` if present.
///
/// Example:
/// ```motoko include=import
/// import Nat "mo:core/Nat";
/// import Iter "mo:core/Iter";
///
/// let map = Map.fromIter<Nat, Text>(
///   [(0, "Zero"), (1, "One"), (2, "Two")].values(),
///   Nat.compare);
///
/// Map.remove(map, Nat.compare, 1);
/// assert Iter.toArray(Map.entries(map)) == [(0, "Zero"), (2, "Two")];
/// ```
///
/// Runtime: `O(log(n))`.
/// Space: `O(log(n))`.
public func remove<K, V>(self : Map<K, V>, compare : (implicit : (K, K) -> Order.Order), key : K)

/// Remove the entry for `key`, returning `true` if it existed.
///
/// Runtime: `O(log(n))`.
/// Space: `O(log(n))`.
/// @deprecated M0235
public func delete<K, V>(self : Map<K, V>, compare : (implicit : (K, K) -> Order.Order), key : K) : Bool

/// Remove the entry for `key`, returning the previous value if any.
///
/// Runtime: `O(log(n))`.
/// Space: `O(log(n))`.
/// @deprecated M0235
public func take<K, V>(self : Map<K, V>, compare : (implicit : (K, K) -> Order.Order), key : K) : ?V;

````

## Accessing map extremes

```motoko
/// Return the entry with the maximum key, or `null` if empty.
///
/// Runtime: `O(log(n))`.
/// Space: `O(1)`.
public func maxEntry<K, V>(self : Map<K, V>) : ?(K, V)

/// Return the entry with the minimum key, or `null` if empty.
///
/// Runtime: `O(log(n))`.
/// Space: `O(1)`.
public func minEntry<K, V>(self : Map<K, V>) : ?(K, V);

```

## Converting to arrays

```motoko
/// Convert all entries to an immutable array.
///
/// Runtime: `O(n)`.
/// Space: `O(n)`.
public func toArray<K, V>(self : Map<K, V>) : [(K, V)]

/// Convert all entries to a mutable array.
///
/// Runtime: `O(n)`.
/// Space: `O(n)`.
public func toVarArray<K, V>(self : Map<K, V>) : [var (K, V)];

```

## Iteration

```motoko
/// Iterator over entries `(key, value)` in ascending key order.
///
/// Runtime: `O(log(n))` to create the iterator.
/// Space: `O(log(n))` retained memory.
public func entries<K, V>(self : Map<K, V>) : Types.Iter<(K, V)>

/// Iterator over entries starting from a given `key` (ascending).
///
/// Runtime: `O(log(n))` to create the iterator.
/// Space: `O(log(n))` retained memory.
public func entriesFrom<K, V>(
  self : Map<K, V>,
  compare : (implicit : (K, K) -> Order.Order),
  key : K,
) : Types.Iter<(K, V)>

/// Iterator over entries in descending key order.
///
/// Runtime: `O(log(n))` to create the iterator.
/// Space: `O(log(n))` retained memory.
public func reverseEntries<K, V>(self : Map<K, V>) : Types.Iter<(K, V)>

/// Iterator over entries starting from a given `key` (descending).
///
/// Runtime: `O(log(n))` to create the iterator.
/// Space: `O(log(n))` retained memory.
public func reverseEntriesFrom<K, V>(
  self : Map<K, V>,
  compare : (implicit : (K, K) -> Order.Order),
  key : K,
) : Types.Iter<(K, V)>

/// Iterator over keys in ascending order.
///
/// Runtime: `O(log(n))` to create the iterator.
/// Space: `O(log(n))` retained memory.
public func keys<K, V>(self : Map<K, V>) : Types.Iter<K>

/// Iterator over values in ascending key order.
///
/// Runtime: `O(log(n))` to create the iterator.
/// Space: `O(log(n))` retained memory.
public func values<K, V>(self : Map<K, V>) : Types.Iter<V>

/// Apply an operation to each entry in ascending key order.
///
/// Runtime: `O(n)`.
/// Space: `O(log(n))` retained memory.
public func forEach<K, V>(self : Map<K, V>, operation : (K, V) -> ());

```

## Higher-order operations

````motoko
/// Return a new map with entries satisfying `criterion`.
///
/// Example:
/// ```motoko include=import
/// import Nat "mo:core/Nat";
/// import Iter "mo:core/Iter";
///
/// let map = Map.fromIter<Nat, Text>(
///   [(1, "One"), (2, "Two"), (3, "Three"), (4, "Four")].values(),
///   Nat.compare);
/// let evens = Map.filter(map, Nat.compare, func(k, v) { k % 2 == 0 });
/// assert Iter.toArray(Map.entries(evens)) == [(2, "Two"), (4, "Four")];
/// ```
///
/// Runtime: `O(n)`.
/// Space: `O(n)`.
public func filter<K, V>(self : Map<K, V>, compare : (implicit : (K, K) -> Order.Order), criterion : (K, V) -> Bool) : Map<K, V>

/// Map values to a new type while keeping the same keys.
///
/// Example:
/// ```motoko include=import
/// import Nat "mo:core/Nat";
/// import Text "mo:core/Text";
/// import Iter "mo:core/Iter";
///
/// let map = Map.fromIter<Nat, Text>(
///   [(0, "Zero"), (1, "One"), (2, "Two")].values(),
///   Nat.compare);
/// let lengths = Map.map(map, func(k, v) { Text.size(v) });
/// assert Iter.toArray(Map.entries(lengths)) == [(0, 4), (1, 3), (2, 3)];
/// ```
///
/// Runtime: `O(n)`.
/// Space: `O(n)`.
public func map<K, V1, V2>(self : Map<K, V1>, project : (K, V1) -> V2) : Map<K, V2>

/// Map and filter in one pass: keep only entries with `?value` results.
///
/// Runtime: `O(n)`.
/// Space: `O(n)`.
public func filterMap<K, V1, V2>(self : Map<K, V1>, compare : (implicit : (K, K) -> Order.Order), project : (K, V1) -> ?V2) : Map<K, V2>

/// Left fold over entries in ascending key order.
///
/// Example:
/// ```motoko include=import
/// import Nat "mo:core/Nat";
///
/// let map = Map.fromIter<Nat, Nat>(
///   [(0, 10), (1, 20), (2, 30)].values(),
///   Nat.compare);
/// let sum = Map.foldLeft(map, 0, func(acc, k, v) { acc + v });
/// assert sum == 60;
/// ```
///
/// Runtime: `O(n)`.
/// Space: `O(log(n))`.
public func foldLeft<K, V, A>(
  self : Map<K, V>,
  base : A,
  combine : (A, K, V) -> A,
) : A

/// Right fold over entries in descending key order.
///
/// Runtime: `O(n)`.
/// Space: `O(log(n))`.
public func foldRight<K, V, A>(
  self : Map<K, V>,
  base : A,
  combine : (K, V, A) -> A,
) : A

/// Return `true` if all entries satisfy `predicate`.
///
/// Example:
/// ```motoko include=import
/// import Nat "mo:core/Nat";
///
/// let map = Map.fromIter<Nat, Nat>(
///   [(0, 10), (1, 20), (2, 30)].values(),
///   Nat.compare);
/// assert Map.all(map, func(k, v) { v >= 10 });
/// ```
///
/// Runtime: `O(n)` worst case.
/// Space: `O(log(n))`.
public func all<K, V>(self : Map<K, V>, predicate : (K, V) -> Bool) : Bool

/// Return `true` if any entry satisfies `predicate`.
///
/// Example:
/// ```motoko include=import
/// import Nat "mo:core/Nat";
///
/// let map = Map.fromIter<Nat, Nat>(
///   [(0, 10), (1, 20), (2, 30)].values(),
///   Nat.compare);
/// assert Map.any(map, func(k, v) { v > 25 });
/// ```
///
/// Runtime: `O(n)` worst case.
/// Space: `O(log(n))`.
public func any<K, V>(self : Map<K, V>, predicate : (K, V) -> Bool) : Bool;

````

## Comparisons and conversions

````motoko
/// Test whether two imperative maps have equal entries.
/// Both maps have to be constructed by the same comparison function.
///
/// Example:
/// ```motoko include=import
/// import Nat "mo:core/Nat";
/// import Text "mo:core/Text";
///
/// let map1 = Map.fromIter<Nat, Text>(
///   [(0, "Zero"), (1, "One"), (2, "Two")].values(),
///   Nat.compare);
/// let map2 = Map.clone(map1);
///
/// assert Map.equal(map1, map2, Nat.compare, Text.equal);
/// Map.clear(map2);
/// assert not Map.equal(map1, map2, Nat.compare, Text.equal);
/// ```
///
/// Runtime: `O(n)`.
/// Space: `O(1)`.
public func equal<K, V>(self : Map<K, V>, other : Map<K, V>, compare : (implicit : (K, K) -> Types.Order), equal : (implicit : (V, V) -> Bool)) : Bool

/// Lexicographically compare two maps by keys, then values.
///
/// Runtime: `O(n)` worst case.
/// Space: `O(1)`.
public func compare<K, V>(self : Map<K, V>, other : Map<K, V>, compareKey : (implicit : (compare : (K, K) -> Order.Order)), compareValue : (implicit : (compare : (V, V) -> Order.Order))) : Order.Order

/// Generate a textual representation of the map for debugging.
///
/// Runtime: `O(n)`.
/// Space: `O(n)`.
public func toText<K, V>(self : Map<K, V>, keyFormat : (implicit : (toText : K -> Text)), valueFormat : (implicit : (toText : V -> Text))) : Text

/// Convert the mutable key-value map to an immutable key-value map.
///
/// Example:
/// ```motoko include=import
/// import PureMap "mo:core/pure/Map";
/// import Nat "mo:core/Nat";
/// import Iter "mo:core/Iter";
///
/// let map = Map.fromIter<Nat, Text>(
///   [(0, "Zero"), (1, "One"), (2, "Two")].values(), Nat.compare);
/// let pureMap = Map.toPure(map, Nat.compare);
/// assert Iter.toArray(PureMap.entries(pureMap)) == Iter.toArray(Map.entries(map))
/// ```
///
/// Runtime: `O(n * log(n))`.
/// Space: `O(n)` retained memory plus garbage, see the note below.
/// where `n` denotes the number of key-value entries stored in the map and
/// assuming that the `compare` function implements an `O(1)` comparison.
///
/// Note: Creates `O(n * log(n))` temporary objects that will be collected as garbage.
/// @deprecated M0235
public func toPure<K, V>(self : Map<K, V>, compare : (implicit : (K, K) -> Order.Order)) : PureMap.Map<K, V>

/// Convert an immutable key-value map to a mutable key-value map.
///
/// Example:
/// ```motoko include=import
/// import PureMap "mo:core/pure/Map";
/// import Nat "mo:core/Nat";
/// import Iter "mo:core/Iter";
///
/// let pureMap = PureMap.fromIter(
///   [(0, "Zero"), (1, "One"), (2, "Two")].values(), Nat.compare);
/// let map = Map.fromPure<Nat, Text>(pureMap, Nat.compare);
/// assert Iter.toArray(Map.entries(map)) == Iter.toArray(PureMap.entries(pureMap))
/// ```
///
/// Runtime: `O(n * log(n))`.
/// Space: `O(n)`.
/// where `n` denotes the number of key-value entries stored in the map and
/// assuming that the `compare` function implements an `O(1)` comparison.
/// @deprecated M0235
public func fromPure<K, V>(map : PureMap.Map<K, V>, compare : (implicit : (K, K) -> Order.Order)) : Map<K, V>

/// Internal sanity check; traps if the internal structure is invalid.
/// @deprecated M0235
public func assertValid<K, V>(self : Map<K, V>, compare : (implicit : (K, K) -> Order.Order));

````

---

This file mirrors `src/Map.mo` so AI tooling has immediate access to the canonical examples.
