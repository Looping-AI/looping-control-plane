import Map "mo:core/Map";
import Text "mo:core/Text";
import Order "mo:core/Order";
import Nat "mo:core/Nat";
import Result "mo:core/Result";
import Iter "mo:core/Iter";
import Blob "mo:core/Blob";
import Types "../types";
import Encryption "../utilities/encryption";

module {
  /// Type alias for encrypted secret storage
  /// The Blob contains: [nonce (8 bytes)] [ciphertext]
  public type EncryptedSecret = Blob;

  /// Type alias for the secrets map
  /// workspaceId -> secretId -> encrypted_secret
  public type SecretsMap = Map.Map<Nat, Map.Map<Types.SecretId, EncryptedSecret>>;

  /// Comparator for SecretId enum.
  /// Uses the stable string representation so that the BTree ordering is
  /// independent of the variant declaration order — adding or reordering
  /// variants in the future will never silently corrupt stored keys.
  public func compareSecretId(a : Types.SecretId, b : Types.SecretId) : Order.Order {
    Text.compare(secretIdToString(a), secretIdToString(b));
  };

  /// Convert SecretId variant to string representation
  private func secretIdToString(id : Types.SecretId) : Text {
    switch (id) {
      case (#groqApiKey) { "groqApiKey" };
      case (#openaiApiKey) { "openaiApiKey" };
      case (#slackBotToken) { "slackBotToken" };
      case (#slackSigningSecret) { "slackSigningSecret" };
    };
  };

  /// Get and decrypt a secret for a specific workspace and secret ID
  ///
  /// @param secrets - The encrypted secrets map
  /// @param encryptionKey - 32-byte encryption key for this workspace
  /// @param workspaceId - The workspace ID
  /// @param secretId - The secret identifier
  /// @returns Decrypted secret text, or null if not found or decryption fails
  public func getSecret(
    secrets : SecretsMap,
    encryptionKey : [Nat8],
    workspaceId : Nat,
    secretId : Types.SecretId,
  ) : ?Text {
    switch (Map.get(secrets, Nat.compare, workspaceId)) {
      case (null) {
        null;
      };
      case (?workspaceSecrets) {
        switch (Map.get(workspaceSecrets, compareSecretId, secretId)) {
          case (null) { null };
          case (?encryptedBlob) {
            // Decrypt the secret
            let encryptedBytes = Blob.toArray(encryptedBlob);
            let decryptedBytes = Encryption.decrypt(encryptionKey, encryptedBytes);
            Encryption.bytesToText(decryptedBytes);
          };
        };
      };
    };
  };

  /// Get and decrypt a secret from an already workspace-scoped secrets map.
  ///
  /// Use this when the caller has already extracted the workspace's secrets via
  /// `Map.get(secrets, Nat.compare, workspaceId)` — avoids passing the full
  /// org-wide map into lower-level modules.
  ///
  /// @param workspaceSecrets - The workspace's own secrets map (or null if none stored)
  /// @param encryptionKey - 32-byte encryption key for this workspace
  /// @param secretId - The secret identifier
  /// @returns Decrypted secret text, or null if not found or decryption fails
  public func getSecretScoped(
    workspaceSecrets : ?Map.Map<Types.SecretId, EncryptedSecret>,
    encryptionKey : [Nat8],
    secretId : Types.SecretId,
  ) : ?Text {
    switch (workspaceSecrets) {
      case (null) { null };
      case (?wsSecrets) {
        switch (Map.get(wsSecrets, compareSecretId, secretId)) {
          case (null) { null };
          case (?encryptedBlob) {
            let encryptedBytes = Blob.toArray(encryptedBlob);
            let decryptedBytes = Encryption.decrypt(encryptionKey, encryptedBytes);
            Encryption.bytesToText(decryptedBytes);
          };
        };
      };
    };
  };

  /// Encrypt and store a secret for a workspace
  ///
  /// @param secrets - The encrypted secrets map
  /// @param encryptionKey - 32-byte encryption key for this workspace
  /// @param workspaceId - The workspace ID
  /// @param secretId - The secret identifier
  /// @param secret - The plaintext secret to encrypt and store
  /// @returns Result
  public func storeSecret(
    secrets : SecretsMap,
    encryptionKey : [Nat8],
    workspaceId : Nat,
    secretId : Types.SecretId,
    secret : Text,
  ) : Result.Result<(), Text> {
    // Convert secret to bytes and encrypt (nonce generated internally)
    let plaintextBytes = Encryption.textToBytes(secret);
    let encryptedBytes = Encryption.encrypt(encryptionKey, plaintextBytes, workspaceId);
    let encryptedBlob = Blob.fromArray(encryptedBytes);

    // Get or create the workspace's secrets map
    let workspaceSecrets = switch (Map.get(secrets, Nat.compare, workspaceId)) {
      case (null) {
        Map.empty<Types.SecretId, EncryptedSecret>();
      };
      case (?existingMap) {
        existingMap;
      };
    };

    // Add the encrypted secret to the workspace's map
    Map.add(workspaceSecrets, compareSecretId, secretId, encryptedBlob);

    // Store the updated map back
    Map.add(secrets, Nat.compare, workspaceId, workspaceSecrets);

    #ok(());
  };

  /// Get workspace's stored secret identifiers (without decrypting)
  /// Returns list of SecretId values that have stored secrets
  ///
  /// @param secrets - The encrypted secrets map
  /// @param workspaceId - The workspace ID
  /// @returns List of SecretId values
  public func getWorkspaceSecrets(
    secrets : SecretsMap,
    workspaceId : Nat,
  ) : Result.Result<[Types.SecretId], Text> {
    switch (Map.get(secrets, Nat.compare, workspaceId)) {
      case (null) {
        #ok([]);
      };
      case (?workspaceSecrets) {
        #ok(Iter.toArray(Map.keys(workspaceSecrets)));
      };
    };
  };

  /// Delete a secret for a specific secret ID in a workspace
  ///
  /// @param secrets - The encrypted secrets map
  /// @param workspaceId - The workspace ID
  /// @param secretId - The secret identifier
  /// @returns Result
  public func deleteSecret(
    secrets : SecretsMap,
    workspaceId : Nat,
    secretId : Types.SecretId,
  ) : Result.Result<(), Text> {
    switch (Map.get(secrets, Nat.compare, workspaceId)) {
      case (null) {
        #err("No secrets found for this workspace.");
      };
      case (?workspaceSecrets) {
        // Check if the secret exists before deleting
        switch (Map.get(workspaceSecrets, compareSecretId, secretId)) {
          case (null) {
            #err("No secret found for " # secretIdToString(secretId) # ".");
          };
          case (?_) {
            ignore Map.delete(workspaceSecrets, compareSecretId, secretId);
            Map.add(secrets, Nat.compare, workspaceId, workspaceSecrets);
            #ok(());
          };
        };
      };
    };
  };
};
