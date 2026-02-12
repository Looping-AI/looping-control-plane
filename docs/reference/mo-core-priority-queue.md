# mo:core PriorityQueue module

Detailed reference for `mo:core/PriorityQueue`, preserving the exact wording, cautions, and examples from the upstream docs.

## Import

```motoko name=import
import PriorityQueue "mo:core/PriorityQueue";

```

## Overview

- Mutable priority queue backed by a binary heap stored inside `mo:core/List`.
- Always yields the element with the highest priority according to a caller-supplied comparison function.
- Typical uses: schedulers, simulations, search algorithms.
- Runtime: `O(log n)` for `push`/`pop`, `O(1)` for `peek`/`size`/`clear`; space `O(n)` with an additive `O(sqrt n)` overhead from the underlying `List`.

## Constructors and sizing

````motoko
/// Returns an empty priority queue.
///
/// Example:
/// ```motoko
/// import PriorityQueue "mo:core/PriorityQueue";
///
/// let pq = PriorityQueue.empty<Nat>();
/// assert PriorityQueue.isEmpty(pq);
/// ```
///
/// Runtime: `O(1)`. Space: `O(1)`.
public func empty<T>() : PriorityQueue<T> = {
  heap = List.empty<T>();
};

/// Returns a priority queue containing a single element.
///
/// Example:
/// ```motoko
/// import PriorityQueue "mo:core/PriorityQueue";
///
/// let pq = PriorityQueue.singleton<Nat>(42);
/// assert PriorityQueue.peek(pq) == ?42;
/// ```
///
/// Runtime: `O(1)`. Space: `O(1)`.
public func singleton<T>(element : T) : PriorityQueue<T> = {
  heap = List.singleton(element);
};

/// Returns the number of elements in the priority queue.
///
/// Runtime: `O(1)`.
public func size<T>(self : PriorityQueue<T>) : Nat = List.size(self.heap);

/// Returns `true` iff the priority queue is empty.
///
/// Example:
/// ```motoko
/// import PriorityQueue "mo:core/PriorityQueue";
/// import Nat "mo:core/Nat";
///
/// let pq = PriorityQueue.empty<Nat>();
/// assert PriorityQueue.isEmpty(pq);
/// PriorityQueue.push(pq, Nat.compare, 5);
/// assert not PriorityQueue.isEmpty(pq);
/// ```
///
/// Runtime: `O(1)`. Space: `O(1)`.
public func isEmpty<T>(self : PriorityQueue<T>) : Bool = List.isEmpty(self.heap);

/// Removes all elements from the priority queue.
///
/// Example:
/// ```motoko
/// import PriorityQueue "mo:core/PriorityQueue";
/// import Nat "mo:core/Nat";
///
///
/// let pq = PriorityQueue.empty<Nat>();
/// PriorityQueue.push(pq, Nat.compare, 5);
/// PriorityQueue.push(pq, Nat.compare, 10);
/// assert not PriorityQueue.isEmpty(pq);
/// PriorityQueue.clear(pq);
/// assert PriorityQueue.isEmpty(pq);
/// ```
///
/// Runtime: `O(1)`. Space: `O(1)`.
public func clear<T>(self : PriorityQueue<T>) = List.clear(self.heap);

````

## Core operations

````motoko
/// Inserts a new element into the priority queue.
///
/// `compare` – comparison function that defines priority ordering.
///
/// Example:
/// ```motoko
/// import PriorityQueue "mo:core/PriorityQueue";
/// import Nat "mo:core/Nat";
///
/// let pq = PriorityQueue.empty<Nat>();
/// PriorityQueue.push(pq, Nat.compare, 5);
/// PriorityQueue.push(pq, Nat.compare, 10);
/// assert PriorityQueue.peek(pq) == ?10;
/// ```
///
/// Runtime: `O(log n)`. Space: `O(1)`.
public func push<T>(self : PriorityQueue<T>, compare : (implicit : (T, T) -> Order.Order), element : T);

/// Returns the element with the highest priority, without removing it.
/// Returns `null` if the queue is empty.
///
/// Example:
/// ```motoko
/// import PriorityQueue "mo:core/PriorityQueue";
///
/// let pq = PriorityQueue.singleton<Nat>(42);
/// assert PriorityQueue.peek(pq) == ?42;
/// ```
///
/// Runtime: `O(1)`. Space: `O(1)`.
public func peek<T>(self : PriorityQueue<T>) : ?T = List.get(self.heap, 0);

/// Removes and returns the element with the highest priority.
/// Returns `null` if the queue is empty.
///
/// `compare` – comparison function that defines priority ordering.
///
/// Example:
/// ```motoko
/// import PriorityQueue "mo:core/PriorityQueue";
/// import Nat "mo:core/Nat";
///
/// let pq = PriorityQueue.empty<Nat>();
/// PriorityQueue.push(pq, Nat.compare, 5);
/// PriorityQueue.push(pq, Nat.compare, 10);
/// assert PriorityQueue.pop(pq, Nat.compare) == ?10;
/// ```
///
/// Runtime: `O(log n)`. Space: `O(1)`.
public func pop<T>(self : PriorityQueue<T>, compare : (implicit : (T, T) -> Order.Order)) : ?T;

````

---

This file mirrors `src/PriorityQueue.mo` so AI tooling has immediate access to the canonical examples.
