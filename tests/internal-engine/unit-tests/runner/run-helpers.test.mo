/// Run Helpers — Unit Tests
///
/// Tests for `RunHelpers.fromEnvelope` and RunRecord field invariants.

import { test; expect } "mo:test";
import Nat "mo:core/Nat";
import RunHelpers "../../../../src/internal-engine/runner/run-helpers";
import WorkflowTypes "../../../../src/internal-engine/workflow-types";

// ─────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────

func makeEnvelope(id : Nat) : WorkflowTypes.EnvelopePayload {
  {
    envelopeId = id;
    dispatchedVersion = ?"v1";
    catalogHash = null;
    requestId = "req-" # Nat.toText(id);
    agentId = 0;
    agentName = "test-agent";
    workspaceId = 0;
    workflowName = "wf-test";
    workflowArguments = null;
    model = "openai/gpt-oss-120b";
    messages = [];
    instructions = "test";
    constraints = { maxRounds = 3; maxTokenBudget = null };
    secrets = { apiKeys = [("openrouter", "key")] };
    scopeGrants = [];
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
