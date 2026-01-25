import Map "mo:core/Map";
import Text "mo:core/Text";
import Order "mo:core/Order";
import Nat "mo:core/Nat";
import Result "mo:core/Result";
import Iter "mo:core/Iter";
import Blob "mo:core/Blob";
import Types "../types";
import EncryptionService "./encryption-service";

module {
  /// Type alias for encrypted API key storage
  /// The Blob contains: [nonce (8 bytes)] [ciphertext]
  public type EncryptedApiKey = Blob;

  /// Type alias for the API keys map
  /// workspaceId -> provider -> encrypted_api_key
  public type ApiKeysMap = Map.Map<Nat, Map.Map<Types.LlmProvider, EncryptedApiKey>>;

  /// Comparator for LlmProvider enum
  public func compareProvider(a : Types.LlmProvider, b : Types.LlmProvider) : Order.Order {
    let aVal = providerToNat(a);
    let bVal = providerToNat(b);
    Nat.compare(aVal, bVal);
  };

  /// Convert LlmProvider variant to Nat for comparison
  private func providerToNat(provider : Types.LlmProvider) : Nat {
    switch (provider) {
      case (#openai) { 0 };
      case (#llmcanister) { 1 };
      case (#groq) { 2 };
    };
  };

  /// Convert LlmProvider variant to string representation
  private func providerToString(provider : Types.LlmProvider) : Text {
    switch (provider) {
      case (#openai) { "openai" };
      case (#llmcanister) { "llmcanister" };
      case (#groq) { "groq" };
    };
  };

  /// Get and decrypt API key for a specific workspace and provider
  ///
  /// @param apiKeys - The encrypted API keys map
  /// @param encryptionKey - 32-byte encryption key for this workspace
  /// @param workspaceId - The workspace ID
  /// @param provider - The LLM provider
  /// @returns Decrypted API key text, or null if not found or decryption fails
  public func getApiKey(
    apiKeys : ApiKeysMap,
    encryptionKey : [Nat8],
    workspaceId : Nat,
    provider : Types.LlmProvider,
  ) : ?Text {
    switch (Map.get(apiKeys, Nat.compare, workspaceId)) {
      case (null) {
        null;
      };
      case (?workspaceKeyMap) {
        switch (Map.get(workspaceKeyMap, compareProvider, provider)) {
          case (null) { null };
          case (?encryptedBlob) {
            // Decrypt the API key
            let encryptedBytes = Blob.toArray(encryptedBlob);
            let decryptedBytes = EncryptionService.decrypt(encryptionKey, encryptedBytes);
            EncryptionService.bytesToText(decryptedBytes);
          };
        };
      };
    };
  };

  /// Encrypt and store an API key for a provider in a workspace
  ///
  /// @param apiKeys - The encrypted API keys map
  /// @param encryptionKey - 32-byte encryption key for this workspace
  /// @param workspaceId - The workspace ID
  /// @param provider - The LLM provider
  /// @param apiKey - The plaintext API key to encrypt and store
  /// @returns Result
  public func storeApiKey(
    apiKeys : ApiKeysMap,
    encryptionKey : [Nat8],
    workspaceId : Nat,
    provider : Types.LlmProvider,
    apiKey : Text,
  ) : Result.Result<(), Text> {
    // Convert API key to bytes and encrypt (nonce generated internally)
    let plaintextBytes = EncryptionService.textToBytes(apiKey);
    let encryptedBytes = EncryptionService.encrypt(encryptionKey, plaintextBytes, workspaceId);
    let encryptedBlob = Blob.fromArray(encryptedBytes);

    // Get or create the workspace's API key map
    let workspaceKeyMap = switch (Map.get(apiKeys, Nat.compare, workspaceId)) {
      case (null) {
        Map.empty<Types.LlmProvider, EncryptedApiKey>();
      };
      case (?existingMap) {
        existingMap;
      };
    };

    // Add the encrypted API key to the workspace's map
    Map.add(workspaceKeyMap, compareProvider, provider, encryptedBlob);

    // Store the updated map back
    Map.add(apiKeys, Nat.compare, workspaceId, workspaceKeyMap);

    #ok(());
  };

  /// Get workspace's API key identifiers (without decrypting the keys)
  /// Returns list of providers that have stored keys
  ///
  /// @param apiKeys - The encrypted API keys map
  /// @param workspaceId - The workspace ID
  /// @returns List of LlmProvider values
  public func getWorkspaceApiKeys(
    apiKeys : ApiKeysMap,
    workspaceId : Nat,
  ) : Result.Result<[Types.LlmProvider], Text> {
    switch (Map.get(apiKeys, Nat.compare, workspaceId)) {
      case (null) {
        #ok([]);
      };
      case (?workspaceKeyMap) {
        #ok(Iter.toArray(Map.keys(workspaceKeyMap)));
      };
    };
  };

  /// Delete an API key for a specific provider in a workspace
  ///
  /// @param apiKeys - The encrypted API keys map
  /// @param workspaceId - The workspace ID
  /// @param provider - The LLM provider
  /// @returns Result
  public func deleteApiKey(
    apiKeys : ApiKeysMap,
    workspaceId : Nat,
    provider : Types.LlmProvider,
  ) : Result.Result<(), Text> {
    switch (Map.get(apiKeys, Nat.compare, workspaceId)) {
      case (null) {
        #err("No API keys found for this workspace.");
      };
      case (?workspaceKeyMap) {
        // Check if the key exists before deleting
        switch (Map.get(workspaceKeyMap, compareProvider, provider)) {
          case (null) {
            #err("No API key found for provider " # providerToString(provider) # ".");
          };
          case (?_) {
            ignore Map.delete(workspaceKeyMap, compareProvider, provider);
            Map.add(apiKeys, Nat.compare, workspaceId, workspaceKeyMap);
            #ok(());
          };
        };
      };
    };
  };
};
