import { test; suite; expect } "mo:test";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Text "mo:core/Text";
import Result "mo:core/Result";
import SecretModel "../../../../src/open-org-backend/models/secret-model";

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
  "SecretModel",
  func() {
    test(
      "storeSecret stores a secret for a workspace and secret ID",
      func() {
        let workspaceId = 0;
        var secrets = Map.empty<Nat, Map.Map<{ #groqApiKey; #openaiApiKey; #slackSigningSecret; #slackBotToken }, SecretModel.EncryptedSecret>>();
        let secretId = #groqApiKey;
        let secret = "test-key-123";

        let result = SecretModel.storeSecret(
          secrets,
          testKey,
          workspaceId,
          secretId,
          secret,
        );

        expect.result<(), Text>(result, resultToText, resultEqual).isOk();

        let retrievedSecret = SecretModel.getSecret(
          secrets,
          testKey,
          workspaceId,
          secretId,
        );

        expect.option(retrievedSecret, Text.toText, Text.equal).equal(?secret);
      },
    );

    test(
      "getSecret returns latest value after update",
      func() {
        let workspaceId = 0;
        var secrets = Map.empty<Nat, Map.Map<{ #groqApiKey; #openaiApiKey; #slackSigningSecret; #slackBotToken }, SecretModel.EncryptedSecret>>();
        let secretId = #groqApiKey;

        // Store first secret
        let firstSecret = "original-key-123";
        let result1 = SecretModel.storeSecret(
          secrets,
          testKey,
          workspaceId,
          secretId,
          firstSecret,
        );
        expect.result<(), Text>(result1, resultToText, resultEqual).isOk();

        // Verify first secret is stored
        let retrievedFirst = SecretModel.getSecret(
          secrets,
          testKey,
          workspaceId,
          secretId,
        );
        expect.option(retrievedFirst, Text.toText, Text.equal).equal(?firstSecret);

        // Update with a new secret
        let secondSecret = "updated-key-456";
        let result2 = SecretModel.storeSecret(
          secrets,
          testKey,
          workspaceId,
          secretId,
          secondSecret,
        );
        expect.result<(), Text>(result2, resultToText, resultEqual).isOk();

        // Verify latest secret is returned
        let retrievedLatest = SecretModel.getSecret(
          secrets,
          testKey,
          workspaceId,
          secretId,
        );
        expect.option(retrievedLatest, Text.toText, Text.equal).equal(?secondSecret);
      },
    );

    test(
      "getWorkspaceSecrets returns list of stored secret IDs",
      func() {
        let workspaceId = 0;
        var secrets = Map.empty<Nat, Map.Map<{ #groqApiKey; #openaiApiKey; #slackSigningSecret; #slackBotToken }, SecretModel.EncryptedSecret>>();

        // Store multiple secrets
        ignore SecretModel.storeSecret(secrets, testKey, workspaceId, #groqApiKey, "key-1");
        ignore SecretModel.storeSecret(secrets, testKey, workspaceId, #openaiApiKey, "key-2");
        ignore SecretModel.storeSecret(secrets, testKey, workspaceId, #slackSigningSecret, "signing-secret");

        let result = SecretModel.getWorkspaceSecrets(secrets, workspaceId);
        switch (result) {
          case (#ok ids) {
            expect.nat(ids.size()).equal(3);
          };
          case (#err _) {
            expect.bool(false).equal(true); // Fail
          };
        };
      },
    );

    test(
      "deleteSecret removes the specified secret",
      func() {
        let workspaceId = 0;
        var secrets = Map.empty<Nat, Map.Map<{ #groqApiKey; #openaiApiKey; #slackSigningSecret; #slackBotToken }, SecretModel.EncryptedSecret>>();
        let secretId = #groqApiKey;

        // Store a secret
        ignore SecretModel.storeSecret(secrets, testKey, workspaceId, secretId, "key-to-delete");

        // Verify it exists
        let beforeDelete = SecretModel.getSecret(secrets, testKey, workspaceId, secretId);
        expect.option(beforeDelete, Text.toText, Text.equal).isSome();

        // Delete it
        let deleteResult = SecretModel.deleteSecret(secrets, workspaceId, secretId);
        expect.result<(), Text>(deleteResult, resultToText, resultEqual).isOk();

        // Verify it's gone
        let afterDelete = SecretModel.getSecret(secrets, testKey, workspaceId, secretId);
        expect.option(afterDelete, Text.toText, Text.equal).isNull();
      },
    );
  },
);
