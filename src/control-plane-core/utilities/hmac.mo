/// HMAC-SHA256 Implementation
///
/// Implements HMAC (Hash-based Message Authentication Code) using SHA256
/// as specified in RFC 2104: H((key XOR opad) || H((key XOR ipad) || message))
///
/// Used for Slack webhook signature verification.

import Blob "mo:core/Blob";
import Array "mo:core/Array";
import Nat8 "mo:core/Nat8";
import VarArray "mo:core/VarArray";
import Sha256 "mo:sha2/Sha256";

module {

  // HMAC constants as defined in RFC 2104
  let BLOCK_SIZE : Nat = 64; // SHA-256 block size in bytes
  let INNER_PAD : Nat8 = 0x36;
  let OUTER_PAD : Nat8 = 0x5c;

  /// Compute HMAC-SHA256
  ///
  /// @param key - Secret key as bytes
  /// @param message - Message to authenticate as bytes
  /// @returns HMAC-SHA256 digest as Blob (32 bytes)
  public func compute(key : [Nat8], message : [Nat8]) : Blob {
    // Step 1: Prepare key - pad or hash to block size (mutable, reused for both pads)
    let paddedKey = prepareKey(key);

    // Step 2: XOR key with inner pad (K ⊕ ipad)
    xorKeyWithPad(paddedKey, INNER_PAD);

    // Step 3: Inner hash = SHA256((K ⊕ ipad) || message)
    let innerDigest = Sha256.Digest(#sha256);
    innerDigest.writeArray(Array.fromVarArray(paddedKey));
    innerDigest.writeArray(message);
    let innerHash = Blob.toArray(innerDigest.sum());

    // Step 4: XOR key with (ipad ⊕ opad) to get (K ⊕ opad) — reuses the same mutable array
    xorKeyWithPad(paddedKey, INNER_PAD ^ OUTER_PAD);

    // Step 5: Outer hash = SHA256((K ⊕ opad) || innerHash)
    let outerDigest = Sha256.Digest(#sha256);
    outerDigest.writeArray(Array.fromVarArray(paddedKey));
    outerDigest.writeArray(innerHash);
    outerDigest.sum();
  };

  /// Prepares the key for HMAC by padding or hashing as needed.
  /// Keys longer than block size are hashed; shorter keys are zero-padded.
  private func prepareKey(key : [Nat8]) : [var Nat8] {
    let paddedKey = VarArray.repeat<Nat8>(0, BLOCK_SIZE);

    if (key.size() > BLOCK_SIZE) {
      let hashedKey = Sha256.fromArray(#sha256, key);
      for (i in hashedKey.keys()) {
        paddedKey[i] := hashedKey[i];
      };
    } else {
      for (i in key.keys()) {
        paddedKey[i] := key[i];
      };
    };

    paddedKey;
  };

  /// XORs each byte of the key with the given pad value in-place.
  private func xorKeyWithPad(key : [var Nat8], pad : Nat8) {
    for (i in key.keys()) {
      key[i] ^= pad;
    };
  };

  /// Convert bytes to lowercase hex string
  public func bytesToHex(bytes : Blob) : Text {
    let arr = Blob.toArray(bytes);
    var hex = "";
    for (byte in arr.vals()) {
      hex #= nat8ToHexChar(byte >> 4);
      hex #= nat8ToHexChar(byte & 0x0F);
    };
    hex;
  };

  // Internal helpers

  private func nat8ToHexChar(n : Nat8) : Text {
    let chars = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"];
    chars[Nat8.toNat(n)];
  };
};
