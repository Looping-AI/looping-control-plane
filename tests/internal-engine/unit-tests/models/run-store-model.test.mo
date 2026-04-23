/// Run Store Model — Unit Tests

import { test; expect } "mo:test";
import Nat "mo:core/Nat";
import Time "mo:core/Time";
import Map "mo:core/Map";
import RunStoreModel "../../../../src/internal-engine/models/run-store-model";
import RunTypes "../../../../src/internal-engine/runner/run-types";
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

/// Far-in-the-past timestamp. Used for stale/aged records so that
/// `Time.now() - ANCIENT` always exceeds every threshold, even when
/// `Time.now()` returns 0 in the mops test mock environment.
let ANCIENT : Int = -9_999_999_999_999_999;

/// Stale record — enqueuedAt set far in the past, exceeds the 1-hour stale threshold.
func makeRecord(id : Nat) : RunTypes.RunRecord {
  RunHelpers.fromEnvelope(makeEnvelope(id), ANCIENT);
};

/// Fresh record — enqueuedAt = Time.now(), will not be considered stale.
func freshRecord(id : Nat) : RunTypes.RunRecord {
  RunHelpers.fromEnvelope(makeEnvelope(id), Time.now());
};

func dummyStats() : ExecutionTypes.ExecutionStats {
  {
    durationNs = 100;
    llmCalls = 1;
    toolCalls = 0;
    inputTokens = 10;
    outputTokens = 20;
    model = "test-model";
    rounds = 1;
    estimatedDollarCost = null;
  };
};

/// Shorthand: enqueue a stale record into store.
func enq(store : RunStoreModel.RunStoreState, id : Nat) {
  ignore RunStoreModel.enqueue(store, makeRecord(id));
};

/// Shorthand: enqueue then complete.
func enqAndComplete(store : RunStoreModel.RunStoreState, id : Nat) {
  enq(store, id);
  RunStoreModel.markCompleted(store, id, #completed, dummyStats(), []);
};

/// Shorthand: enqueue then fail.
func enqAndFail(store : RunStoreModel.RunStoreState, id : Nat, err : Text) {
  enq(store, id);
  RunStoreModel.markFailed(store, id, err, []);
};

/// Insert a pre-aged completed record directly into the map
/// (bypasses markCompleted so we control completedAt).
func insertAgedCompleted(store : RunStoreModel.RunStoreState, id : Nat) {
  let r : RunTypes.RunRecord = {
    makeRecord(id) with
    completedAt = ?ANCIENT;
    status = ?(#completed);
    stats = ?dummyStats();
  };
  Map.add(store.completed, Nat.compare, id, r);
};

/// Insert a pre-aged failed record directly into the map
/// (bypasses markFailed so we control failedAt).
func insertAgedFailed(store : RunStoreModel.RunStoreState, id : Nat) {
  let r : RunTypes.RunRecord = {
    makeRecord(id) with
    failedAt = ?ANCIENT;
    failedError = "old error";
    status = ?(#failed("old error"));
  };
  Map.add(store.failed, Nat.compare, id, r);
};

// ─────────────────────────────────────────────────────────────────
// enqueue / isDuplicate
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
  "isDuplicate: false for unknown id",
  func() {
    let store = RunStoreModel.empty();
    expect.bool(RunStoreModel.isDuplicate(store, 99)).isFalse();
  },
);

test(
  "isDuplicate: true for record in running",
  func() {
    let store = RunStoreModel.empty();
    enq(store, 1);
    expect.bool(RunStoreModel.isDuplicate(store, 1)).isTrue();
  },
);

test(
  "isDuplicate: true for record in completed",
  func() {
    let store = RunStoreModel.empty();
    enqAndComplete(store, 2);
    expect.bool(RunStoreModel.isDuplicate(store, 2)).isTrue();
  },
);

test(
  "isDuplicate: true for record in failed",
  func() {
    let store = RunStoreModel.empty();
    enqAndFail(store, 3, "boom");
    expect.bool(RunStoreModel.isDuplicate(store, 3)).isTrue();
  },
);

// ─────────────────────────────────────────────────────────────────
// getRunning
// ─────────────────────────────────────────────────────────────────

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
      case (null) { expect.bool(false).isTrue() };
      case (?r) { expect.nat(r.envelopeId).equal(7) };
    };
  },
);

// ─────────────────────────────────────────────────────────────────
// claim
// ─────────────────────────────────────────────────────────────────

test(
  "claim returns null for unknown envelopeId",
  func() {
    let store = RunStoreModel.empty();
    expect.bool(RunStoreModel.claim(store, 99) == null).isTrue();
  },
);

test(
  "claim returns the record",
  func() {
    let store = RunStoreModel.empty();
    enq(store, 10);
    let claimed = RunStoreModel.claim(store, 10);
    switch (claimed) {
      case (null) { expect.bool(false).isTrue() };
      case (?r) { expect.nat(r.envelopeId).equal(10) };
    };
  },
);

test(
  "claim sets claimedAt",
  func() {
    let store = RunStoreModel.empty();
    enq(store, 11);
    let claimed = RunStoreModel.claim(store, 11);
    switch (claimed) {
      case (null) { expect.bool(false).isTrue() };
      case (?r) { expect.bool(r.claimedAt != null).isTrue() };
    };
  },
);

test(
  "claim leaves record in running map",
  func() {
    let store = RunStoreModel.empty();
    enq(store, 12);
    ignore RunStoreModel.claim(store, 12);
    expect.nat(RunStoreModel.sizes(store).running).equal(1);
    expect.nat(RunStoreModel.sizes(store).completed).equal(0);
  },
);

// ─────────────────────────────────────────────────────────────────
// markCompleted
// ─────────────────────────────────────────────────────────────────

test(
  "markCompleted moves record from running to completed",
  func() {
    let store = RunStoreModel.empty();
    enq(store, 20);
    RunStoreModel.markCompleted(store, 20, #completed, dummyStats(), []);
    expect.nat(RunStoreModel.sizes(store).running).equal(0);
    expect.nat(RunStoreModel.sizes(store).completed).equal(1);
  },
);

test(
  "markCompleted sets completedAt",
  func() {
    let store = RunStoreModel.empty();
    enq(store, 21);
    RunStoreModel.markCompleted(store, 21, #completed, dummyStats(), []);
    let r = RunStoreModel.get(store, 21);
    switch (r) {
      case (null) { expect.bool(false).isTrue() };
      case (?rec) { expect.bool(rec.completedAt != null).isTrue() };
    };
  },
);

test(
  "markCompleted stores status #completed",
  func() {
    let store = RunStoreModel.empty();
    enq(store, 22);
    RunStoreModel.markCompleted(store, 22, #completed, dummyStats(), []);
    let r = RunStoreModel.get(store, 22);
    switch (r) {
      case (null) { expect.bool(false).isTrue() };
      case (?rec) { expect.bool(rec.status == ?(#completed)).isTrue() };
    };
  },
);

test(
  "markCompleted stores status #roundLimitReached",
  func() {
    let store = RunStoreModel.empty();
    enq(store, 23);
    RunStoreModel.markCompleted(store, 23, #roundLimitReached, dummyStats(), []);
    let r = RunStoreModel.get(store, 23);
    switch (r) {
      case (null) { expect.bool(false).isTrue() };
      case (?rec) { expect.bool(rec.status == ?(#roundLimitReached)).isTrue() };
    };
  },
);

test(
  "markCompleted on unknown id is a no-op",
  func() {
    let store = RunStoreModel.empty();
    RunStoreModel.markCompleted(store, 99, #completed, dummyStats(), []);
    let sz = RunStoreModel.sizes(store);
    expect.nat(sz.running).equal(0);
    expect.nat(sz.completed).equal(0);
  },
);

// ─────────────────────────────────────────────────────────────────
// markFailed
// ─────────────────────────────────────────────────────────────────

test(
  "markFailed moves record from running to failed",
  func() {
    let store = RunStoreModel.empty();
    enq(store, 30);
    RunStoreModel.markFailed(store, 30, "something broke", []);
    expect.nat(RunStoreModel.sizes(store).running).equal(0);
    expect.nat(RunStoreModel.sizes(store).failed).equal(1);
  },
);

test(
  "markFailed sets failedError",
  func() {
    let store = RunStoreModel.empty();
    enq(store, 31);
    RunStoreModel.markFailed(store, 31, "trap occurred", []);
    let r = RunStoreModel.get(store, 31);
    switch (r) {
      case (null) { expect.bool(false).isTrue() };
      case (?rec) { expect.text(rec.failedError).equal("trap occurred") };
    };
  },
);

test(
  "markFailed sets status to #failed",
  func() {
    let store = RunStoreModel.empty();
    enq(store, 32);
    RunStoreModel.markFailed(store, 32, "oops", []);
    let r = RunStoreModel.get(store, 32);
    switch (r) {
      case (null) { expect.bool(false).isTrue() };
      case (?rec) { expect.bool(rec.status == ?(#failed("oops"))).isTrue() };
    };
  },
);

test(
  "markFailed on unknown id is a no-op",
  func() {
    let store = RunStoreModel.empty();
    RunStoreModel.markFailed(store, 99, "err", []);
    let sz = RunStoreModel.sizes(store);
    expect.nat(sz.running).equal(0);
    expect.nat(sz.failed).equal(0);
  },
);

// ─────────────────────────────────────────────────────────────────
// get
// ─────────────────────────────────────────────────────────────────

test(
  "get returns null for unknown envelopeId",
  func() {
    let store = RunStoreModel.empty();
    expect.bool(RunStoreModel.get(store, 99) == null).isTrue();
  },
);

test(
  "get finds record in running map",
  func() {
    let store = RunStoreModel.empty();
    enq(store, 40);
    let r = RunStoreModel.get(store, 40);
    switch (r) {
      case (null) { expect.bool(false).isTrue() };
      case (?rec) { expect.nat(rec.envelopeId).equal(40) };
    };
  },
);

test(
  "get finds record after markCompleted",
  func() {
    let store = RunStoreModel.empty();
    enqAndComplete(store, 41);
    let r = RunStoreModel.get(store, 41);
    switch (r) {
      case (null) { expect.bool(false).isTrue() };
      case (?rec) { expect.nat(rec.envelopeId).equal(41) };
    };
  },
);

test(
  "get finds record after markFailed",
  func() {
    let store = RunStoreModel.empty();
    enqAndFail(store, 42, "err");
    let r = RunStoreModel.get(store, 42);
    switch (r) {
      case (null) { expect.bool(false).isTrue() };
      case (?rec) { expect.nat(rec.envelopeId).equal(42) };
    };
  },
);

// ─────────────────────────────────────────────────────────────────
// listFailed
// ─────────────────────────────────────────────────────────────────

test(
  "listFailed returns empty array when no failures",
  func() {
    let store = RunStoreModel.empty();
    expect.nat(RunStoreModel.listFailed(store).size()).equal(0);
  },
);

test(
  "listFailed returns all failed records",
  func() {
    let store = RunStoreModel.empty();
    enqAndFail(store, 50, "e1");
    enqAndFail(store, 51, "e2");
    enqAndFail(store, 52, "e3");
    expect.nat(RunStoreModel.listFailed(store).size()).equal(3);
  },
);

test(
  "listFailed count matches sizes().failed",
  func() {
    let store = RunStoreModel.empty();
    enqAndFail(store, 53, "err");
    let listed = RunStoreModel.listFailed(store);
    let sz = RunStoreModel.sizes(store);
    expect.nat(listed.size()).equal(sz.failed);
  },
);

// ─────────────────────────────────────────────────────────────────
// failStaleRunning
// ─────────────────────────────────────────────────────────────────

test(
  "failStaleRunning moves stale record to failed",
  func() {
    let store = RunStoreModel.empty();
    enq(store, 60); // enqueuedAt = 0 → stale
    let moved = RunStoreModel.failStaleRunning(store);
    expect.nat(moved.size()).equal(1);
    expect.nat(RunStoreModel.sizes(store).running).equal(0);
    expect.nat(RunStoreModel.sizes(store).failed).equal(1);
  },
);

test(
  "failStaleRunning returns the affected envelopeIds",
  func() {
    let store = RunStoreModel.empty();
    enq(store, 61);
    enq(store, 62);
    let moved = RunStoreModel.failStaleRunning(store);
    expect.nat(moved.size()).equal(2);
  },
);

test(
  "failStaleRunning does not move a fresh record",
  func() {
    let store = RunStoreModel.empty();
    ignore RunStoreModel.enqueue(store, freshRecord(63));
    let moved = RunStoreModel.failStaleRunning(store);
    expect.nat(moved.size()).equal(0);
    expect.nat(RunStoreModel.sizes(store).running).equal(1);
    expect.nat(RunStoreModel.sizes(store).failed).equal(0);
  },
);

test(
  "failStaleRunning sets failedError on stale record",
  func() {
    let store = RunStoreModel.empty();
    enq(store, 64);
    ignore RunStoreModel.failStaleRunning(store);
    let r = RunStoreModel.get(store, 64);
    switch (r) {
      case (null) { expect.bool(false).isTrue() };
      case (?rec) {
        expect.bool(rec.failedError != "").isTrue();
        expect.bool(rec.status != null).isTrue();
      };
    };
  },
);

// ─────────────────────────────────────────────────────────────────
// purgeCompleted
// ─────────────────────────────────────────────────────────────────

test(
  "purgeCompleted removes aged completed records",
  func() {
    let store = RunStoreModel.empty();
    insertAgedCompleted(store, 70); // completedAt = ?0 (epoch, far past threshold)
    let purged = RunStoreModel.purgeCompleted(store);
    expect.nat(purged).equal(1);
    expect.nat(RunStoreModel.sizes(store).completed).equal(0);
  },
);

test(
  "purgeCompleted does not remove recent completed records",
  func() {
    let store = RunStoreModel.empty();
    enqAndComplete(store, 71); // completedAt = ?Time.now() (fresh)
    let purged = RunStoreModel.purgeCompleted(store);
    expect.nat(purged).equal(0);
    expect.nat(RunStoreModel.sizes(store).completed).equal(1);
  },
);

test(
  "purgeCompleted returns correct count for mixed ages",
  func() {
    let store = RunStoreModel.empty();
    insertAgedCompleted(store, 72);
    insertAgedCompleted(store, 73);
    enqAndComplete(store, 74); // recent
    let purged = RunStoreModel.purgeCompleted(store);
    expect.nat(purged).equal(2);
    expect.nat(RunStoreModel.sizes(store).completed).equal(1);
  },
);

// ─────────────────────────────────────────────────────────────────
// purgeOldFailed
// ─────────────────────────────────────────────────────────────────

test(
  "purgeOldFailed removes aged failed records",
  func() {
    let store = RunStoreModel.empty();
    insertAgedFailed(store, 80); // failedAt = ?0 (epoch, far past threshold)
    let purged = RunStoreModel.purgeOldFailed(store);
    expect.nat(purged).equal(1);
    expect.nat(RunStoreModel.sizes(store).failed).equal(0);
  },
);

test(
  "purgeOldFailed does not remove recent failed records",
  func() {
    let store = RunStoreModel.empty();
    enqAndFail(store, 81, "err"); // failedAt = ?Time.now() (fresh)
    let purged = RunStoreModel.purgeOldFailed(store);
    expect.nat(purged).equal(0);
    expect.nat(RunStoreModel.sizes(store).failed).equal(1);
  },
);

test(
  "purgeOldFailed returns correct count for mixed ages",
  func() {
    let store = RunStoreModel.empty();
    insertAgedFailed(store, 82);
    insertAgedFailed(store, 83);
    enqAndFail(store, 84, "err"); // recent
    let purged = RunStoreModel.purgeOldFailed(store);
    expect.nat(purged).equal(2);
    expect.nat(RunStoreModel.sizes(store).failed).equal(1);
  },
);
