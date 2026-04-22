import Principal "mo:core/Principal";
import Nat "mo:core/Nat";
import ExecutionTypes "../../src/internal-engine/execution-types";
import RunStoreModel "../../src/internal-engine/models/run-store-model";
import RunTypes "../../src/internal-engine/runner/run-types";
import TestHelpers "./test-helpers";

// ============================================
// Internal Engine Test Canister
// ============================================
//
// IMPORTANT: Never add this canister to dfx or deploy it.
//
// Exposes internal engine modules as public actor methods so PocketIC TypeScript
// integration tests can invoke them over Candid. Placeholder only — methods will
// be expanded as coverage is added in future sessions.

shared ({ caller = _parent }) persistent actor class InternalEngineTestCanister() = self {

  // ── Run Store ─────────────────────────────────────────────────────

  let runStore = RunStoreModel.empty();

  /// Enqueue a minimal test envelope and return ok/duplicate.
  public func testEnqueue(envelopeId : Nat) : async Text {
    let envelope = TestHelpers.minimalEnvelope(envelopeId, "test-agent", "Hello");
    let record = RunTypes.fromEnvelope(envelope, 0);
    switch (RunStoreModel.enqueue(runStore, record)) {
      case (#ok) { "ok" };
      case (#duplicate) { "duplicate" };
    };
  };

  /// Return the number of runs currently in the running map.
  public func testRunningCount() : async Nat {
    RunStoreModel.sizes(runStore).running;
  };

};
