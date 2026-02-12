# mo:core Iter module

Reference for `mo:core/Iter`, mirroring the upstream documentation and examples for iterator utilities.

## Import

```motoko name=import
import Iter "mo:core/Iter";

```

## Overview

Iterators represent lazily produced sequences. They’re stateful—each `next()` consumes a value—so avoid sharing one iterator between multiple consumers unless you control the lifecycle.

```motoko
/// Utilities for `Iter` (iterator) values.
///
/// Iterators are a way to represent sequences of values that can be lazily produced.
/// They can be used to:
/// - Iterate over collections.
/// - Represent collections that are too large to fit in memory or that are produced incrementally.
/// - Transform collections without creating intermediate collections.
///
/// Iterators are inherently stateful. Calling `next` "consumes" a value from
/// the Iterator that cannot be put back, so keep that in mind when sharing
/// iterators between consumers.

```

## Constructors

````motoko
/// Creates an empty iterator.
///
/// ```motoko include=import
/// for (x in Iter.empty<Nat>())
///   assert false; // This loop body will never run
/// ```
public func empty<T>() : Iter<T>

/// Creates an iterator that produces a single value.
///
/// ```motoko include=import
/// var sum = 0;
/// for (x in Iter.singleton(3))
///   sum += x;
/// assert sum == 3;
/// ```
public func singleton<T>(value : T) : Iter<T>;

````

## Consumption helpers

````motoko
/// Calls a function `f` on every value produced by an iterator and discards
/// the results. If you're looking to keep these results use `map` instead.
///
/// ```motoko include=import
/// var sum = 0;
/// Iter.forEach<Nat>([1, 2, 3].values(), func(x) {
///   sum += x;
/// });
/// assert sum == 6;
/// ```
public func forEach<T>(
  self : Iter<T>,
  f : (T) -> (),
)

/// Consumes an iterator and counts how many elements were produced (discarding them in the process).
/// ```motoko include=import
/// let iter = [1, 2, 3].values();
/// assert 3 == Iter.size(iter);
/// ```
public func size<T>(self : Iter<T>) : Nat;

````

## Transformation

````motoko
/// Takes an iterator and returns a new iterator that pairs each element with its index.
/// The index starts at 0 and increments by 1 for each element.
///
/// ```motoko include=import
/// let iter = Iter.fromArray(["A", "B", "C"]);
/// let enumerated = Iter.enumerate(iter);
/// let result = Iter.toArray(enumerated);
/// assert result == [(0, "A"), (1, "B"), (2, "C")];
/// ```
public func enumerate<T>(self : Iter<T>) : Iter<(Nat, T)>

/// Creates a new iterator that yields every nth element from the original iterator.
/// If `interval` is 0, returns an empty iterator. If `interval` is 1, returns the original iterator.
///
/// ```motoko include=import
/// let iter = Iter.fromArray([1, 2, 3, 4, 5, 6]);
/// let steppedIter = Iter.step(iter, 2); // Take every 2nd element
/// assert ?1 == steppedIter.next();
/// assert ?3 == steppedIter.next();
/// assert ?5 == steppedIter.next();
/// assert null == steppedIter.next();
/// ```
public func step<T>(self : Iter<T>, n : Nat) : Iter<T>

/// Takes a function and an iterator and returns a new iterator that lazily applies
/// the function to every element produced by the argument iterator.
/// ```motoko include=import
/// let iter = [1, 2, 3].values();
/// let mappedIter = Iter.map<Nat, Nat>(iter, func (x) = x * 2);
/// let result = Iter.toArray(mappedIter);
/// assert result == [2, 4, 6];
/// ```
public func map<T, R>(self : Iter<T>, f : T -> R) : Iter<R>

/// Creates a new iterator that only includes elements from the original iterator
/// for which the predicate function returns true.
///
/// ```motoko include=import
/// let iter = [1, 2, 3, 4, 5].values();
/// let evenNumbers = Iter.filter<Nat>(iter, func (x) = x % 2 == 0);
/// let result = Iter.toArray(evenNumbers);
/// assert result == [2, 4];
/// ```
public func filter<T>(self : Iter<T>, f : T -> Bool) : Iter<T>

/// Creates a new iterator by applying a transformation function to each element
/// of the original iterator. Elements for which the function returns null are
/// excluded from the result.
///
/// ```motoko include=import
/// let iter = [1, 2, 3].values();
/// let evenNumbers = Iter.filterMap<Nat, Nat>(iter, func (x) = if (x % 2 == 0) ?x else null);
/// let result = Iter.toArray(evenNumbers);
/// assert result == [2];
/// ```
public func filterMap<T, R>(self : Iter<T>, f : T -> ?R) : Iter<R>

/// Flattens an iterator of iterators into a single iterator by concatenating the inner iterators.
/// ```motoko include=import
/// let iter = Iter.flatten([[1, 2].values(), [3].values(), [4, 5, 6].values()].values());
/// let result = Iter.toArray(iter);
/// assert result == [1, 2, 3, 4, 5, 6];
/// ```
public func flatten<T>(self : Iter<Iter<T>>) : Iter<T>

/// Transforms every element of an iterator into an iterator and concatenates the results.
/// ```motoko include=import
/// let iter = Iter.flatMap<Nat, Nat>([1, 3, 5].values(), func (x) = [x, x + 1].values());
/// let result = Iter.toArray(iter);
/// assert result == [1, 2, 3, 4, 5, 6];
/// ```
public func flatMap<T, R>(self : Iter<T>, f : T -> Iter<R>) : Iter<R>;

````

## Windowing and slicing

````motoko
/// Returns a new iterator that yields at most, first `n` elements from the original iterator.
///
/// ```motoko include=import
/// let iter = Iter.fromArray([1, 2, 3, 4, 5]);
/// let first3 = Iter.take(iter, 3);
/// let result = Iter.toArray(first3);
/// assert result == [1, 2, 3];
/// ```
public func take<T>(self : Iter<T>, n : Nat) : Iter<T>

/// Returns a new iterator that yields elements from the original iterator until the predicate function returns false.
///
/// ```motoko include=import
/// let iter = Iter.fromArray([1, 2, 3, 4, 5, 4, 3, 2, 1]);
/// let result = Iter.takeWhile<Nat>(iter, func (x) = x < 4);
/// let array = Iter.toArray(result);
/// assert array == [1, 2, 3];
/// ```
public func takeWhile<T>(self : Iter<T>, f : T -> Bool) : Iter<T>

/// Returns a new iterator that skips the first `n` elements from the original iterator.
///
/// ```motoko include=import
/// let iter = Iter.fromArray([1, 2, 3, 4, 5]);
/// let skipped = Iter.drop(iter, 3);
/// let result = Iter.toArray(skipped);
/// assert result == [4, 5];
/// ```
public func drop<T>(self : Iter<T>, n : Nat) : Iter<T>;

````

---

This summary keeps the exact examples/code blocks from `src/Iter.mo` to maximize retrieval quality for AI tooling.
