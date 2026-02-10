`````markdown
# mo:core Region module

Detailed reference for `mo:core/Region`, preserving the exact wording, cautions, and examples from the upstream docs.

## Import

```motoko name=import
import Region "mo:core/Region";

```

## Overview

- Byte-level access to isolated virtual stable-memory regions that survive upgrades.
- Regions grow in 64KiB pages, never shrink, and remain allocated even if the handle becomes unreachable.
- Compatible with Motoko stable variables and `ExperimentalStableMemory` while supporting multiple isolated regions.
- Soft limit controlled by `--max-stable-pages`; actual IC stable memory may be larger to accommodate Motoko bookkeeping.
- Use `Text.decodeUtf8`/`Text.encodeUtf8` with `loadBlob`/`storeBlob` for textual data.

## Region handles

````motoko
/// A stateful handle to an isolated region of IC stable memory.
/// `Region` is a stable type and regions can be stored in stable variables.
/// @deprecated M0235
public type Region = Prim.Types.Region;

/// Allocate a new, isolated Region of size 0.
///
/// Example:
/// ```motoko no-repl include=import
/// persistent actor {
///   public func example() : async () {
///     let region = Region.new();
///     assert Region.size(region) == 0;
///   }
/// }
/// ```
public let new : () -> Region = Prim.regionNew;

/// Return a Nat identifying the given region.
/// May be used for equality, comparison and hashing.
/// NB: Regions returned by `new()` are numbered from 16
/// (regions 0..15 are currently reserved for internal use).
///
/// Example:
/// ```motoko no-repl include=import
/// persistent actor {
///   public func example() : async () {
///     let region = Region.new();
///     assert Region.id(region) == 16;
///   }
/// }
/// ```
public func id(self : Region) : Nat = Prim.regionId(self);

````

## Capacity management

````motoko
/// Current size of `region`, in pages (64KiB each). Initially 0 and preserved across upgrades.
///
/// Example:
/// ```motoko no-repl include=import
/// persistent actor {
///   public func example() : async () {
///     let region = Region.new();
///     let beforeSize = Region.size(region);
///     ignore Region.grow(region, 10);
///     let afterSize = Region.size(region);
///     assert afterSize - beforeSize == 10;
///   }
/// }
/// ```
public func size(self : Region) : (pages : Nat64) = Prim.regionSize(self);

/// Grow current `size` by `newPages` (each 64KiB).
/// Returns the previous size or `0xFFFF_FFFF_FFFF_FFFF` if insufficient pages remain.
/// New pages are zero-initialized; capped by `--max-stable-pages`.
///
/// Example:
/// ```motoko no-repl include=import
/// import Error "mo:core/Error";
///
/// persistent actor {
///   public func example() : async () {
///     let region = Region.new();
///     let beforeSize = Region.grow(region, 10);
///     if (beforeSize == 0xFFFF_FFFF_FFFF_FFFF) {
///       throw Error.reject("Out of memory");
///     };
///     let afterSize = Region.size(region);
///     assert afterSize - beforeSize == 10;
///   }
/// }
/// ```
public func grow(self : Region, newPages : Nat64) : (oldPages : Nat64) = Prim.regionGrow(self, newPages);

````

## Unsigned loads and stores

````motoko
/// Load a `Nat8` value from `offset`. Traps on out-of-bounds.
///
/// Example:
/// ```motoko no-repl include=import
/// persistent actor {
///   public func example() : async () {
///     let region = Region.new();
///     let offset : Nat64 = 0;
///     let value : Nat8 = 123;
///     Region.storeNat8(region, offset, value);
///     assert Region.loadNat8(region, offset) == 123;
///   }
/// }
/// ```
public func loadNat8(self : Region, offset : Nat64) : Nat8 = Prim.regionLoadNat8(self, offset);

/// Store a `Nat8` value at `offset`. Traps on out-of-bounds.
public func storeNat8(self : Region, offset : Nat64, value : Nat8) : () = Prim.regionStoreNat8(self, offset, value);

/// Load a `Nat16` value from `offset`. Traps on out-of-bounds.
public func loadNat16(self : Region, offset : Nat64) : Nat16 = Prim.regionLoadNat16(self, offset);

/// Store a `Nat16` value at `offset`. Traps on out-of-bounds.
public func storeNat16(self : Region, offset : Nat64, value : Nat16) : () = Prim.regionStoreNat16(self, offset, value);

/// Load a `Nat32` value from `offset`. Traps on out-of-bounds.
public func loadNat32(self : Region, offset : Nat64) : Nat32 = Prim.regionLoadNat32(self, offset);

/// Store a `Nat32` value at `offset`. Traps on out-of-bounds.
public func storeNat32(self : Region, offset : Nat64, value : Nat32) : () = Prim.regionStoreNat32(self, offset, value);

/// Load a `Nat64` value from `offset`. Traps on out-of-bounds.
public func loadNat64(self : Region, offset : Nat64) : Nat64 = Prim.regionLoadNat64(self, offset);

/// Store a `Nat64` value at `offset`. Traps on out-of-bounds.
public func storeNat64(self : Region, offset : Nat64, value : Nat64) : () = Prim.regionStoreNat64(self, offset, value);

````

## Signed loads and stores

```motoko
/// Load an `Int8` value from `offset`. Traps on out-of-bounds.
public func loadInt8(self : Region, offset : Nat64) : Int8 = Prim.regionLoadInt8(self, offset);

/// Store an `Int8` value at `offset`. Traps on out-of-bounds.
public func storeInt8(self : Region, offset : Nat64, value : Int8) : () = Prim.regionStoreInt8(self, offset, value);

/// Load an `Int16` value from `offset`. Traps on out-of-bounds.
public func loadInt16(self : Region, offset : Nat64) : Int16 = Prim.regionLoadInt16(self, offset);

/// Store an `Int16` value at `offset`. Traps on out-of-bounds.
public func storeInt16(self : Region, offset : Nat64, value : Int16) : () = Prim.regionStoreInt16(self, offset, value);

/// Load an `Int32` value from `offset`. Traps on out-of-bounds.
public func loadInt32(self : Region, offset : Nat64) : Int32 = Prim.regionLoadInt32(self, offset);

/// Store an `Int32` value at `offset`. Traps on out-of-bounds.
public func storeInt32(self : Region, offset : Nat64, value : Int32) : () = Prim.regionStoreInt32(self, offset, value);

/// Load an `Int64` value from `offset`. Traps on out-of-bounds.
public func loadInt64(self : Region, offset : Nat64) : Int64 = Prim.regionLoadInt64(self, offset);

/// Store an `Int64` value at `offset`. Traps on out-of-bounds.
public func storeInt64(self : Region, offset : Nat64, value : Int64) : () = Prim.regionStoreInt64(self, offset, value);

```

## Floating point and blobs

````motoko
/// Load a `Float` from `offset` (little-endian). Traps on out-of-bounds.
///
/// Example:
/// ```motoko no-repl include=import
/// persistent actor {
///   public func example() : async () {
///     let region = Region.new();
///     let offset : Nat64 = 0;
///     let value = 1.25;
///     Region.storeFloat(region, offset, value);
///     assert Region.loadFloat(region, offset) == 1.25;
///   }
/// }
/// ```
public func loadFloat(self : Region, offset : Nat64) : Float = Prim.regionLoadFloat(self, offset);

/// Store a `Float` at `offset`. Traps on out-of-bounds.
public func storeFloat(self : Region, offset : Nat64, value : Float) : () = Prim.regionStoreFloat(self, offset, value);

/// Load `size` bytes from `offset` as a `Blob`. Traps on out-of-bounds.
///
/// Example:
/// ```motoko no-repl include=import
/// import Blob "mo:core/Blob";
///
/// persistent actor {
///   public func example() : async () {
///     let region = Region.new();
///     let offset : Nat64 = 0;
///     let value = Blob.fromArray([1, 2, 3]);
///     let size = value.size();
///     Region.storeBlob(region, offset, value);
///     assert Blob.toArray(Region.loadBlob(region, offset, size)) == [1, 2, 3];
///   }
/// }
/// ```
public func loadBlob(self : Region, offset : Nat64, size : Nat) : Blob = Prim.regionLoadBlob(self, offset, size);

/// Store `blob.size()` bytes of `blob` beginning at `offset`. Traps on out-of-bounds.
public func storeBlob(self : Region, offset : Nat64, value : Blob) : () = Prim.regionStoreBlob(self, offset, value);

````

---

This file mirrors `src/Region.mo` so AI tooling has immediate access to the canonical examples.
`````
