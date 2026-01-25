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
  /// workspaceId -> (agentId, provider_name) -> encrypted_api_key
  public type ApiKeysMap = Map.Map<Nat, Map.Map<(Nat, Text), EncryptedApiKey>>;

  // Comparator for (Nat, Text) tuples
  public func compareNatTextTuple(a : (Nat, Text), b : (Nat, Text)) : Order.Order {
    switch (Nat.compare(a.0, b.0)) {
      case (#equal) { Text.compare(a.1, b.1) };
      case (other) { other };
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

  /// Get and decrypt API key for a specific workspace, agent, and provider
  ///
  /// @param apiKeys - The encrypted API keys map
  /// @param encryptionKey - 32-byte encryption key for this workspace
  /// @param workspaceId - The workspace ID
  /// @param agentId - The agent ID
  /// @param provider - The LLM provider
  /// @returns Decrypted API key text, or null if not found or decryption fails
  public func getApiKeyForWorkspaceAndAgent(
    apiKeys : ApiKeysMap,
    encryptionKey : [Nat8],
    workspaceId : Nat,
    agentId : Nat,
    provider : Types.LlmProvider,
  ) : ?Text {
    let providerName = providerToString(provider);
    let key = (agentId, providerName);

    switch (Map.get(apiKeys, Nat.compare, workspaceId)) {
      case (null) {
        null;
      };
      case (?workspaceKeyMap) {
        switch (Map.get(workspaceKeyMap, compareNatTextTuple, key)) {
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

  /// Encrypt and store an API key for an agent in a workspace
  ///
  /// @param apiKeys - The encrypted API keys map
  /// @param encryptionKey - 32-byte encryption key for this workspace
  /// @param workspaceId - The workspace ID
  /// @param agentId - The agent ID
  /// @param provider - The LLM provider
  /// @param apiKey - The plaintext API key to encrypt and store
  /// @returns Result
  public func storeApiKey(
    apiKeys : ApiKeysMap,
    encryptionKey : [Nat8],
    workspaceId : Nat,
    agentId : Nat,
    provider : Types.LlmProvider,
    apiKey : Text,
  ) : Result.Result<(), Text> {
    let providerName = providerToString(provider);
    let key = (agentId, providerName);

    // Convert API key to bytes and encrypt (nonce generated internally)
    let plaintextBytes = EncryptionService.textToBytes(apiKey);
    let encryptedBytes = EncryptionService.encrypt(encryptionKey, plaintextBytes, workspaceId);
    let encryptedBlob = Blob.fromArray(encryptedBytes);

    // Get or create the workspace's API key map
    let workspaceKeyMap = switch (Map.get(apiKeys, Nat.compare, workspaceId)) {
      case (null) {
        Map.empty<(Nat, Text), EncryptedApiKey>();
      };
      case (?existingMap) {
        existingMap;
      };
    };

    // Add the encrypted API key to the workspace's map
    Map.add(workspaceKeyMap, compareNatTextTuple, key, encryptedBlob);

    // Store the updated map back
    Map.add(apiKeys, Nat.compare, workspaceId, workspaceKeyMap);

    #ok(());
  };

  /// Get workspace's API key identifiers (without decrypting the keys)
  /// Returns list of (agentId, providerName) pairs
  ///
  /// @param apiKeys - The encrypted API keys map
  /// @param workspaceId - The workspace ID
  /// @returns List of (agentId, providerName) tuples
  public func getWorkspaceApiKeys(
    apiKeys : ApiKeysMap,
    workspaceId : Nat,
  ) : Result.Result<[(Nat, Text)], Text> {
    switch (Map.get(apiKeys, Nat.compare, workspaceId)) {
      case (null) {
        #ok([]);
      };
      case (?workspaceKeyMap) {
        #ok(Iter.toArray(Map.keys(workspaceKeyMap)));
      };
    };
  };

  /// Delete an API key for a specific agent and provider in a workspace
  ///
  /// @param apiKeys - The encrypted API keys map
  /// @param workspaceId - The workspace ID
  /// @param agentId - The agent ID
  /// @param provider - The LLM provider
  /// @returns Result
  public func deleteApiKey(
    apiKeys : ApiKeysMap,
    workspaceId : Nat,
    agentId : Nat,
    provider : Types.LlmProvider,
  ) : Result.Result<(), Text> {
    let providerName = providerToString(provider);
    let key = (agentId, providerName);

    switch (Map.get(apiKeys, Nat.compare, workspaceId)) {
      case (null) {
        #err("No API keys found for this workspace.");
      };
      case (?workspaceKeyMap) {
        // Check if the key exists before deleting
        switch (Map.get(workspaceKeyMap, compareNatTextTuple, key)) {
          case (null) {
            #err("No API key found for agent " # debug_show (agentId) # " with provider " # providerName # ".");
          };
          case (?_) {
            ignore Map.delete(workspaceKeyMap, compareNatTextTuple, key);
            Map.add(apiKeys, Nat.compare, workspaceId, workspaceKeyMap);
            #ok(());
          };
        };
      };
    };
  };
};
