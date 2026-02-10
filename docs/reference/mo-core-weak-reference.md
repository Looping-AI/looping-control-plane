# mo:core WeakReference module

Detailed reference for `mo:core/WeakReference`, preserving the exact wording, cautions, and examples from the upstream docs.

## Import

```motoko name=import
import WeakReference "mo:core/WeakReference";

```

## Overview

- Implements weak references to objects so they can be released by garbage collection.
- Not supported when compiling with classical persistence (`--legacy-persistence`).

## API

````motoko
public type WeakReference<T> = { ref : weak T };

/// Allocate a new weak reference to the given object.
///
/// The `obj` parameter is the object to allocate a weak reference for.
/// Returns a new weak reference pointing to the given object.
/// ```motoko include=import
/// let obj = { x = 1 };
/// let weakRef = WeakReference.allocate(obj);
/// ```
public func allocate<T>(obj : T) : WeakReference<T>;

/// Get the value that the weak reference is pointing to.
///
/// The `self` parameter is the weak reference pointing to the value the function returns.
/// The function returns the value that the weak reference is pointing to,
/// or `null` if the value has been collected by the garbage collector.
/// ```motoko include=import
/// let obj = { x = 1 };
/// let weakRef = WeakReference.allocate(obj);
/// let value = weakRef.get();
/// ```
public func get<T>(self : WeakReference<T>) : ?T;

/// Check if the weak reference is still alive.
///
/// The `self` parameter is the weak reference to check whether it is still alive.
/// Returns `true` if the weak reference is still alive, `false` otherwise.
/// False means that the value has been collected by the garbage collector.
/// ```motoko include=import
/// let obj = { x = 1 };
/// let weakRef = WeakReference.allocate(obj);
/// let isLive = weakRef.isLive();
/// assert isLive == true;
/// ```
public func isLive<T>(self : WeakReference<T>) : Bool;

````

---

This file mirrors `src/WeakReference.mo` so AI tooling has immediate access to the canonical examples.
