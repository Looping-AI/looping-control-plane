# mo:core Order module

Detailed reference for `mo:core/Order`, preserving the exact wording, cautions, and examples from the upstream docs.

## Import

```motoko name=import
import Order "mo:core/Order";

```

## Overview

- Small helper utilities for working with the `Types.Order` variant (`#less`, `#equal`, `#greater`).
- Provides predicate helpers, equality checks, and an iterator over all possible values.

## API

```motoko
/// A type to represent an order.
public type Order = Types.Order;

/// Check if an order is #less.
public func isLess(self : Order) : Bool {
  switch self {
    case (#less) { true };
    case _ { false };
  };
};

/// Check if an order is #equal.
public func isEqual(self : Order) : Bool {
  switch self {
    case (#equal) { true };
    case _ { false };
  };
};

/// Check if an order is #greater.
public func isGreater(self : Order) : Bool {
  switch self {
    case (#greater) { true };
    case _ { false };
  };
};

/// Returns true if only if  `order1` and `order2` are the same.
public func equal(self : Order, other : Order) : Bool {
  switch (self, other) {
    case (#less, #less) { true };
    case (#equal, #equal) { true };
    case (#greater, #greater) { true };
    case _ { false };
  };
};

/// Returns an iterator that yields all possible `Order` values:
/// `#less`, `#equal`, `#greater`.
public func allValues() : Types.Iter<Order> {
  var nextState : ?Order = ?#less;
  {
    next = func() : ?Order {
      let state = nextState;
      switch state {
        case (?#less) { nextState := ?#equal };
        case (?#equal) { nextState := ?#greater };
        case (?#greater) { nextState := null };
        case (null) {};
      };
      state;
    };
  };
};

```

---

This file mirrors `src/Order.mo` so AI tooling has immediate access to the canonical examples.
