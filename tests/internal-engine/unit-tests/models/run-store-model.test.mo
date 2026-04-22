/// Run Store Model — Unit Tests (placeholder)
///
/// These tests will grow to cover enqueue/dedup/lifecycle transitions.
/// Populated in a future session once the internal-engine test canister
/// is wired up and its DID is generated.

import { test; expect } "mo:test";
import Nat "mo:core/Nat";
import RunStoreModel "../../../../src/internal-engine/models/run-store-model";
import RunTypes "../../../../src/internal-engine/runner/run-types";
import ExecutionTypes "../../../../src/internal-engine/execution-types";

// ─────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────

func makeEnvelope(id : Nat) : ExecutionTypes.EnvelopePayload {
  {
    envelopeId = id;
    requestId = "req-" # Nat.toText(id);
    agentId = 0;
    workspaceId = 0;
    workflowId = "wf-test";
    agentName = "test-agent";
    dispatchedVersion = ?"v1";
    instructions = "test";
    messages = [];
    constraints = { maxRounds = 3; maxTokenBudget = null };
    secrets = { apiKeys = [("openrouter", "key")] };
    scopeGrants = [];
    permits = [];
    envelopeNonce = "nonce-" # Nat.toText(id);
  };
};

func makeRecord(id : Nat) : RunTypes.RunRecord {
  RunTypes.fromEnvelope(makeEnvelope(id), 0);
};

// ─────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────

test(
  "empty store has no running records",
  func() {
    let store = RunStoreModel.empty();
    let sz = RunStoreModel.sizes(store);
    expect.nat(sz.running).equal(0);
    expect.nat(sz.completed).equal(0);
    expect.nat(sz.failed).equal(0);
  },
);

test(
  "enqueue adds to running map",
  func() {
    let store = RunStoreModel.empty();
    let result = RunStoreModel.enqueue(store, makeRecord(1));
    expect.bool(result == #ok).isTrue();
    expect.nat(RunStoreModel.sizes(store).running).equal(1);
  },
);

test(
  "enqueue rejects duplicate envelopeId",
  func() {
    let store = RunStoreModel.empty();
    ignore RunStoreModel.enqueue(store, makeRecord(42));
    let result = RunStoreModel.enqueue(store, makeRecord(42));
    expect.bool(result == #duplicate).isTrue();
    expect.nat(RunStoreModel.sizes(store).running).equal(1);
  },
);

test(
  "getRunning returns null for unknown envelopeId",
  func() {
    let store = RunStoreModel.empty();
    let found = RunStoreModel.getRunning(store, 99);
    expect.bool(found == null).isTrue();
  },
);

test(
  "getRunning returns record after enqueue",
  func() {
    let store = RunStoreModel.empty();
    ignore RunStoreModel.enqueue(store, makeRecord(7));
    let found = RunStoreModel.getRunning(store, 7);
    switch (found) {
      case (null) { expect.bool(false).isTrue() }; // force fail
      case (?r) { expect.nat(r.envelopeId).equal(7) };
    };
  },
);
