# mo:core Blob module

Reference for `mo:core/Blob`, keeping the same wording and examples as the Motoko core docs.

## Import

```motoko name=import
import Blob "mo:core/Blob";

```

## Overview

- Blobs are immutable byte sequences; index operations require converting to an array first.
- Built-in helpers not listed in the module: `blob.size()` and `blob.values()` already exist as methods.
- Literal blobs come from `""` strings with escaped bytes (e.g. `"\00\ff"`).

## Construction and inspection

### `empty`

````motoko
/// Returns an empty `Blob` (equivalent to `""`).
///
/// Example:
/// ```motoko include=import
/// let emptyBlob = Blob.empty();
/// assert emptyBlob.size() == 0;
/// ```
public func empty() : Blob = "";

````

### `isEmpty`

````motoko
/// Returns whether the given `Blob` is empty (has a size of zero).
///
/// ```motoko include=import
/// let blob1 = "" : Blob;
/// let blob2 = "\FF\00" : Blob;
/// assert Blob.isEmpty(blob1);
/// assert not Blob.isEmpty(blob2);
/// ```
public func isEmpty(self : Blob) : Bool = self == "";

````

### `size`

````motoko
/// Returns the number of bytes in the given `Blob`.
/// This is equivalent to `blob.size()`.
///
/// Example:
/// ```motoko include=import
/// let blob = "\FF\00\AA" : Blob;
/// assert Blob.size(blob) == 3;
/// assert blob.size() == 3;
/// ```
public func size(self : Blob) : Nat = self.size();

````

## Conversion helpers

### `fromArray` / `fromVarArray`

````motoko
/// Creates a `Blob` from an array of bytes (`[Nat8]`), by copying each element.
///
/// Example:
/// ```motoko include=import
/// let bytes : [Nat8] = [0, 255, 0];
/// let blob = Blob.fromArray(bytes);
/// assert blob == "\00\FF\00";
/// ```
public let fromArray : (bytes : [Nat8]) -> Blob = Prim.arrayToBlob;

/// Creates a `Blob` from a mutable array of bytes (`[var Nat8]`), by copying each element.
///
/// Example:
/// ```motoko include=import
/// let bytes : [var Nat8] = [var 0, 255, 0];
/// let blob = Blob.fromVarArray(bytes);
/// assert blob == "\00\FF\00";
/// ```
public let fromVarArray : (bytes : [var Nat8]) -> Blob = Prim.arrayMutToBlob;

````

### `toArray` / `toVarArray`

````motoko
/// Converts a `Blob` to an array of bytes (`[Nat8]`), by copying each element.
///
/// Example:
/// ```motoko include=import
/// let blob = "\00\FF\00" : Blob;
/// let bytes = Blob.toArray(blob);
/// assert bytes == [0, 255, 0];
/// ```
public let toArray : (self : Blob) -> [Nat8] = Prim.blobToArray;

/// Converts a `Blob` to a mutable array of bytes (`[var Nat8]`), by copying each element.
///
/// Example:
/// ```motoko include=import
/// import Nat8 "mo:core/Nat8";
/// import VarArray "mo:core/VarArray";
///
/// let blob = "\00\FF\00" : Blob;
/// let bytes = Blob.toVarArray(blob);
/// assert VarArray.equal<Nat8>(bytes, [var 0, 255, 0], Nat8.equal);
/// ```
public let toVarArray : (self : Blob) -> [var Nat8] = Prim.blobToArrayMut;

````

## Hashing and comparisons

### `hash`

````motoko
/// Returns the (non-cryptographic) hash of `blob`.
///
/// Example:
/// ```motoko include=import
/// let blob = "\00\FF\00" : Blob;
/// let h = Blob.hash(blob);
/// assert h == 1_818_567_776;
/// ```
public let hash : (self : Blob) -> Types.Hash = Prim.hashBlob;

````

### `compare`

````motoko
/// General purpose comparison function for `Blob` by comparing the value of
/// the bytes. Returns the `Order` (either `#less`, `#equal`, or `#greater`)
/// by comparing `blob1` with `blob2`.
///
/// Example:
/// ```motoko include=import
/// let blob1 = "\00\00\00" : Blob;
/// let blob2 = "\00\FF\00" : Blob;
/// let result = Blob.compare(blob1, blob2);
/// assert result == #less;
/// ```
public func compare(self : Blob, other : Blob) : Order.Order {
  let c = Prim.blobCompare(self, other);
  if (c < 0) #less else if (c == 0) #equal else #greater;
};

````

## Equality helpers

````motoko
/// Equality function for `Blob` types.
/// This is equivalent to `blob1 == blob2`.
///
/// Example:
/// ```motoko include=import
/// let blob1 = "\00\FF\00" : Blob;
/// let blob2 = "\00\FF\00" : Blob;
/// assert Blob.equal(blob1, blob2);
/// ```
///
/// Note: The reason why this function is defined in this library (in addition
/// to the existing `==` operator) is so that you can use it as a function value
/// to pass to a higher order function.
///
/// Example:
/// ```motoko include=import
/// import List "mo:core/List";
///
/// let list1 = List.singleton<Blob>("\00\FF\00");
/// let list2 = List.singleton<Blob>("\00\FF\00");
/// assert List.equal(list1, list2, Blob.equal);
/// ```
public func equal(self : Blob, other : Blob) : Bool { self == other };

/// Inequality function for `Blob` types.
/// This is equivalent to `blob1 != blob2`.
///
/// Example:
/// ```motoko include=import
/// let blob1 = "\00\AA\AA" : Blob;
/// let blob2 = "\00\FF\00" : Blob;
/// assert Blob.notEqual(blob1, blob2);
/// ```
///
/// Note: The reason why this function is defined in this library (in addition
/// to the existing `!=` operator) is so that you can use it as a function value
/// to pass to a higher order function.
public func notEqual(self : Blob, other : Blob) : Bool { self != other };

````

## Ordering helpers

````motoko
/// "Less than" function for `Blob` types.
/// This is equivalent to `blob1 < blob2`.
///
/// Example:
/// ```motoko include=import
/// let blob1 = "\00\AA\AA" : Blob;
/// let blob2 = "\00\FF\00" : Blob;
/// assert Blob.less(blob1, blob2);
/// ```
///
/// Note: The reason why this function is defined in this library (in addition
/// to the existing `<` operator) is so that you can use it as a function value
/// to pass to a higher order function.
public func less(self : Blob, other : Blob) : Bool { self < other };

/// "Less than or equal to" function for `Blob` types.
/// This is equivalent to `blob1 <= blob2`.
///
/// Example:
/// ```motoko include=import
/// let blob1 = "\00\AA\AA" : Blob;
/// let blob2 = "\00\FF\00" : Blob;
/// assert Blob.lessOrEqual(blob1, blob2);
/// ```
///
/// Note: The reason why this function is defined in this library (in addition
/// to the existing `<=` operator) is so that you can use it as a function value
/// to pass to a higher order function.
public func lessOrEqual(self : Blob, other : Blob) : Bool { self <= other };

/// "Greater than" function for `Blob` types.
/// This is equivalent to `blob1 > blob2`.
///
/// Example:
/// ```motoko include=import
/// let blob1 = "\BB\AA\AA" : Blob;
/// let blob2 = "\00\00\00" : Blob;
/// assert Blob.greater(blob1, blob2);
/// ```
///
/// Note: The reason why this function is defined in this library (in addition
/// to the existing `>` operator) is so that you can use it as a function value
/// to pass to a higher order function.
public func greater(self : Blob, other : Blob) : Bool { self > other };

/// "Greater than or equal to" function for `Blob` types.
/// This is equivalent to `blob1 >= blob2`.
///
/// Example:
/// ```motoko include=import
/// let blob1 = "\BB\AA\AA" : Blob;
/// let blob2 = "\00\00\00" : Blob;
/// assert Blob.greaterOrEqual(blob1, blob2);
/// ```
///
/// Note: The reason why this function is defined in this library (in addition
/// to the existing `>=` operator) is so that you can use it as a function value
/// to pass to a higher order function.
public func greaterOrEqual(self : Blob, other : Blob) : Bool {
  self >= other;
};

````

---

This file mirrors `src/Blob.mo` so AI tooling has immediate access to the canonical examples.
