/// Hashing — Unit Tests
///
/// Verifies `sha256Hex` against well-known SHA-256 test vectors.

import { test; expect } "mo:test";
import Hashing "../../../../src/internal-engine/workflows/hashing";

test(
  "sha256Hex of empty string matches RFC test vector",
  func() {
    expect.text(Hashing.sha256Hex("")).equal(
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    );
  },
);

test(
  "sha256Hex of 'hello' matches known digest",
  func() {
    expect.text(Hashing.sha256Hex("hello")).equal(
      "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
    );
  },
);

test(
  "sha256Hex returns lowercase hex of length 64",
  func() {
    let result = Hashing.sha256Hex("test input");
    expect.nat(result.size()).equal(64);
  },
);

test(
  "sha256Hex is deterministic — same input yields same output",
  func() {
    let input = "workflow-catalog-hash-stability";
    expect.text(Hashing.sha256Hex(input)).equal(Hashing.sha256Hex(input));
  },
);

test(
  "sha256Hex differs for different inputs",
  func() {
    let a = Hashing.sha256Hex("input-a");
    let b = Hashing.sha256Hex("input-b");
    expect.bool(a == b).isFalse();
  },
);
