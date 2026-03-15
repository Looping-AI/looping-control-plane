import { test; suite; expect } "mo:test";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Text "mo:core/Text";
import Int "mo:core/Int";
import Time "mo:core/Time";
import Result "mo:core/Result";
import SecretModel "../../../../src/control-plane-core/models/secret-model";
import AgentModel "../../../../src/control-plane-core/models/agent-model";
import Types "../../../../src/control-plane-core/types";
import Constants "../../../../src/control-plane-core/constants";

type SecretId = Types.SecretId;

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

let testRequester : SecretModel.SecretRequester = {
  slackUserId = ?"U123";
  agentId = null;
  operation = "test";
};

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
        let state = SecretModel.initState();
        let secretId = #openRouterApiKey;
        let secret = "test-key-123";

        let result = SecretModel.storeSecret(
          state,
          testKey,
          workspaceId,
          secretId,
          secret,
          testRequester,
        );

        expect.result<(), Text>(result, resultToText, resultEqual).isOk();

        let retrievedSecret = SecretModel.getSecret(
          state,
          testKey,
          workspaceId,
          secretId,
          testRequester,
        );

        expect.option(retrievedSecret, Text.toText, Text.equal).equal(?secret);
      },
    );

    test(
      "getSecret returns latest value after update",
      func() {
        let workspaceId = 0;
        let state = SecretModel.initState();
        let secretId = #openRouterApiKey;

        // Store first secret
        let firstSecret = "original-key-123";
        let result1 = SecretModel.storeSecret(
          state,
          testKey,
          workspaceId,
          secretId,
          firstSecret,
          testRequester,
        );
        expect.result<(), Text>(result1, resultToText, resultEqual).isOk();

        // Verify first secret is stored
        let retrievedFirst = SecretModel.getSecret(
          state,
          testKey,
          workspaceId,
          secretId,
          testRequester,
        );
        expect.option(retrievedFirst, Text.toText, Text.equal).equal(?firstSecret);

        // Update with a new secret
        let secondSecret = "updated-key-456";
        let result2 = SecretModel.storeSecret(
          state,
          testKey,
          workspaceId,
          secretId,
          secondSecret,
          testRequester,
        );
        expect.result<(), Text>(result2, resultToText, resultEqual).isOk();

        // Verify latest secret is returned
        let retrievedLatest = SecretModel.getSecret(
          state,
          testKey,
          workspaceId,
          secretId,
          testRequester,
        );
        expect.option(retrievedLatest, Text.toText, Text.equal).equal(?secondSecret);
      },
    );

    test(
      "getWorkspaceSecrets returns list of stored secret IDs",
      func() {
        let workspaceId = 0;
        let state = SecretModel.initState();

        // Store multiple secrets
        ignore SecretModel.storeSecret(state, testKey, workspaceId, #openRouterApiKey, "key-1", testRequester);
        ignore SecretModel.storeSecret(state, testKey, workspaceId, #openaiApiKey, "key-2", testRequester);
        ignore SecretModel.storeSecret(state, testKey, workspaceId, #slackBotToken, "bot-token", testRequester);

        let result = SecretModel.getWorkspaceSecrets(state, workspaceId);
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
        let state = SecretModel.initState();
        let secretId = #openRouterApiKey;

        // Store a secret
        ignore SecretModel.storeSecret(state, testKey, workspaceId, secretId, "key-to-delete", testRequester);

        // Verify it exists
        let beforeDelete = SecretModel.getSecret(state, testKey, workspaceId, secretId, testRequester);
        expect.option(beforeDelete, Text.toText, Text.equal).isSome();

        // Delete it
        let deleteResult = SecretModel.deleteSecret(state, workspaceId, secretId, testRequester);
        expect.result<(), Text>(deleteResult, resultToText, resultEqual).isOk();

        // Verify it's gone
        let afterDelete = SecretModel.getSecret(state, testKey, workspaceId, secretId, testRequester);
        expect.option(afterDelete, Text.toText, Text.equal).isNull();
      },
    );

    // ── Audit log tests ────────────────────────────────────────────────────────

    test(
      "storeSecret logs a change entry for workspace > 0",
      func() {
        let workspaceId = 1;
        let state = SecretModel.initState();
        let before = Time.now();
        ignore SecretModel.storeSecret(state, testKey, workspaceId, #openRouterApiKey, "key", testRequester);
        let log = SecretModel.getChangeLogSince(state, workspaceId, before);
        expect.nat(log.size()).equal(1);
        expect.bool(log[0].changeType == #stored(#openRouterApiKey)).isTrue();
        expect.option(log[0].requester.slackUserId, Text.toText, Text.equal).equal(?"U123");
      },
    );

    test(
      "storeSecret ALWAYS logs change entries, even for excluded secretIds on workspace 0",
      func() {
        let state = SecretModel.initState();
        let before = Time.now();
        ignore SecretModel.storeSecret(state, testKey, 0, #slackBotToken, "tok", testRequester);
        ignore SecretModel.storeSecret(state, testKey, 0, #slackSigningSecret, "sig", testRequester);
        let log = SecretModel.getChangeLogSince(state, 0, before);
        // Change events are never suppressed — sensitivity of write operations warrants full logging
        expect.nat(log.size()).equal(2);
      },
    );

    test(
      "storeSecret DOES log non-excluded secrets on workspace 0",
      func() {
        let state = SecretModel.initState();
        let before = Time.now();
        ignore SecretModel.storeSecret(state, testKey, 0, #openRouterApiKey, "key", testRequester);
        let log = SecretModel.getChangeLogSince(state, 0, before);
        expect.nat(log.size()).equal(1);
      },
    );

    test(
      "getSecret logs an access entry when secret is found",
      func() {
        let workspaceId = 1;
        let state = SecretModel.initState();
        ignore SecretModel.storeSecret(state, testKey, workspaceId, #openRouterApiKey, "key", testRequester);
        let before = Time.now();
        ignore SecretModel.getSecret(state, testKey, workspaceId, #openRouterApiKey, testRequester);
        let log = SecretModel.getAccessLogSince(state, workspaceId, before);
        expect.nat(log.size()).equal(1);
        expect.bool(log[0].secretId == #openRouterApiKey).isTrue();
      },
    );

    test(
      "getSecret does NOT log access for workspace 0 excluded secretIds",
      func() {
        let state = SecretModel.initState();
        ignore SecretModel.storeSecret(state, testKey, 0, #slackBotToken, "tok", { slackUserId = null; agentId = null; operation = "init" });
        let before = Time.now();
        ignore SecretModel.getSecret(state, testKey, 0, #slackBotToken, testRequester);
        let log = SecretModel.getAccessLogSince(state, 0, before);
        expect.nat(log.size()).equal(0);
      },
    );

    test(
      "deleteSecret logs a change entry",
      func() {
        let workspaceId = 1;
        let state = SecretModel.initState();
        ignore SecretModel.storeSecret(state, testKey, workspaceId, #openaiApiKey, "k", testRequester);
        ignore SecretModel.deleteSecret(state, workspaceId, #openaiApiKey, testRequester);
        // Query all entries (timestamps may collide in synchronous test execution)
        let log = SecretModel.getChangeLogSince(state, workspaceId, 0);
        expect.nat(log.size()).equal(2); // store + delete
        expect.bool(log[1].changeType == #deleted(#openaiApiKey)).isTrue();
      },
    );

    test(
      "purgeAllWorkspaceLogs keeps entries within retention window",
      func() {
        let workspaceId = 1;
        let state = SecretModel.initState();
        ignore SecretModel.storeSecret(state, testKey, workspaceId, #openRouterApiKey, "k", testRequester);
        // With a large retention window nothing should be purged.
        // (Backdating entries for a "real" purge test requires async time-advance
        //  which is not available in synchronous mops test execution.)
        let purged = SecretModel.purgeAllWorkspaceLogs(state, Constants.ACCESS_LOG_RETENTION_NS);
        expect.nat(purged).equal(0);
        let log = SecretModel.getChangeLogSince(state, workspaceId, 0);
        expect.nat(log.size()).equal(1);
      },
    );

    test(
      "getChangeLogSince returns entries at or after the cutoff",
      func() {
        let workspaceId = 2;
        let state = SecretModel.initState();
        ignore SecretModel.storeSecret(state, testKey, workspaceId, #openRouterApiKey, "k1", testRequester);
        ignore SecretModel.storeSecret(state, testKey, workspaceId, #openaiApiKey, "k2", testRequester);
        // In synchronous test execution Time.now() is constant, so since=0 returns all entries.
        let log = SecretModel.getChangeLogSince(state, workspaceId, 0);
        expect.nat(log.size()).equal(2);
        expect.bool(log[0].changeType == #stored(#openRouterApiKey)).isTrue();
        expect.bool(log[1].changeType == #stored(#openaiApiKey)).isTrue();
        // A far-future cutoff should return nothing
        let futureLog = SecretModel.getChangeLogSince(state, workspaceId, 9_999_999_999_999_999_999);
        expect.nat(futureLog.size()).equal(0);
      },
    );
  },
);

// ─── Helper: minimal AgentRecord for resolveSecret tests ─────────────────────

let orgKey : [Nat8] = [
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
  0x20,
  0x21,
  0x22,
  0x23,
  0x24,
  0x25,
  0x26,
  0x27,
  0x28,
  0x29,
  0x2A,
  0x2B,
  0x2C,
  0x2D,
  0x2E,
  0x2F,
];

func makeAgentWithOverrides(secretOverrides : [(Types.SecretId, Text)]) : AgentModel.AgentRecord {
  {
    id = 1;
    name = "test-agent";
    workspaceId = 1;
    category = #planning;
    llmModel = #openRouter(#gpt_oss_120b);
    executionType = #api;
    secretsAllowed = [(1, #openRouterApiKey)];
    secretOverrides;
    toolsDisallowed = [];
    toolsMisconfigured = [];
    toolsState = Map.empty<Text, AgentModel.ToolState>();
    sources = [];
  };
};

// ─── Suite: resolveSecret ─────────────────────────────────────────────────────

suite(
  "SecretModel - resolveSecret",
  func() {

    test(
      "Level 2: returns workspace secret when no override matches",
      func() {
        let state = SecretModel.initState();
        ignore SecretModel.storeSecret(state, testKey, 1, #openRouterApiKey, "ws-key", testRequester);
        let agent = makeAgentWithOverrides([]);
        let result = SecretModel.resolveSecret(state, agent, 1, #openRouterApiKey, testKey, orgKey, testRequester);
        expect.option(result, Text.toText, Text.equal).equal(?"ws-key");
      },
    );

    test(
      "Level 3: falls back to org workspace when workspace secret is missing",
      func() {
        let state = SecretModel.initState();
        // Store key only at org level (workspaceId=0)
        ignore SecretModel.storeSecret(state, orgKey, 0, #openRouterApiKey, "org-key", testRequester);
        let agent = makeAgentWithOverrides([]);
        let result = SecretModel.resolveSecret(state, agent, 1, #openRouterApiKey, testKey, orgKey, testRequester);
        expect.option(result, Text.toText, Text.equal).equal(?"org-key");
      },
    );

    test(
      "Level 2 takes precedence over Level 3",
      func() {
        let state = SecretModel.initState();
        ignore SecretModel.storeSecret(state, testKey, 1, #openRouterApiKey, "ws-key", testRequester);
        ignore SecretModel.storeSecret(state, orgKey, 0, #openRouterApiKey, "org-key", testRequester);
        let agent = makeAgentWithOverrides([]);
        let result = SecretModel.resolveSecret(state, agent, 1, #openRouterApiKey, testKey, orgKey, testRequester);
        expect.option(result, Text.toText, Text.equal).equal(?"ws-key");
      },
    );

    test(
      "Level 1: custom override takes precedence over workspace secret",
      func() {
        let state = SecretModel.initState();
        // Store both standard key and custom override key in workspace 1
        ignore SecretModel.storeSecret(state, testKey, 1, #openRouterApiKey, "ws-standard-key", testRequester);
        ignore SecretModel.storeSecret(state, testKey, 1, #custom("my-override-key"), "custom-key-value", testRequester);
        let agent = makeAgentWithOverrides([(#openRouterApiKey, "my-override-key")]);
        let result = SecretModel.resolveSecret(state, agent, 1, #openRouterApiKey, testKey, orgKey, testRequester);
        expect.option(result, Text.toText, Text.equal).equal(?"custom-key-value");
      },
    );

    test(
      "Level 1: falls through to Level 2 when custom key is not stored",
      func() {
        let state = SecretModel.initState();
        // Custom key is declared in override but not actually stored
        ignore SecretModel.storeSecret(state, testKey, 1, #openRouterApiKey, "ws-key", testRequester);
        let agent = makeAgentWithOverrides([(#openRouterApiKey, "nonexistent-custom")]);
        let result = SecretModel.resolveSecret(state, agent, 1, #openRouterApiKey, testKey, orgKey, testRequester);
        // Falls through to Level 2
        expect.option(result, Text.toText, Text.equal).equal(?"ws-key");
      },
    );

    test(
      "Full miss: returns null when no secret is found at any level",
      func() {
        let state = SecretModel.initState();
        let agent = makeAgentWithOverrides([]);
        let result = SecretModel.resolveSecret(state, agent, 1, #openRouterApiKey, testKey, orgKey, testRequester);
        expect.option(result, Text.toText, Text.equal).isNull();
      },
    );

    test(
      "No org fallback when workspaceId is 0",
      func() {
        let state = SecretModel.initState();
        // Secret is stored with orgKey under workspace 0, but calling with workspaceId=0
        // should NOT retry itself (would cause double-decryption attempt with wrong key)
        ignore SecretModel.storeSecret(state, orgKey, 0, #openRouterApiKey, "org-key", testRequester);
        let agent = makeAgentWithOverrides([]);
        // Use testKey (not orgKey) as the workspace key — should miss
        let result = SecretModel.resolveSecret(state, agent, 0, #openRouterApiKey, testKey, orgKey, testRequester);
        // workspaceId=0 so Level 3 fallback is skipped; Level 2 uses testKey which can't decrypt
        expect.option(result, Text.toText, Text.equal).isNull();
      },
    );

    test(
      "Custom key collision guard: 'custom:X' and 'X' are stored separately",
      func() {
        let state = SecretModel.initState();
        ignore SecretModel.storeSecret(state, testKey, 1, #openRouterApiKey, "standard-value", testRequester);
        ignore SecretModel.storeSecret(state, testKey, 1, #custom("openRouterApiKey"), "collision-value", testRequester);
        let agent = makeAgentWithOverrides([(#openRouterApiKey, "openRouterApiKey")]);
        // Level 1: looks up custom:openRouterApiKey → should get collision-value
        let lvl1 = SecretModel.resolveSecret(state, agent, 1, #openRouterApiKey, testKey, orgKey, testRequester);
        expect.option(lvl1, Text.toText, Text.equal).equal(?"collision-value");
        // Direct Level 2 (no override agent): looks up #openRouterApiKey → should get standard-value
        let agentNoOverride = makeAgentWithOverrides([]);
        let lvl2 = SecretModel.resolveSecret(state, agentNoOverride, 1, #openRouterApiKey, testKey, orgKey, testRequester);
        expect.option(lvl2, Text.toText, Text.equal).equal(?"standard-value");
      },
    );
  },
);
