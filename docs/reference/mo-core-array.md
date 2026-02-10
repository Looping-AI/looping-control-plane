# mo:core Array module

High-level reference for `mo:core/Array`, focusing on the most useful operations and including the official examples from the core library.

## Import

```motoko name=import
import Array "mo:core/Array";

```

## Overview

- Immutable arrays have type `[T]`; mutable arrays have type `[var T]`.
- Mutable arrays allow elements to be modified; immutable arrays are fixed once created.
- For grow/shrink behavior, prefer `List` (`mo:core/pure/List`). Arrays have fixed size.

The sections below group the main functions by usage, with the original examples inlined for reference.

## Construction

### `empty`

````motoko
/// Creates an empty array (equivalent to `[]`).
///
/// ```motoko include=import
/// let array = Array.empty<Text>();
/// assert array == [];
/// ```
///
/// Runtime: O(1)
///
/// Space: O(1)
public func empty<T>() : [T];

````

### `repeat`

````motoko
/// Creates an array containing `item` repeated `size` times.
///
/// ```motoko include=import
/// let array = Array.repeat<Text>("Echo", 3);
/// assert array == ["Echo", "Echo", "Echo"];
/// ```
///
/// Runtime: O(size)
///
/// Space: O(size)
public func repeat<T>(item : T, size : Nat) : [T];

````

### `tabulate`

````motoko
/// Creates an immutable array of size `size`. Each element at index i
/// is created by applying `generator` to i.
///
/// ```motoko include=import
/// let array : [Nat] = Array.tabulate<Nat>(4, func i = i * 2);
/// assert array == [0, 2, 4, 6];
/// ```
///
/// Runtime: O(size)
///
/// Space: O(size)
///
/// *Runtime and space assumes that `generator` runs in O(1) time and space.
public let tabulate : <T>(size : Nat, generator : Nat -> T) -> [T];

````

### `fromVarArray` / `toVarArray`

````motoko
/// Transforms a mutable array into an immutable array.
///
/// ```motoko include=import
/// let varArray = [var 0, 1, 2];
/// varArray[2] := 3;
/// let array = Array.fromVarArray<Nat>(varArray);
/// assert array == [0, 1, 3];
/// ```
///
/// Runtime: O(size)
///
/// Space: O(1)
/// @deprecated M0235
public func fromVarArray<T>(varArray : [var T]) : [T]

/// Transforms an immutable array into a mutable array.
///
/// ```motoko include=import
/// import VarArray "mo:core/VarArray";
/// import Nat "mo:core/Nat";
///
/// let array = [0, 1, 2];
/// let varArray = Array.toVarArray<Nat>(array);
/// varArray[2] := 3;
/// assert VarArray.equal(varArray, [var 0, 1, 3], Nat.equal);
/// ```
///
/// Runtime: O(size)
///
/// Space: O(1)
public func toVarArray<T>(self : [T]) : [var T];

````

## Equality and comparison

### `equal`

````motoko
/// Tests if two arrays contain equal values (i.e. they represent the same
/// list of elements). Uses `equal` to compare elements in the arrays.
///
/// ```motoko include=import
/// // Use the equal function from the Nat module to compare Nats
/// import {equal} "mo:core/Nat";
///
/// let array1 = [0, 1, 2, 3];
/// let array2 = [0, 1, 2, 3];
/// assert Array.equal(array1, array2, equal);
/// ```
///
/// Runtime: O(size1 + size2)
///
/// Space: O(1)
///
/// *Runtime and space assumes that `equal` runs in O(1) time and space.
public func equal<T>(self : [T], other : [T], equal : (implicit : (T, T) -> Bool)) : Bool;

````

### `compare`

````motoko
/// Compares two arrays using the provided comparison function for elements.
/// Returns #less, #equal, or #greater if `array1` is less than, equal to,
/// or greater than `array2` respectively.
///
/// If arrays have different sizes but all elements up to the shorter length are equal,
/// the shorter array is considered #less than the longer array.
///
/// ```motoko include=import
/// import Nat "mo:core/Nat";
///
/// let array1 = [1, 2, 3];
/// let array2 = [1, 2, 4];
/// assert Array.compare<Nat>(array1, array2, Nat.compare) == #less;
/// ```
///
/// ```motoko include=import
/// import Nat "mo:core/Nat";
///
/// let array3 = [1, 2];
/// let array4 = [1, 2, 3];
/// assert Array.compare<Nat>(array3, array4, Nat.compare) == #less;
/// ```
///
/// Runtime: O(min(size1, size2))
///
/// Space: O(1)
///
/// *Runtime and space assumes that `compare` runs in O(1) time and space.
public func compare<T>(self : [T], other : [T], compare : (implicit : (T, T) -> Order.Order)) : Order.Order;

````

## Search helpers

### `find` / `findIndex`

````motoko
/// Returns the first value in `array` for which `predicate` returns true.
/// If no element satisfies the predicate, returns null.
///
/// ```motoko include=import
/// let array = [1, 9, 4, 8];
/// let found = Array.find<Nat>(array, func x = x > 8);
/// assert found == ?9;
/// ```
/// Runtime: O(size)
///
/// Space: O(1)
///
/// *Runtime and space assumes that `predicate` runs in O(1) time and space.
public func find<T>(self : [T], predicate : T -> Bool) : ?T

/// Returns the first index in `array` for which `predicate` returns true.
/// If no element satisfies the predicate, returns null.
///
/// ```motoko include=import
/// let array = ['A', 'B', 'C', 'D'];
/// let found = Array.findIndex<Char>(array, func(x) { x == 'C' });
/// assert found == ?2;
/// ```
/// Runtime: O(size)
///
/// Space: O(1)
///
/// *Runtime and space assumes that `predicate` runs in O(1) time and space.
public func findIndex<T>(self : [T], predicate : T -> Bool) : ?Nat;

````

### `indexOf` / `nextIndexOf` / `lastIndexOf` / `prevIndexOf`

````motoko
/// Returns the index of the first `element` in the `array`.
///
/// ```motoko include=import
/// import Char "mo:core/Char";
/// let array = ['c', 'o', 'f', 'f', 'e', 'e'];
/// assert Array.indexOf<Char>(array, Char.equal, 'c') == ?0;
/// assert Array.indexOf<Char>(array, Char.equal, 'f') == ?2;
/// assert Array.indexOf<Char>(array, Char.equal, 'g') == null;
/// ```
///
/// Runtime: O(array.size())
///
/// Space: O(1)
public func indexOf<T>(self : [T], equal : (implicit : (T, T) -> Bool), element : T) : ?Nat

/// Returns the index of the next occurrence of `element` in the `array` starting from the `from` index (inclusive).
///
/// ```motoko include=import
/// import Char "mo:core/Char";
/// let array = ['c', 'o', 'f', 'f', 'e', 'e'];
/// assert Array.nextIndexOf<Char>(array, Char.equal, 'c', 0) == ?0;
/// assert Array.nextIndexOf<Char>(array, Char.equal, 'f', 0) == ?2;
/// assert Array.nextIndexOf<Char>(array, Char.equal, 'f', 2) == ?2;
/// assert Array.nextIndexOf<Char>(array, Char.equal, 'f', 3) == ?3;
/// assert Array.nextIndexOf<Char>(array, Char.equal, 'f', 4) == null;
/// ```
///
/// Runtime: O(array.size())
///
/// Space: O(1)
public func nextIndexOf<T>(self : [T], equal : (implicit : (T, T) -> Bool), element : T, fromInclusive : Nat) : ?Nat

/// Returns the index of the last `element` in the `array`.
///
/// ```motoko include=import
/// import Char "mo:core/Char";
/// let array = ['c', 'o', 'f', 'f', 'e', 'e'];
/// assert Array.lastIndexOf<Char>(array, Char.equal, 'c') == ?0;
/// assert Array.lastIndexOf<Char>(array, Char.equal, 'f') == ?3;
/// assert Array.lastIndexOf<Char>(array, Char.equal, 'e') == ?5;
/// assert Array.lastIndexOf<Char>(array, Char.equal, 'g') == null;
/// ```
///
/// Runtime: O(array.size())
///
/// Space: O(1)
public func lastIndexOf<T>(self : [T], equal : (implicit : (T, T) -> Bool), element : T) : ?Nat

/// Returns the index of the previous occurrence of `element` in the `array` starting from the `from` index (exclusive).
///
/// ```motoko include=import
/// import Char "mo:core/Char";
/// let array = ['c', 'o', 'f', 'f', 'e', 'e'];
/// assert Array.prevIndexOf<Char>(array, Char.equal, 'c', array.size()) == ?0;
/// assert Array.prevIndexOf<Char>(array, Char.equal, 'e', array.size()) == ?5;
/// assert Array.prevIndexOf<Char>(array, Char.equal, 'e', 5) == ?4;
/// assert Array.prevIndexOf<Char>(array, Char.equal, 'e', 4) == null;
/// ```
///
/// Runtime: O(array.size());
/// Space: O(1);
public func prevIndexOf<T>(self : [T], equal : (implicit : (T, T) -> Bool), element : T, fromExclusive : Nat) : ?Nat;

````

## Predicates

````motoko
/// Returns true if all elements in `array` satisfy the predicate function.
///
/// ```motoko include=import
/// let array = [1, 2, 3, 4];
/// assert Array.all<Nat>(array, func x = x > 0);
/// ```
///
/// Runtime: O(size)
///
/// Space: O(1)
///
/// *Runtime and space assumes that `predicate` runs in O(1) time and space.
public func all<T>(self : [T], predicate : T -> Bool) : Bool

/// Returns true if any element in `array` satisfies the predicate function.
///
/// ```motoko include=import
/// let array = [1, 2, 3, 4];
/// assert Array.any<Nat>(array, func x = x > 3);
/// ```
///
/// Runtime: O(size)
///
/// Space: O(1)
///
/// *Runtime and space assumes that `predicate` runs in O(1) time and space.
public func any<T>(self : [T], predicate : T -> Bool) : Bool;

````

## Combining and flattening

````motoko
/// Create a new array by concatenating the values of `array1` and `array2`.
/// Note that `Array.concat` copies its arguments and has linear complexity.
///
/// ```motoko include=import
/// let array1 = [1, 2, 3];
/// let array2 = [4, 5, 6];
/// let result = Array.concat<Nat>(array1, array2);
/// assert result == [1, 2, 3, 4, 5, 6];
/// ```
/// Runtime: O(size1 + size2)
///
/// Space: O(size1 + size2)
public func concat<T>(self : [T], other : [T]) : [T]

/// Combines an iterator of arrays into a single array. Retains the original
/// ordering of the elements.
///
/// Consider using `Array.flatten()` for better performance.
///
/// ```motoko include=import
/// let arrays = [[0, 1, 2], [2, 3], [], [4]];
/// let joinedArray = Array.join<Nat>(arrays.values());
/// assert joinedArray == [0, 1, 2, 2, 3, 4];
/// ```
///
/// Runtime: O(number of elements in array)
///
/// Space: O(number of elements in array)
public func join<T>(self : Types.Iter<[T]>) : [T]

/// Combines an array of arrays into a single array. Retains the original
/// ordering of the elements.
///
/// This has better performance compared to `Array.join()`.
///
/// ```motoko include=import
/// let arrays = [[0, 1, 2], [2, 3], [], [4]];
/// let flatArray = Array.flatten<Nat>(arrays);
/// assert flatArray == [0, 1, 2, 2, 3, 4];
/// ```
///
/// Runtime: O(number of elements in array)
///
/// Space: O(number of elements in array)
public func flatten<T>(self : [[T]]) : [T];

````

## Sorting, reversing, and order checks

````motoko
/// Sorts the elements in the array according to `compare`.
/// Sort is deterministic and stable.
///
/// ```motoko include=import
/// import Nat "mo:core/Nat";
///
/// let array = [4, 2, 6];
/// let sorted = Array.sort(array, Nat.compare);
/// assert sorted == [2, 4, 6];
/// ```
/// Runtime: O(size * log(size))
///
/// Space: O(size)
/// *Runtime and space assumes that `compare` runs in O(1) time and space.
public func sort<T>(self : [T], compare : (implicit : (T, T) -> Order.Order)) : [T]

/// Creates a new array by reversing the order of elements in `array`.
///
/// ```motoko include=import
/// let array = [10, 11, 12];
/// let reversed = Array.reverse(array);
/// assert reversed == [12, 11, 10];
/// ```
///
/// Runtime: O(size)
///
/// Space: O(1)
public func reverse<T>(self : [T]) : [T]

/// Performs binary search on a sorted array to find the index of the `element`.
///
/// Returns `#found(index)` if the element is found, or `#insertionIndex(index)` with the index
/// where the element would be inserted according to the ordering if not found.
///
/// If there are multiple equal elements, no guarantee is made about which index is returned.
/// The array must be sorted in ascending order according to the `compare` function.
///
/// ```motoko include=import
/// import Nat "mo:core/Nat";
///
/// let sorted = [1, 3, 5, 7, 9, 11];
/// assert Array.binarySearch<Nat>(sorted, Nat.compare, 5) == #found(2);
/// assert Array.binarySearch<Nat>(sorted, Nat.compare, 6) == #insertionIndex(3);
/// ```
///
/// Runtime: O(log(size))
///
/// Space: O(1)
///
/// *Runtime and space assumes that `compare` runs in O(1) time and space.
public func binarySearch<T>(self : [T], compare : (implicit : (T, T) -> Order.Order), element : T) : {
  #found : Nat;
  #insertionIndex : Nat;
};

/// Checks whether the `array` is sorted according to the `compare` function.
///
/// ```motoko include=import
/// import Nat "mo:core/Nat";
///
/// let array = [1, 2, 3];
/// assert Array.isSorted<Nat>(array, Nat.compare);
/// ```
///
/// Runtime: O(size)
///
/// Space: O(1)
///
/// *Runtime and space assumes that `compare` runs in O(1) time and space.
public func isSorted<T>(self : [T], compare : (implicit : (T, T) -> Order.Order)) : Bool;

````

## Mapping and filtering

````motoko
/// Calls `f` with each element in `array`.
/// Retains original ordering of elements.
///
/// ```motoko include=import
/// var sum = 0;
/// let array = [0, 1, 2, 3];
/// Array.forEach<Nat>(array, func(x) {
///   sum += x;
/// });
/// assert sum == 6;
/// ```
///
/// Runtime: O(size)
///
/// Space: O(size)
///
/// *Runtime and space assumes that `f` runs in O(1) time and space.
public func forEach<T>(self : [T], f : T -> ())

/// Creates a new array by applying `f` to each element in `array`. `f` "maps"
/// each element it is applied to of type `X` to an element of type `Y`.
/// Retains original ordering of elements.
///
/// ```motoko include=import
/// let array1 = [0, 1, 2, 3];
/// let array2 = Array.map<Nat, Nat>(array1, func x = x * 2);
/// assert array2 == [0, 2, 4, 6];
/// ```
///
/// Runtime: O(size)
///
/// Space: O(size)
///
/// *Runtime and space assumes that `f` runs in O(1) time and space.
public func map<T, R>(self : [T], f : T -> R) : [R]

/// Creates a new array by applying `predicate` to every element
/// in `array`, retaining the elements for which `predicate` returns true.
///
/// ```motoko include=import
/// let array = [4, 2, 6, 1, 5];
/// let evenElements = Array.filter<Nat>(array, func x = x % 2 == 0);
/// assert evenElements == [4, 2, 6];
/// ```
/// Runtime: O(size)
///
/// Space: O(size)
/// *Runtime and space assumes that `predicate` runs in O(1) time and space.
public func filter<T>(self : [T], f : T -> Bool) : [T]

/// Creates a new array by applying `f` to each element in `array`,
/// and keeping all non-null elements. The ordering is retained.
///
/// ```motoko include=import
/// import {toText} "mo:core/Nat";
///
/// let array = [4, 2, 0, 1];
/// let newArray =
///   Array.filterMap<Nat, Text>( // mapping from Nat to Text values
///     array,
///     func x = if (x == 0) { null } else { ?toText(100 / x) } // can't divide by 0, so return null
///   );
/// assert newArray == ["25", "50", "100"];
/// ```
/// Runtime: O(size)
///
/// Space: O(size)
/// *Runtime and space assumes that `f` runs in O(1) time and space.
public func filterMap<T, R>(self : [T], f : T -> ?R) : [R]

/// Creates a new array by applying `f` to each element in `array`.
/// If any invocation of `f` produces an `#err`, returns an `#err`. Otherwise
/// returns an `#ok` containing the new array.
///
/// ```motoko include=import
/// let array = [4, 3, 2, 1, 0];
/// // divide 100 by every element in the array
/// let result = Array.mapResult<Nat, Nat, Text>(array, func x {
///   if (x > 0) {
///     #ok(100 / x)
///   } else {
///     #err "Cannot divide by zero"
///   }
/// });
/// assert result == #err "Cannot divide by zero";
/// ```
///
/// Runtime: O(size)
///
/// Space: O(size)
///
/// *Runtime and space assumes that `f` runs in O(1) time and space.
/// @deprecated M0235
public func mapResult<T, R, E>(self : [T], f : T -> Types.Result <R, E]) : Types.Result<[R], E>

/// Creates a new array by applying `f` to each element in `array` and its index.
/// Retains original ordering of elements.
///
/// ```motoko include=import
/// let array = [10, 10, 10, 10];
/// let newArray = Array.mapEntries<Nat, Nat>(array, func (x, i) = i * x);
/// assert newArray == [0, 10, 20, 30];
/// ```
///
/// Runtime: O(size)
///
/// Space: O(size)
///
/// *Runtime and space assumes that `f` runs in O(1) time and space.
public func mapEntries<T, R>(self : [T], f : (T, Nat) -> R) : [R]

/// Creates a new array by applying `k` to each element in `array`,
/// and concatenating the resulting arrays in order.
///
/// ```motoko include=import
/// let array = [1, 2, 3, 4];
/// let newArray = Array.flatMap<Nat, Int>(array, func x = [x, -x].values());
/// assert newArray == [1, -1, 2, -2, 3, -3, 4, -4];
/// ```
/// Runtime: O(size)
///
/// Space: O(size)
/// *Runtime and space assumes that `k` runs in O(1) time and space.
public func flatMap<T, R>(self : [T], k : T -> Types.Iter<R>) : [R];

````

## Folding (reductions)

````motoko
/// Collapses the elements in `array` into a single value by starting with `base`
/// and progressively combining elements into `base` with `combine`. Iteration runs
/// left to right.
///
/// ```motoko include=import
/// import {add} "mo:core/Nat";
///
/// let array = [4, 2, 0, 1];
/// let sum =
///   Array.foldLeft<Nat, Nat>(
///     array,
///     0, // start the sum at 0
///     func(sumSoFar, x) = sumSoFar + x // this entire function can be replaced with `add`!
///   );
/// assert sum == 7;
/// ```
///
/// Runtime: O(size)
///
/// Space: O(1)
///
/// *Runtime and space assumes that `combine` runs in O(1) time and space.
public func foldLeft<T, A>(self : [T], base : A, combine : (A, T) -> A : A)

/// Collapses the elements in `array` into a single value by starting with `base`
/// and progressively combining elements into `base` with `combine`. Iteration runs
/// right to left.
///
/// ```motoko include=import
/// import {toText} "mo:core/Nat";
///
/// let array = [1, 9, 4, 8];
/// let bookTitle = Array.foldRight<Nat, Text>(array, "", func(x, acc) = toText(x) # acc);
/// assert bookTitle == "1948";
/// ```
///
/// Runtime: O(size)
///
/// Space: O(1)
///
/// *Runtime and space assumes that `combine` runs in O(1) time and space.
public func foldRight<T, A>(self : [T], base : A, combine : (T, A) -> A) : A;

````

## Iteration views and ranges

````motoko
/// Returns an iterator (`Iter`) over the indices of `array`.
/// An iterator provides a single method `next()`, which returns
/// indices in order, or `null` when out of index to iterate over.
///
/// Note: You can also use `array.keys()` instead of this function. See example
/// below.
///
/// ```motoko include=import
/// let array = [10, 11, 12];
///
/// var sum = 0;
/// for (element in array.keys()) {
///   sum += element;
/// };
/// assert sum == 3; // 0 + 1 + 2
/// ```
///
/// Runtime: O(1)
///
/// Space: O(1)
public func keys<T>(self : [T]) : Types.Iter<Nat>

/// Iterator provides a single method `next()`, which returns
/// elements in order, or `null` when out of elements to iterate over.
///
/// Note: You can also use `array.values()` instead of this function. See example
/// below.
///
/// ```motoko include=import
/// let array = [10, 11, 12];
///
/// var sum = 0;
/// for (element in array.values()) {
///   sum += element;
/// };
/// assert sum == 33;
/// ```
///
/// Runtime: O(1)
///
/// Space: O(1)
public func values<T>(self : [T]) : Types.Iter<T>

/// Iterator provides a single method `next()`, which returns
/// pairs of (index, element) in order, or `null` when out of elements to iterate over.
///
/// ```motoko include=import
/// let array = [10, 11, 12];
///
/// var sum = 0;
/// for ((index, element) in Array.enumerate(array)) {
///   sum += element;
/// };
/// assert sum == 33;
/// ```
///
/// Runtime: O(1)
///
/// Space: O(1)
public func enumerate<T>(self : [T]) : Types.Iter<(Nat, T)>;

````

### `range`, `sliceToArray`, `sliceToVarArray`

````motoko
/// Returns an iterator over a slice of `array` starting at `fromInclusive` up to (but not including) `toExclusive`.
///
/// Negative indices are relative to the end of the array. For example, `-1` corresponds to the last element in the array.
///
/// If the indices are out of bounds, they are clamped to the array bounds.
/// If the first index is greater than the second, the function returns an empty iterator.
///
/// ```motoko include=import
/// let array = [1, 2, 3, 4, 5];
/// let iter1 = Array.range<Nat>(array, 3, array.size());
/// assert iter1.next() == ?4;
/// assert iter1.next() == ?5;
/// assert iter1.next() == null;
///
/// let iter2 = Array.range<Nat>(array, 3, -1);
/// assert iter2.next() == ?4;
/// assert iter2.next() == null;
///
/// let iter3 = Array.range<Nat>(array, 0, 0);
/// assert iter3.next() == null;
/// ```
///
/// Runtime: O(1)
///
/// Space: O(1)
public func range<T>(self : [T], fromInclusive : Int, toExclusive : Int) : Types.Iter<T>

/// Returns a new array containing elements from `array` starting at `fromInclusive` up to (but not including) index `toExclusive`.
/// If the indices are out of bounds, they are clamped to the array bounds.
///
/// ```motoko include=import
/// let array = [1, 2, 3, 4, 5];
///
/// let slice1 = Array.sliceToArray<Nat>(array, 1, 4);
/// assert slice1 == [2, 3, 4];
///
/// let slice2 = Array.sliceToArray<Nat>(array, 1, -1);
/// assert slice2 == [2, 3, 4];
/// ```
///
/// Runtime: O(toExclusive - fromInclusive)
///
/// Space: O(toExclusive - fromInclusive)
public func sliceToArray<T>(self : [T], fromInclusive : Int, toExclusive : Int) : [T]

/// Returns a new mutable array containing elements from `array` starting at `fromInclusive` up to (but not including) index `toExclusive`.
/// If the indices are out of bounds, they are clamped to the array bounds.
///
/// ```motoko include=import
/// import VarArray "mo:core/VarArray";
/// import Nat "mo:core/Nat";
///
/// let array = [1, 2, 3, 4, 5];
///
/// let slice1 = Array.sliceToVarArray<Nat>(array, 1, 4);
/// assert VarArray.equal(slice1, [var 2, 3, 4], Nat.equal);
///
/// let slice2 = Array.sliceToVarArray<Nat>(array, 1, -1);
/// assert VarArray.equal(slice2, [var 2, 3, 4], Nat.equal);
/// ```
///
/// Runtime: O(toExclusive - fromInclusive)
///
/// Space: O(toExclusive - fromInclusive)
public func sliceToVarArray<T>(self : [T], fromInclusive : Int, toExclusive : Int) : [var T];

````

## Text representation and other helpers

````motoko
/// Create an array containing a single value.
///
/// ```motoko include=import
/// let array = Array.singleton(2);
/// assert array == [2];
/// ```
///
/// Runtime: O(1)
///
/// Space: O(1)
public func singleton<T>(element : T) : [T]

/// Returns the size of an array. Equivalent to `array.size()`.
public func size<T>(self : [T]) : Nat

/// Returns whether an array is empty, i.e. contains zero elements.
public func isEmpty<T>(self : [T]) : Bool

/// Converts an iterator to an array.
/// @deprecated M0235
public func fromIter<T>(iter : Types.Iter<T>) : [T]

/// Converts the array to its textual representation using `f` to convert each element to `Text`.
///
/// ```motoko include=import
/// import Nat "mo:core/Nat";
///
/// let array = [1, 2, 3];
/// let text = Array.toText<Nat>(array, Nat.toText);
/// assert text == "[1, 2, 3]";
/// ```
///
/// Runtime: O(size)
///
/// Space: O(size)
///
/// *Runtime and space assumes that `f` runs in O(1) time and space.
public func toText<T>(self : [T], f : (implicit : (toText : T -> Text))) : Text;

````

---

This file mirrors the official `mo:core/Array` documentation: function groupings are summarized, and all examples are copied verbatim so tools like Copilot and Claude can rely on the same reference you would find in the upstream library.
