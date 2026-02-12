# mo:core Bool module

Reference for `mo:core/Bool`, mirroring the upstream docs so Copilot sees the exact same examples.

## Import

```motoko name=import
import Bool "mo:core/Bool";

```

## Overview

- Boolean operators `and`/`or` short-circuit, but the helpers below are strict.
- Use these functions when higher-order APIs expect callbacks instead of infix operators.

## Logical operations

### `logicalAnd`

````motoko
/// Returns `a and b`.
///
/// Example:
/// ```motoko include=import
/// assert not Bool.logicalAnd(true, false);
/// assert Bool.logicalAnd(true, true);
/// ```
public func logicalAnd(self : Bool, other : Bool) : Bool = self and other;

````

### `logicalOr`

````motoko
/// Returns `a or b`.
///
/// Example:
/// ```motoko include=import
/// assert Bool.logicalOr(true, false);
/// assert Bool.logicalOr(false, true);
/// ```
public func logicalOr(self : Bool, other : Bool) : Bool = self or other;

````

### `logicalXor`

````motoko
/// Returns exclusive or of `a` and `b`, `a != b`.
///
/// Example:
/// ```motoko include=import
/// assert Bool.logicalXor(true, false);
/// assert not Bool.logicalXor(true, true);
/// assert not Bool.logicalXor(false, false);
/// ```
public func logicalXor(self : Bool, other : Bool) : Bool = self != other;

````

### `logicalNot`

````motoko
/// Returns `not bool`.
///
/// Example:
/// ```motoko include=import
/// assert Bool.logicalNot(false);
/// assert not Bool.logicalNot(true);
/// ```
public func logicalNot(self : Bool) : Bool = not self;

````

## Comparison helpers

### `equal`

````motoko
/// Returns `a == b`.
///
/// Example:
/// ```motoko include=import
/// assert Bool.equal(true, true);
/// assert not Bool.equal(true, false);
/// ```
public func equal(self : Bool, other : Bool) : Bool { self == other };

````

### `compare`

````motoko
/// Returns the ordering of `a` compared to `b`.
/// Returns `#less` if `a` is `false` and `b` is `true`,
/// `#equal` if `a` equals `b`,
/// and `#greater` if `a` is `true` and `b` is `false`.
///
/// Example:
/// ```motoko include=import
/// assert Bool.compare(true, false) == #greater;
/// assert Bool.compare(true, true) == #equal;
/// assert Bool.compare(false, true) == #less;
/// ```
public func compare(self : Bool, other : Bool) : Order.Order {
  if (self == other) #equal else if self #greater else #less;
};

````

### `toText`

````motoko
/// Returns a text value which is either `"true"` or `"false"` depending on the input value.
///
/// Example:
/// ```motoko include=import
/// assert Bool.toText(true) == "true";
/// assert Bool.toText(false) == "false";
/// ```
public func toText(self : Bool) : Text {
  if self "true" else "false";
};

````

## Enumeration

### `allValues`

````motoko
/// Returns an iterator over all possible boolean values (`true` and `false`).
///
/// Example:
/// ```motoko include=import
/// let iter = Bool.allValues();
/// assert iter.next() == ?true;
/// assert iter.next() == ?false;
/// assert iter.next() == null;
/// ```
public func allValues() : Iter.Iter<Bool> = object {
  var state : ?Bool = ?true;
  public func next() : ?Bool {
    switch state {
      case (?true) { state := ?false; ?true };
      case (?false) { state := null; ?false };
      case null { null };
    };
  };
};

````

---

This file mirrors `src/Bool.mo` so AI tooling has immediate access to the canonical examples.
