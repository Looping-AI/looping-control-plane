/// Run Helpers — Unit Tests
///
/// Tests for `RunHelpers.fromEnvelope` and RunRecord field invariants.

import { test; expect } "mo:test";
import Nat "mo:core/Nat";
import RunHelpers "../../../../src/internal-engine/runner/run-helpers";
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
    workflowName = "wf-test";
    agentName = "test-agent";
    dispatchedVersion = ?"v1";
    instructions = "test";
    messages = [];
    constraints = { maxRounds = 3; maxTokenBudget = null };
    model = "openai/gpt-oss-120b";
    secrets = { apiKeys = [("openrouter", "key")] };
    scopeGrants = [];
    envelopeNonce = "nonce-" # Nat.toText(id);
    catalogHash = null;
  };
};

// ─────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────

test(
  "fromEnvelope preserves envelopeId",
  func() {
    let env = makeEnvelope(5);
    let record = RunHelpers.fromEnvelope(env, 1234);
    expect.nat(record.envelopeId).equal(5);
  },
);

test(
  "fromEnvelope sets enqueuedAt from now parameter",
  func() {
    let env = makeEnvelope(1);
    let record = RunHelpers.fromEnvelope(env, 9999);
    expect.bool(record.enqueuedAt == 9999).isTrue();
  },
);

test(
  "fromEnvelope starts with nil lifecycle timestamps",
  func() {
    let env = makeEnvelope(2);
    let record = RunHelpers.fromEnvelope(env, 0);
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
    let record = RunHelpers.fromEnvelope(env, 0);
    expect.nat(record.steps.size()).equal(0);
  },
);
