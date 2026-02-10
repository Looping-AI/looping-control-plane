# mo:core CertifiedData module

Detailed reference for `mo:core/CertifiedData`, preserving the exact wording, cautions, and examples from the upstream docs.

## Import

```motoko name=import
import CertifiedData "mo:core/CertifiedData";

```

## Overview

- The Internet Computer lets canisters store small, certified blobs during update calls so later query calls can fetch a certificate for that data.
- This module is a low-level API intended for advanced users/library authors; see the Internet Computer Functional Specification for end-to-end guidance.
- Certificates are only available while serving query calls; update or inter-canister contexts always return `null`.

## Set certified data

````motoko
/// Set the certified data.
///
/// Must be called from an update method, else traps.
/// Must be passed a blob of at most 32 bytes, else traps.
///
/// Example:
/// ```motoko no-repl
/// import CertifiedData "mo:core/CertifiedData";
/// import Blob "mo:core/Blob";
///
/// // Must be in an update call
///
/// let array : [Nat8] = [1, 2, 3];
/// let blob = Blob.fromArray(array);
/// CertifiedData.set(blob);
/// ```
///
/// See a full example on how to use certified variables here: https://github.com/dfinity/examples/tree/master/motoko/cert-var
///
public let set : (data : Blob) -> () = Prim.setCertifiedData;

````

## Retrieve the certificate

````motoko
/// Gets a certificate
///
/// Returns `null` if no certificate is available, e.g. when processing an
/// update call or inter-canister call. This returns a non-`null` value only
/// when processing a query call.
///
/// Example:
/// ```motoko no-repl
/// import CertifiedData "mo:core/CertifiedData";
/// // Must be in a query call
///
/// CertifiedData.getCertificate();
/// ```
/// See a full example on how to use certified variables here: https://github.com/dfinity/examples/tree/master/motoko/cert-var
///
public let getCertificate : () -> ?Blob = Prim.getCertificate;

````

---

This file mirrors `src/CertifiedData.mo` so AI tooling has immediate access to the canonical examples.
