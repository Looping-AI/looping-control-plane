import { test; suite; expect } "mo:test";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Text "mo:core/Text";
import Result "mo:core/Result";
import ApiKeysService "../../../../src/open-org-backend/services/api-keys-service";

// Test key (32 bytes) - simulates a SHA256-hashed Schnorr signature
let testKey : [Nat8] = [
  0x00,
  0x01,
  0x02,
  0x03,
  0x04,
  0x05,
  0x06,
  0x07,
  0x08,
  0x09,
  0x0A,
  0x0B,
  0x0C,
  0x0D,
  0x0E,
  0x0F,
  0x10,
  0x11,
  0x12,
  0x13,
  0x14,
  0x15,
  0x16,
  0x17,
  0x18,
  0x19,
  0x1A,
  0x1B,
  0x1C,
  0x1D,
  0x1E,
  0x1F,
];

func resultToText(r : Result.Result<(), Text>) : Text {
  switch (r) {
    case (#ok _) { "#ok" };
    case (#err e) { "#err(" # e # ")" };
  };
};

func resultEqual(r1 : Result.Result<(), Text>, r2 : Result.Result<(), Text>) : Bool {
  r1 == r2;
};

suite(
  "ApiKeysService",
  func() {
    test(
      "storeApiKey stores an API key for a workspace and provider",
      func() {
        let workspaceId = 0;
        var apiKeys = Map.empty<Nat, Map.Map<{ #openai; #llmcanister; #groq }, ApiKeysService.EncryptedApiKey>>();
        let provider = #groq;
        let apiKey = "test-key-123";

        let result = ApiKeysService.storeApiKey(
          apiKeys,
          testKey,
          workspaceId,
          provider,
          apiKey,
        );

        expect.result<(), Text>(result, resultToText, resultEqual).isOk();

        let retrievedKey = ApiKeysService.getApiKey(
          apiKeys,
          testKey,
          workspaceId,
          provider,
        );

        expect.option(retrievedKey, Text.toText, Text.equal).equal(?apiKey);
      },
    );

    test(
      "getApiKey returns latest key after update",
      func() {
        let workspaceId = 0;
        var apiKeys = Map.empty<Nat, Map.Map<{ #openai; #llmcanister; #groq }, ApiKeysService.EncryptedApiKey>>();
        let provider = #groq;

        // Store first API key
        let firstKey = "original-key-123";
        let result1 = ApiKeysService.storeApiKey(
          apiKeys,
          testKey,
          workspaceId,
          provider,
          firstKey,
        );
        expect.result<(), Text>(result1, resultToText, resultEqual).isOk();

        // Verify first key is stored
        let retrievedFirstKey = ApiKeysService.getApiKey(
          apiKeys,
          testKey,
          workspaceId,
          provider,
        );
        expect.option(retrievedFirstKey, Text.toText, Text.equal).equal(?firstKey);

        // Update with a new API key
        let secondKey = "updated-key-456";
        let result2 = ApiKeysService.storeApiKey(
          apiKeys,
          testKey,
          workspaceId,
          provider,
          secondKey,
        );
        expect.result<(), Text>(result2, resultToText, resultEqual).isOk();

        // Verify latest key is returned
        let retrievedLatestKey = ApiKeysService.getApiKey(
          apiKeys,
          testKey,
          workspaceId,
          provider,
        );
        expect.option(retrievedLatestKey, Text.toText, Text.equal).equal(?secondKey);
      },
    );

    test(
      "getWorkspaceApiKeys returns list of stored providers",
      func() {
        let workspaceId = 0;
        var apiKeys = Map.empty<Nat, Map.Map<{ #openai; #llmcanister; #groq }, ApiKeysService.EncryptedApiKey>>();

        // Store multiple keys
        ignore ApiKeysService.storeApiKey(apiKeys, testKey, workspaceId, #groq, "key-1");
        ignore ApiKeysService.storeApiKey(apiKeys, testKey, workspaceId, #openai, "key-2");

        let result = ApiKeysService.getWorkspaceApiKeys(apiKeys, workspaceId);
        switch (result) {
          case (#ok keys) {
            expect.nat(keys.size()).equal(2);
          };
          case (#err _) {
            expect.bool(false).equal(true); // Fail
          };
        };
      },
    );

    test(
      "deleteApiKey removes the specified key",
      func() {
        let workspaceId = 0;
        var apiKeys = Map.empty<Nat, Map.Map<{ #openai; #llmcanister; #groq }, ApiKeysService.EncryptedApiKey>>();
        let provider = #groq;

        // Store a key
        ignore ApiKeysService.storeApiKey(apiKeys, testKey, workspaceId, provider, "key-to-delete");

        // Verify it exists
        let beforeDelete = ApiKeysService.getApiKey(apiKeys, testKey, workspaceId, provider);
        expect.option(beforeDelete, Text.toText, Text.equal).isSome();

        // Delete it
        let deleteResult = ApiKeysService.deleteApiKey(apiKeys, workspaceId, provider);
        expect.result<(), Text>(deleteResult, resultToText, resultEqual).isOk();

        // Verify it's gone
        let afterDelete = ApiKeysService.getApiKey(apiKeys, testKey, workspaceId, provider);
        expect.option(afterDelete, Text.toText, Text.equal).isNull();
      },
    );
  },
);
