# mo:core Option module

Concise reference for `mo:core/Option`, keeping the upstream documentation text and examples intact so you can rely on the same snippets Copilot/Claude see inside the Motoko core library.

## Import

```motoko name=import
import Option "mo:core/Option";

```

## Overview

Optional values behave like typed `null`s. Many helpers below wrap the common pattern-matching idioms.

## Access helpers

### `get`

```motoko
/// Unwraps an optional value, with a default value, i.e. `get(?x, d) = x` and
/// `get(null, d) = d`.
public func get<T>(self : ?T, default : T) : T;

```

### `getMapped`

```motoko
/// Unwraps an optional value using a function, or returns the default, i.e.
/// `option(?x, f, d) = f x` and `option(null, f, d) = d`.
public func getMapped<T, R>(self : ?T, f : T -> R, default : R) : R;

```

### `unwrap`

```motoko
/// Unwraps an optional value, i.e. `unwrap(?x) = x`.
///
/// `Option.unwrap()` fails if the argument is null. Consider using a `switch` or `do?` expression instead.
public func unwrap<T>(self : ?T) : T;

```

## Mapping and chaining

### `map`

````motoko
/// Applies a function to the wrapped value. `null`'s are left untouched.
/// ```motoko
/// import Option "mo:core/Option";
/// assert Option.map<Nat, Nat>(?42, func x = x + 1) == ?43;
/// assert Option.map<Nat, Nat>(null, func x = x + 1) == null;
/// ```
public func map<T, R>(self : ?T, f : T -> R) : ?R;

````

### `forEach`

````motoko
/// Applies a function to the wrapped value, but discards the result. Use
/// `forEach` if you're only interested in the side effect `f` produces.
///
/// ```motoko
/// import Option "mo:core/Option";
/// var counter : Nat = 0;
/// Option.forEach(?5, func (x : Nat) { counter += x });
/// assert counter == 5;
/// Option.forEach(null, func (x : Nat) { counter += x });
/// assert counter == 5;
/// ```
public func forEach<T>(self : ?T, f : T -> ());

````

### `apply`

```motoko
/// Applies an optional function to an optional value. Returns `null` if at
/// least one of the arguments is `null`.
public func apply<T, R>(self : ?T, f : ?(T -> R)) : ?R;

```

### `chain`

```motoko
/// Applies a function to an optional value. Returns `null` if the argument is
/// `null`, or the function returns `null`.
public func chain<T, R>(self : ?T, f : T -> ?R) : ?R;

```

### `flatten`

````motoko
/// Given an optional optional value, removes one layer of optionality.
/// ```motoko
/// import Option "mo:core/Option";
/// assert Option.flatten(?(?(42))) == ?42;
/// assert Option.flatten(?(null)) == null;
/// assert Option.flatten(null) == null;
/// ```
public func flatten<T>(self : ??T) : ?T;

````

## Constructors and predicates

````motoko
/// Creates an optional value from a definite value.
/// ```motoko
/// import Option "mo:core/Option";
/// assert Option.some(42) == ?42;
/// ```
public func some<T>(self : T) : ?T

/// Returns true if the argument is not `null`, otherwise returns false.
public func isSome(self : ?Any) : Bool

/// Returns true if the argument is `null`, otherwise returns false.
public func isNull(self : ?Any) : Bool;

````

## Equality, comparison, and display

```motoko
/// Returns true if the optional arguments are equal according to the equality function provided, otherwise returns false.
public func equal<T>(self : ?T, other : ?T, eq : (implicit : (equal : (T, T) -> Bool))) : Bool

/// Compares two optional values using the provided comparison function.
///
/// Returns:
/// - `#equal` if both values are `null`,
/// - `#less` if the first value is `null` and the second is not,
/// - `#greater` if the first value is not `null` and the second is,
/// - the result of the comparison function when both values are not `null`.
public func compare<T>(self : ?T, other : ?T, compare : (implicit : (T, T) -> Types.Order)) : Types.Order

/// Returns the textural representation of an optional value for debugging purposes.
public func toText<T>(self : ?T, toText : (implicit : T -> Text)) : Text;

```

---

This mirrors the upstream Option docs so downstream tools stay in sync with the authoritative examples.
