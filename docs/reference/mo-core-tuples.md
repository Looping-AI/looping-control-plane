# mo:core Tuples module

Detailed reference for `mo:core/Tuples`, preserving the exact wording, cautions, and examples from the upstream docs.

## Import

```motoko name=import
import { Tuple2; Tuple3; Tuple4 } "mo:core/Tuples";

```

## Overview

- Utility modules for tuples of size 2–4: swapping, text conversion, equality, and lexicographic compare helpers.
- Also exposes factory helpers (`makeToText`, `makeEqual`, `makeCompare`) to reuse formatting/comparison logic.

## Tuple2 helpers

```motoko
public module Tuple2 {
  /// Swaps the elements of a tuple.
  public func swap<A, B>((a, b) : (A, B)) : (B, A);

  /// Creates a textual representation of a tuple for debugging purposes.
  public func toText<A, B>(self : (A, B), toTextA : A -> Text, toTextB : B -> Text) : Text;

  /// Compares two tuples for equality.
  public func equal<A, B>(self : (A, B), other : (A, B), aEqual : (A, A) -> Bool, bEqual : (B, B) -> Bool) : Bool;

  /// Compares two tuples lexicographically.
  public func compare<A, B>(self : (A, B), other : (A, B), aCompare : (A, A) -> Types.Order, bCompare : (B, B) -> Types.Order) : Types.Order;

  /// Creates reusable `toText`, `equal`, and `compare` helpers for tuple elements.
  public func makeToText<A, B>(toTextA : A -> Text, toTextB : B -> Text) : ((A, B)) -> Text;
  public func makeEqual<A, B>(aEqual : (A, A) -> Bool, bEqual : (B, B) -> Bool) : ((A, B), (A, B)) -> Bool;
  public func makeCompare<A, B>(aCompare : (A, A) -> Types.Order, bCompare : (B, B) -> Types.Order) : ((A, B), (A, B)) -> Types.Order;
};

```

## Tuple3 helpers

```motoko
public module Tuple3 {
  /// Creates a textual representation of a 3-tuple for debugging purposes.
  public func toText<A, B, C>(self : (A, B, C), toTextA : A -> Text, toTextB : B -> Text, toTextC : C -> Text) : Text;

  /// Compares two 3-tuples for equality.
  public func equal<A, B, C>(self : (A, B, C), other : (A, B, C), aEqual : (A, A) -> Bool, bEqual : (B, B) -> Bool, cEqual : (C, C) -> Bool) : Bool;

  /// Compares two 3-tuples lexicographically.
  public func compare<A, B, C>(self : (A, B, C), other : (A, B, C), aCompare : (A, A) -> Types.Order, bCompare : (B, B) -> Types.Order, cCompare : (C, C) -> Types.Order) : Types.Order;

  /// Factory helpers mirroring the 2-tuple module.
  public func makeToText<A, B, C>(toTextA : A -> Text, toTextB : B -> Text, toTextC : C -> Text) : ((A, B, C)) -> Text;
  public func makeEqual<A, B, C>(aEqual : (A, A) -> Bool, bEqual : (B, B) -> Bool, cEqual : (C, C) -> Bool) : ((A, B, C), (A, B, C)) -> Bool;
  public func makeCompare<A, B, C>(aCompare : (A, A) -> Types.Order, bCompare : (B, B) -> Types.Order, cCompare : (C, C) -> Types.Order) : ((A, B, C), (A, B, C)) -> Types.Order;
};

```

## Tuple4 helpers

```motoko
public module Tuple4 {
  /// Creates a textual representation of a 4-tuple for debugging purposes.
  public func toText<A, B, C, D>(self : (A, B, C, D), toTextA : A -> Text, toTextB : B -> Text, toTextC : C -> Text, toTextD : D -> Text) : Text;

  /// Compares two 4-tuples for equality.
  public func equal<A, B, C, D>(self : (A, B, C, D), other : (A, B, C, D), aEqual : (A, A) -> Bool, bEqual : (B, B) -> Bool, cEqual : (C, C) -> Bool, dEqual : (D, D) -> Bool) : Bool;

  /// Compares two 4-tuples lexicographically.
  public func compare<A, B, C, D>(self : (A, B, C, D), other : (A, B, C, D), aCompare : (A, A) -> Types.Order, bCompare : (B, B) -> Types.Order, cCompare : (C, C) -> Types.Order, dCompare : (D, D) -> Types.Order) : Types.Order;

  /// Factory helpers mirroring Tuple2/Tuple3.
  public func makeToText<A, B, C, D>(toTextA : A -> Text, toTextB : B -> Text, toTextC : C -> Text, toTextD : D -> Text) : ((A, B, C, D)) -> Text;
  public func makeEqual<A, B, C, D>(aEqual : (A, A) -> Bool, bEqual : (B, B) -> Bool, cEqual : (C, C) -> Bool, dEqual : (D, D) -> Bool) : ((A, B, C, D), (A, B, C, D)) -> Bool;
  public func makeCompare<A, B, C, D>(aCompare : (A, A) -> Types.Order, bCompare : (B, B) -> Types.Order, cCompare : (C, C) -> Types.Order, dCompare : (D, D) -> Types.Order) : ((A, B, C, D), (A, B, C, D)) -> Types.Order;
};

```

---

This file mirrors `src/Tuples.mo` so AI tooling has immediate access to the canonical examples.
