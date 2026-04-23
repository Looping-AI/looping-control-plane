import Principal "mo:core/Principal";
import Array "mo:core/Array";
import Nat "mo:core/Nat";
import Time "mo:core/Time";
import Timer "mo:core/Timer";
import Error "mo:core/Error";
import ExecutionTypes "./execution-types";
import CoreApi "./wrappers/core-api";
import RunTypes "./runner/run-types";
import RunStoreModel "./models/run-store-model";
import ExecutionRunner "./runner/execution-runner";

shared ({ caller = coreId }) persistent actor class InternalEngine() = self {

  let core : CoreApi.CoreApi = actor (Principal.toText(coreId));

  // ── Persistent state ───────────────────────────────────────────────

  let runStore = RunStoreModel.empty();

  // ── Envelope version ──────────────────────────────────────────────
  // The envelope format version this engine requires.
  // Format: "v1", "v1.1" — major = breaking field changes, minor = additive.
  // On mismatch Core receives a JSON error body and retries with the required version.
  let envelopeVersion : Text = "v1";

  // ── Periodic run-store maintenance ────────────────────────────────
  // Runs every hour: recovers hung runs, prunes completed/failed records.
  ignore Timer.recurringTimer<system>(
    #seconds(3600),
    func() : async () {
      ignore RunStoreModel.failStaleRunning(runStore);
      ignore RunStoreModel.purgeCompleted(runStore);
      ignore RunStoreModel.purgeOldFailed(runStore);
    },
  );

  // ── Execute (ingress) ─────────────────────────────────────────────
  // Validates, enqueues into the run store, fires a zero-delay timer,
  // and returns immediately. The LLM loop runs asynchronously via the
  // timer and delivers results to Core via emitComplete / emitMilestone.

  public shared ({ caller }) func execute(envelope : ExecutionTypes.EnvelopePayload) : async {
    #ok;
    #err : Text;
  } {
    if (caller != coreId) { return #err("Unauthorized") };

    // Version check — reject envelopes with an unknown or missing dispatchedVersion.
    // Error body follows the shared JSON protocol so HTTP engines can use the same contract:
    //   {"envelopeVersionRequired":"v1"}
    let versionOk = switch (envelope.dispatchedVersion) {
      case (?v) { v == envelopeVersion };
      case (null) { false };
    };
    if (not versionOk) {
      return #err("{\"envelopeVersionRequired\":\"" # envelopeVersion # "\"}");
    };

    // Validate before accepting — fail fast for missing credentials
    let hasApiKey = Array.find<(Text, Text)>(
      envelope.secrets.apiKeys,
      func(kv : (Text, Text)) : Bool { kv.0 == "openrouter" },
    ) != null;
    if (not hasApiKey) {
      return #err("Missing 'openrouter' API key in envelope secrets");
    };

    // Build run record and enqueue
    let record = RunTypes.fromEnvelope(envelope, Time.now());
    switch (RunStoreModel.enqueue(runStore, record)) {
      case (#duplicate) {
        return #err("Duplicate envelopeId: " # Nat.toText(envelope.envelopeId));
      };
      case (#ok) {};
    };

    let envelopeId = envelope.envelopeId;
    ignore Timer.setTimer<system>(
      #nanoseconds 0,
      func() : async () {
        await processEnvelope(envelopeId);
      },
    );
    #ok;
  };

  // ── Envelope processor ─────────────────────────────────────────────
  // Delegates to the runner and catches traps so that failures are
  // always recorded in the run store.

  private func processEnvelope(envelopeId : Nat) : async () {
    try {
      await ExecutionRunner.run(core, envelopeId, runStore);
    } catch (e : Error) {
      // Trap or unexpected error — record failure if the runner didn't already
      switch (RunStoreModel.getRunning(runStore, envelopeId)) {
        case (null) {}; // Runner already moved it — nothing to do
        case (_) {
          RunStoreModel.markFailed(
            runStore,
            envelopeId,
            "Trap: " # Error.message(e),
            [],
          );
        };
      };
    };
  };
};
