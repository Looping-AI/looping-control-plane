/// Run Types — Unit Tests (placeholder)
///
/// Tests for `RunTypes.fromEnvelope` and RunRecord field invariants.
/// Populated in a future session once the internal-engine test canister
/// is wired up and its DID is generated.

import { test; expect } "mo:test";
import Nat "mo:core/Nat";
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

// ─────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────

test(
  "fromEnvelope preserves envelopeId",
  func() {
    let env = makeEnvelope(5);
    let record = RunTypes.fromEnvelope(env, 1234);
    expect.nat(record.envelopeId).equal(5);
  },
);

test(
  "fromEnvelope sets enqueuedAt from now parameter",
  func() {
    let env = makeEnvelope(1);
    let record = RunTypes.fromEnvelope(env, 9999);
    expect.bool(record.enqueuedAt == 9999).isTrue();
  },
);

test(
  "fromEnvelope starts with nil lifecycle timestamps",
  func() {
    let env = makeEnvelope(2);
    let record = RunTypes.fromEnvelope(env, 0);
    expect.bool(record.claimedAt == null).isTrue();
    expect.bool(record.completedAt == null).isTrue();
    expect.bool(record.failedAt == null).isTrue();
    expect.bool(record.status == null).isTrue();
    expect.bool(record.stats == null).isTrue();
  },
);

test(
  "fromEnvelope starts with empty steps",
  func() {
    let env = makeEnvelope(3);
    let record = RunTypes.fromEnvelope(env, 0);
    expect.nat(record.steps.size()).equal(0);
  },
);
