# mo:core Debug module

Detailed reference for `mo:core/Debug`, preserving the exact wording, cautions, and examples from the upstream docs.

## Import

```motoko name=import
import Debug "mo:core/Debug";

```

## Overview

- Provides utility functions for printing and marking incomplete code paths.
- On ICP networks, replicated execution logs go to the canister log; non-replicated query output is discarded.
- Outside ICP (interpreter, standalone Wasm), `Debug.print` writes to stdout.

## Printing helpers

````motoko
/// Prints `text` to output stream.
///
/// NOTE: When running on an ICP network, all output is written to the [canister log](https://internetcomputer.org/docs/current/developer-docs/smart-contracts/maintain/logs) with the exclusion of any output
/// produced during the execution of non-replicated queries and composite queries.
/// In other environments, like the interpreter and stand-alone wasm engines, the output is written to standard out.
///
/// ```motoko include=import
/// Debug.print "Hello New World!";
/// Debug.print(debug_show(4)) // Often used with `debug_show` to convert values to Text
/// ```
public func print(text : Text) {
  Prim.debugPrint(text);
};

````

## Mark incomplete code

````motoko
/// Mark incomplete code with the `todo()` function.
///
/// Each have calls are well-typed in all typing contexts, which
/// trap in all execution contexts.
///
/// ```motoko include=import
/// func doSomethingComplex() {
///   Debug.todo()
/// };
/// ```
public func todo() : None {
  Runtime.trap("Debug.todo()");
};

````

---

This file mirrors `src/Debug.mo` so AI tooling has immediate access to the canonical examples.
