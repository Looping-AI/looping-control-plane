/// Key Derivation Service
/// Derives encryption keys via Threshold Schnorr signatures with caching
///
/// Each Workspace gets a unique, deterministic encryption key derived from:
/// 1. Calling sign_with_schnorr with workspace ID as derivation path + message
/// 2. Hashing the signature with SHA256 to get a 32-byte key

import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Blob "mo:core/Blob";
import Map "mo:core/Map";
import Array "mo:core/Array";
import Sha256 "mo:sha2/Sha256";
import IC "mo:ic/Types";
import ICCall "mo:ic/Call";
import Types "../types";
import Constants "../constants";

module {
  // ============================================
  // Constants
  // ============================================

  /// Key name for local development
  public let KEY_NAME_LOCAL : Text = "key_1";

  /// Key name for mainnet test
  public let KEY_NAME_TEST : Text = "test_key_1";

  /// Key name for production
  public let KEY_NAME_PROD : Text = "key_1";

  /// Get the Schnorr key name based on environment
  public func getSchnorrKeyName(env : Types.Environment) : Text {
    switch (env) {
      case (#local) { KEY_NAME_LOCAL };
      case (#test) { KEY_NAME_LOCAL };
      case (#staging) { KEY_NAME_TEST };
      case (#production) { KEY_NAME_PROD };
    };
  };

  /// Static message used for key derivation
  /// The workspace ID in derivation_path makes each key unique
  private let KEY_DERIVATION_MESSAGE : Blob = "workspace_api_key_encryption_v1";

  // ============================================
  // Key Cache Type
  // ============================================

  /// Cache of derived encryption keys per Workspace
  /// This avoids repeated expensive Schnorr calls
  public type KeyCache = Map.Map<Nat, [Nat8]>;

  // ============================================
  // Helper Functions
  // ============================================

  /// Convert a Nat to a big-endian byte array (8 bytes)
  private func natToBytes(n : Nat) : [Nat8] {
    Array.tabulate<Nat8>(
      8,
      func(i : Nat) : Nat8 {
        // Shift right by (7-i)*8 bits and mask with 0xFF
        Nat8.fromNat((n / (256 ** (7 - i))) % 256);
      },
    );
  };

  // ============================================
  // Key Derivation Functions
  // ============================================

  /// Derive an encryption key for a Workspace using Schnorr signatures
  /// The key is deterministic: same workspace ID always produces same key
  ///
  /// Algorithm:
  /// 1. Call sign_with_schnorr with workspace ID as derivation path
  /// 2. Hash the signature with SHA256 to get a 32-byte key
  ///
  /// @param workspaceId - The workspace ID to derive a key for
  /// @returns A 32-byte encryption key as [Nat8]
  public func deriveKeyFromSchnorr(workspaceId : Nat) : async [Nat8] {
    let keyName = getSchnorrKeyName(Constants.ENVIRONMENT);

    // Convert workspace ID to bytes for derivation path
    let workspaceIdBytes = natToBytes(workspaceId);

    // Prepare the signing request
    let signArgs : IC.SignWithSchnorrArgs = {
      message = KEY_DERIVATION_MESSAGE;
      derivation_path = [Blob.fromArray(workspaceIdBytes)];
      key_id = {
        algorithm = #ed25519; // Ed25519 is simpler and sufficient for our purpose
        name = keyName;
      };
      aux = null; // No BIP341 tweak needed
    };

    // Call the management canister with automatically calculated cycles
    let { signature } = await ICCall.signWithSchnorr(signArgs);

    // Hash the signature to get a 32-byte key
    // This ensures uniform distribution and fixed length
    let signatureBytes = Blob.toArray(signature);
    Blob.toArray(Sha256.fromArray(#sha256, signatureBytes));
  };

  /// Look up a cached key or derive a new one
  /// Mutates the cache if key needs to be derived
  ///
  /// @param cache - Current key cache (will be mutated)
  /// @param workspaceId - The workspace ID to get/derive key for
  /// @returns The encryption key
  public func getOrDeriveKey(
    cache : KeyCache,
    workspaceId : Nat,
  ) : async [Nat8] {
    // Check if key exists in cache
    switch (Map.get(cache, Nat.compare, workspaceId)) {
      case (?key) {
        key;
      };
      case (null) {
        // Key not in cache, derive it
        let key = await deriveKeyFromSchnorr(workspaceId);

        // Add to cache
        Map.add(cache, Nat.compare, workspaceId, key);

        key;
      };
    };
  };

  /// Clear all entries from the cache
  /// Should be called monthly via Timer
  public func clearCache() : KeyCache {
    Map.empty<Nat, [Nat8]>();
  };

  /// Get cache size (for monitoring)
  public func getCacheSize(cache : KeyCache) : Nat {
    Map.size(cache);
  };
};
