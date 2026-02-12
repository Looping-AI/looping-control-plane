# mo:core Queue module

Detailed reference for `mo:core/Queue`, preserving the exact wording, cautions, and examples from the upstream docs.

## Import

```motoko name=import
import Queue "mo:core/Queue";

```

## Overview

- Mutable double-ended queue backed by a doubly-linked list.
- Supports FIFO (`pushBack`/`popFront`) and LIFO (`pushFront`/`popFront`) patterns.
- Runtime: `O(1)` for push/pop/peek, `O(n)` for iteration or `contains`; space `O(n)`.
- `toPure`/`fromPure` interoperate with the persistent `pure/Queue` (deprecated per M0235).

## Working with pure queues

````motoko
/// Converts a mutable queue to an immutable, purely functional queue.
///
/// Example:
/// ```motoko
/// import Queue "mo:core/Queue";
///
/// persistent actor {
///   let queue = Queue.fromIter<Nat>([1, 2, 3].values());
///   let pureQueue = Queue.toPure<Nat>(queue);
/// }
/// ```
///
/// Runtime: O(n)
/// Space: O(n)
/// `n` denotes the number of elements stored in the queue.
/// @deprecated M0235
public func toPure<T>(self : Queue<T>) : PureQueue.Queue<T>;

/// Converts an immutable, purely functional queue to a mutable queue.
///
/// Example:
/// ```motoko
/// import Queue "mo:core/Queue";
/// import PureQueue "mo:core/pure/Queue";
///
/// persistent actor {
///   let pureQueue = PureQueue.fromIter<Nat>([1, 2, 3].values());
///   let queue = Queue.fromPure<Nat>(pureQueue);
/// }
/// ```
///
/// Runtime: O(n)
/// Space: O(n)
/// `n` denotes the number of elements stored in the queue.
/// @deprecated M0235
public func fromPure<T>(pureQueue : PureQueue.Queue<T>) : Queue<T>;

````

## Construction and cloning

````motoko
/// Create a new empty mutable double-ended queue.
///
/// Example:
/// ```motoko
/// import Queue "mo:core/Queue";
///
/// persistent actor {
///   let queue = Queue.empty<Text>();
///   assert Queue.size(queue) == 0;
/// }
/// ```
///
/// Runtime: `O(1)`.
/// Space: `O(1)`.
public func empty<T>() : Queue<T>;

/// Creates a new queue with a single element.
///
/// Example:
/// ```motoko
/// import Queue "mo:core/Queue";
///
/// persistent actor {
///   let queue = Queue.singleton<Nat>(123);
///   assert Queue.size(queue) == 1;
/// }
/// ```
///
/// Runtime: O(1)
/// Space: O(1)
public func singleton<T>(element : T) : Queue<T>;

/// Removes all elements from the queue.
///
/// Example:
/// ```motoko
/// import Queue "mo:core/Queue";
///
/// persistent actor {
///   let queue = Queue.fromIter<Nat>([1, 2, 3].values());
///   Queue.clear(queue);
///   assert Queue.isEmpty(queue);
/// }
/// ```
///
/// Runtime: O(1)
/// Space: O(1)
public func clear<T>(self : Queue<T>);

/// Creates a deep copy of the queue.
///
/// Example:
/// ```motoko
/// import Queue "mo:core/Queue";
///
/// persistent actor {
///   let original = Queue.fromIter<Nat>([1, 2, 3].values());
///   let copy = Queue.clone(original);
///   Queue.clear(original);
///   assert Queue.size(original) == 0;
///   assert Queue.size(copy) == 3;
/// }
/// ```
///
/// Runtime: O(n)
/// Space: O(n)
/// `n` denotes the number of elements stored in the queue.
public func clone<T>(self : Queue<T>) : Queue<T>;

````

## Inspection helpers

```motoko
/// Returns the number of elements in the queue.
public func size<T>(self : Queue<T>) : Nat;

/// Returns `true` if the queue contains no elements.
public func isEmpty<T>(self : Queue<T>) : Bool;

/// Checks if an element exists in the queue using the provided equality function.
public func contains<T>(self : Queue<T>, equal : (implicit : (T, T) -> Bool), element : T) : Bool;

/// Returns the first element in the queue without removing it.
/// Returns null if the queue is empty.
public func peekFront<T>(self : Queue<T>) : ?T;

/// Returns the last element in the queue without removing it.
/// Returns null if the queue is empty.
public func peekBack<T>(self : Queue<T>) : ?T;

```

## Mutation helpers

```motoko
/// Adds an element to the front of the queue.
public func pushFront<T>(self : Queue<T>, element : T);

/// Adds an element to the back of the queue.
public func pushBack<T>(self : Queue<T>, element : T);

/// Removes and returns the first element in the queue.
/// Returns null if the queue is empty.
public func popFront<T>(self : Queue<T>) : ?T;

/// Removes and returns the last element in the queue.
/// Returns null if the queue is empty.
public func popBack<T>(self : Queue<T>) : ?T;

```

## Iteration

```motoko
/// Returns an iterator over the elements of the queue in front-to-back order.
public func values<T>(self : Queue<T>) : Iter.Iter<T>;

/// Creates a queue from an iterator of elements.
public func fromIter<T>(iter : Iter.Iter<T>) : Queue<T>;

/// Converts the queue to an array (front-first order).
public func toArray<T>(self : Queue<T>) : [T];

```

---

This file mirrors `src/Queue.mo` so AI tooling has immediate access to the canonical examples.
